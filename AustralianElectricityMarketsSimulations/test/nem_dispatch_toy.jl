using HiGHS
using PowerSimulations
using PowerSystemCaseBuilder
import PowerSimulations as PSI
import PowerSystems as PSY

const PSB = PowerSystemCaseBuilder

const TOY_START = DateTime(2025, 1, 1)
const TOY_RESOLUTION = Minute(5)
const TOY_TOLERANCE = 1.0e-6

# The two `5_bus_hydro_ed_sys` units the toy keeps; both sit on bus1.
const TOY_CHEAP = "Alta"
const TOY_EXPENSIVE = "Park City"
const TOY_BATTERY = "batt1"

# A unit's offer and dispatch limits, in MW, MW/min and $/MWh. `bands` is a vector of
# `(MW, price)` pairs in offer order.
function toy_unit(capacity, bands; initial, ramp_up, ramp_down = 100.0, availability = capacity)
    return (; capacity, bands, initial, ramp_up, ramp_down, availability)
end

# A battery's one-band GEN/LOAD offers and dispatch limits, in MW, MW/min (net) and $/MWh.
# `initial` is `INITIALMW` (net MW, negative when charging). `gen_avail`/`load_avail` are the
# per-direction energy bid `MAXAVAIL`, defaulting to the offer band width.
function toy_battery(
        gen_capacity, gen_price, load_capacity, load_price;
        initial, ramp_up, ramp_down = 100.0, gen_avail = gen_capacity, load_avail = load_capacity,
    )
    return (;
        gen_capacity, gen_price, load_capacity, load_price, initial, ramp_up, ramp_down,
        gen_avail, load_avail,
    )
end

# `5_bus_hydro_ed_sys` reduced to one area, the load on bus4 and the given `ThermalStandard`
# units, each carrying its bid stack and the four dispatch-limit series over two 5-minute
# intervals. `batteries` is a vector of `name => toy_battery(...)` pairs, each built as an
# `EnergyReservoirStorage` on bus1 with a generous static rating (never the binding limit),
# an incremental/decremental offer curve, and the ramp/initial/energy-availability series.
# `mutate!(sys, stamps)`, when given, runs just before the fixture's
# `transform_single_time_series!`, so it can attach raw two-timestamp series of its own.
function nem_toy_system(units, load_mw; batteries = Pair{String, Any}[], mutate! = nothing)
    sys = PSB.build_system(PSISystems, "5_bus_hydro_ed_sys")
    PSY.clear_time_series!(sys)
    PSY.set_units_base_system!(sys, "NATURAL_UNITS")

    area = PSY.get_component(PSY.Area, sys, "1")
    foreach(bus -> PSY.set_area!(bus, area), PSY.get_components(PSY.ACBus, sys))
    PSY.remove_component!(sys, PSY.get_component(PSY.Area, sys, "2"))
    for T in (PSY.ThermalStandard, PSY.HydroDispatch, PSY.HydroTurbine, PSY.PowerLoad)
        foreach(c -> PSY.set_available!(c, false), PSY.get_components(T, sys))
    end

    base_power = PSY.get_base_power(sys)
    stamps = [TOY_START, TOY_START + TOY_RESOLUTION]
    function add_series!(component, name, value; multiplier = nothing)
        PSY.add_time_series!(
            sys, component,
            PSY.SingleTimeSeries(;
                name,
                data = PSY.TimeSeries.TimeArray(stamps, fill(value, length(stamps))),
                scaling_factor_multiplier = multiplier,
            ),
        )
        return
    end
    function add_forecast!(component, name, value)
        PSY.add_time_series!(
            sys, component,
            PSY.Deterministic(;
                name, data = Dict(TOY_START => fill(value, length(stamps))),
                resolution = TOY_RESOLUTION, interval = TOY_RESOLUTION,
            ),
        )
        return
    end

    for (name, unit) in units
        gen = PSY.get_component(PSY.ThermalStandard, sys, name)
        PSY.set_active_power_limits!(gen, (min = 0.0, max = unit.capacity))
        offer = PSY.PiecewiseStepData([0.0; cumsum(first.(unit.bands))], last.(unit.bands))
        AustralianElectricityMarkets._set_incremental_bid_cost!(
            sys, gen, (piecewise_step_data = fill(offer, length(stamps)),),
            TOY_START, TOY_RESOLUTION,
        )
        add_series!(
            gen, "max_active_power", unit.availability / unit.capacity;
            multiplier = PSY.get_max_active_power,
        )
        add_series!(gen, "ramp_up_rate", unit.ramp_up / base_power)
        add_series!(gen, "ramp_down_rate", unit.ramp_down / base_power)
        add_series!(gen, "initial_mw", unit.initial / base_power)
    end

    load = PSY.get_component(PSY.PowerLoad, sys, "bus4")
    PSY.set_available!(load, true)
    PSY.set_max_active_power!(load, load_mw)
    PSY.set_active_power!(load, load_mw)
    add_series!(load, "max_active_power", 1.0; multiplier = PSY.get_max_active_power)

    bus1 = PSY.get_component(PSY.ACBus, sys, "bus1")
    for (name, bat) in batteries
        battery = PSY.EnergyReservoirStorage(;
            name = name, available = true, bus = bus1, prime_mover_type = PSY.PrimeMovers.BA,
            storage_technology_type = PSY.StorageTech.LIB, storage_capacity = 1.0,
            storage_level_limits = (min = 0.0, max = 1.0), initial_storage_capacity_level = 0.5,
            rating = 1.0, active_power = bat.initial / base_power,
            input_active_power_limits = (min = 0.0, max = 1.0e4),
            output_active_power_limits = (min = 0.0, max = 1.0e4),
            efficiency = (in = 1.0, out = 1.0), reactive_power = 0.0,
            reactive_power_limits = (min = -1.0, max = 1.0), base_power = base_power,
        )
        PSY.add_component!(sys, battery)

        gen_offer = PSY.PiecewiseStepData([0.0, bat.gen_capacity], [bat.gen_price])
        AustralianElectricityMarkets._set_incremental_bid_cost!(
            sys, battery, (piecewise_step_data = fill(gen_offer, length(stamps)),),
            TOY_START, TOY_RESOLUTION,
        )
        load_offer = PSY.PiecewiseStepData([0.0, bat.load_capacity], [bat.load_price])
        decr = PSY.Deterministic(;
            name = "decremental_variable_cost", data = Dict(TOY_START => fill(load_offer, length(stamps))),
            resolution = TOY_RESOLUTION, interval = TOY_RESOLUTION,
        )
        PSY.set_decremental_variable_cost!(sys, battery, decr, PSY.UnitSystem.NATURAL_UNITS)
        decr_init = PSY.Deterministic(;
            name = "decremental_initial_input", data = Dict(TOY_START => fill(0.0, length(stamps))),
            resolution = TOY_RESOLUTION, interval = TOY_RESOLUTION,
        )
        PSY.set_decremental_initial_input!(sys, battery, decr_init)

        add_forecast!(battery, "energy_max_avail", bat.gen_avail / base_power)
        add_forecast!(battery, "energy_max_avail_decremental", bat.load_avail / base_power)
        add_series!(battery, "ramp_up_rate", bat.ramp_up / base_power)
        add_series!(battery, "ramp_down_rate", bat.ramp_down / base_power)
        add_series!(battery, "initial_mw", bat.initial / base_power)
    end

    isnothing(mutate!) || mutate!(sys, stamps)

    # One two-interval window, matching the single window the bid forecast carries.
    PSY.transform_single_time_series!(sys, 2 * TOY_RESOLUTION, TOY_RESOLUTION)
    return sys
end

# A single ENERGY `UnitTerm` `GenericConstraint` named "N_TOY_LIMIT", `<=` `rhs_mw` on `duid`'s
# ENERGY output, with "rhs"/"invoked" series on `stamps`, in the form `add_nem_constraints!`
# would produce. `rhs_mw` is a natural-MW value, stored per-unit of the system base.
function add_toy_generic_constraint!(sys, stamps, duid, rhs_mw)
    base_power = PSY.get_base_power(sys)
    rhs_pu = rhs_mw / base_power
    gc = GenericConstraint(;
        name = "N_TOY_LIMIT",
        sense = ConstraintSense.LE,
        rhs = rhs_pu,
        terms = ConstraintTerm[UnitTerm(duid, BidType.ENERGY, 1.0)],
    )
    PSY.add_service!(sys, gc, [PSY.get_component(PSY.ThermalStandard, sys, duid)])
    PSY.add_time_series!(
        sys, gc,
        PSY.SingleTimeSeries(; name = "rhs", data = PSY.TimeSeries.TimeArray(stamps, fill(rhs_pu, length(stamps)))),
    )
    PSY.add_time_series!(
        sys, gc,
        PSY.SingleTimeSeries(; name = "invoked", data = PSY.TimeSeries.TimeArray(stamps, fill(1.0, length(stamps)))),
    )
    return
end

# Solves one 5-minute interval under `NEMReplayDispatch`. Returns dispatch and per-band offers in
# MW, the area price in $/MWh, the objective in $, and each `GenericConstraint`'s shadow price in
# $/MWh, keyed by name (empty if `sys` carries none). Any `GenericConstraint` in `sys` is registered
# under `LinearFactorLimit`.
function solve_toy(sys)
    network = PSI.NetworkModel(
        PSI.AreaBalancePowerModel;
        use_slacks = true,
        duals = [PSI.CopperPlateBalanceConstraint],
    )
    template = PSI.ProblemTemplate(network)
    set_nem_dispatch_models!(template, sys)
    PSI.set_device_model!(template, PSY.PowerLoad, PSI.StaticPowerLoad)
    if !isempty(PSY.get_components(GenericConstraint, sys))
        PSI.set_service_model!(
            template,
            PSI.ServiceModel(GenericConstraint, LinearFactorLimit; duals = [NEMConstraintLimit]),
        )
    end
    model = PSI.DecisionModel(
        template, sys;
        optimizer = optimizer_with_attributes(HiGHS.Optimizer, "output_flag" => false),
        horizon = TOY_RESOLUTION,
        resolution = TOY_RESOLUTION,
        interval = TOY_RESOLUTION,
        initial_time = TOY_START,
        name = "nem_toy",
        store_variable_names = true,
    )
    @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
    @test PSI.solve!(model) == PSI.RunStatus.SUCCESSFULLY_FINALIZED

    base_power = PSY.get_base_power(sys)
    results = PSI.OptimizationProblemResults(model)
    dispatch = read_variable(results, "ActivePowerVariable__ThermalStandard")
    dual = only(read_dual(results, "CopperPlateBalanceConstraint__Area").value)
    container = PSI.get_optimization_container(model)
    offers = PSI.get_variable(
        container, PSI.PiecewiseLinearBlockIncrementalOffer(), PSY.ThermalStandard,
    )
    dispatch_mw = Dict(row.name => row.value for row in eachrow(dispatch))
    battery_out_mw = Dict{String, Float64}()
    battery_in_mw = Dict{String, Float64}()
    if !isempty(PSY.get_components(PSY.EnergyReservoirStorage, sys))
        for row in eachrow(read_variable(results, "ActivePowerOutVariable__EnergyReservoirStorage"))
            battery_out_mw[row.name] = row.value
            dispatch_mw[row.name] = get(dispatch_mw, row.name, 0.0) + row.value
        end
        for row in eachrow(read_variable(results, "ActivePowerInVariable__EnergyReservoirStorage"))
            battery_in_mw[row.name] = row.value
            dispatch_mw[row.name] = get(dispatch_mw, row.name, 0.0) - row.value
        end
    end
    nem_keys = [
        k for k in PSI.get_constraint_keys(container)
            if PSI.IS.Optimization.get_entry_type(k) === NEMConstraintLimit
    ]
    return (;
        dispatch_mw = dispatch_mw,
        battery_out_mw = battery_out_mw,
        battery_in_mw = battery_in_mw,
        band_mw = Dict(
            (name, band) => PSI.JuMP.value(v) * base_power
                for ((name, band, _), v) in pairs(offers.data)
        ),
        price = dual / (base_power * DISPATCH_INTERVAL_HOURS),
        objective = PSI.JuMP.objective_value(PSI.get_jump_model(container)),
        constraint_price = Dict(
            k.meta => only(read_dual(results, k).value) / (base_power * DISPATCH_INTERVAL_HOURS)
                for k in nem_keys
        ),
    )
end

@testset "merit order: the cheaper unit is filled first" begin
    sys = nem_toy_system(
        [
            TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = 60.0, ramp_up = 100.0),
            TOY_EXPENSIVE => toy_unit(100.0, [(100.0, 80.0)]; initial = 60.0, ramp_up = 100.0),
        ],
        120.0,
    )
    out = solve_toy(sys)

    @test out.dispatch_mw[TOY_CHEAP] ≈ 100.0 atol = TOY_TOLERANCE
    @test out.dispatch_mw[TOY_EXPENSIVE] ≈ 20.0 atol = TOY_TOLERANCE
    @test out.price ≈ 80.0 atol = TOY_TOLERANCE
    @test out.objective ≈ (100.0 * 20.0 + 20.0 * 80.0) * DISPATCH_INTERVAL_HOURS atol = TOY_TOLERANCE
end

@testset "multi-band stack: bands load in price order, the marginal one partially" begin
    sys = nem_toy_system(
        [
            TOY_CHEAP => toy_unit(
                100.0, [(20.0, 20.0), (30.0, 50.0), (50.0, 300.0)];
                initial = 60.0, ramp_up = 100.0,
            ),
            TOY_EXPENSIVE => toy_unit(100.0, [(100.0, 1000.0)]; initial = 60.0, ramp_up = 100.0),
        ],
        40.0,
    )
    out = solve_toy(sys)

    @test out.dispatch_mw[TOY_CHEAP] ≈ 40.0 atol = TOY_TOLERANCE
    @test out.dispatch_mw[TOY_EXPENSIVE] ≈ 0.0 atol = TOY_TOLERANCE
    @test out.band_mw[(TOY_CHEAP, 1)] ≈ 20.0 atol = TOY_TOLERANCE
    @test out.band_mw[(TOY_CHEAP, 2)] ≈ 20.0 atol = TOY_TOLERANCE
    @test out.band_mw[(TOY_CHEAP, 3)] ≈ 0.0 atol = TOY_TOLERANCE
    @test out.price ≈ 50.0 atol = TOY_TOLERANCE
    @test out.objective ≈ (20.0 * 20.0 + 20.0 * 50.0) * DISPATCH_INTERVAL_HOURS atol = TOY_TOLERANCE
end

@testset "a binding ramp overrides merit order" begin
    function ramp_toy(cheap_ramp_up)
        return nem_toy_system(
            [
                TOY_CHEAP => toy_unit(
                    100.0, [(100.0, 20.0)]; initial = 50.0, ramp_up = cheap_ramp_up,
                ),
                TOY_EXPENSIVE => toy_unit(100.0, [(100.0, 80.0)]; initial = 50.0, ramp_up = 20.0),
            ],
            90.0,
        )
    end
    tight = solve_toy(ramp_toy(1.0))
    relaxed = solve_toy(ramp_toy(20.0))

    @testset "held at INITIALMW + rate × 5 min, the expensive unit covers the rest" begin
        @test tight.dispatch_mw[TOY_CHEAP] ≈ 50.0 + 1.0 * 5 atol = TOY_TOLERANCE
        @test tight.dispatch_mw[TOY_EXPENSIVE] ≈ 35.0 atol = TOY_TOLERANCE
        @test tight.price ≈ 80.0 atol = TOY_TOLERANCE
    end

    @testset "with the ramp relaxed, merit order is restored" begin
        @test relaxed.dispatch_mw[TOY_CHEAP] ≈ 90.0 atol = TOY_TOLERANCE
        @test relaxed.dispatch_mw[TOY_EXPENSIVE] ≈ 0.0 atol = TOY_TOLERANCE
        @test relaxed.price ≈ 20.0 atol = TOY_TOLERANCE
    end
end

@testset "a battery discharges when the area price is above its generation offer" begin
    # The battery's 60 MW, $20/MWh offer clears first; Park City's $80/MWh offer covers the
    # remaining 40 MW of the 100 MW load and sets the price. The battery's load band ($1/MWh)
    # is never worth clearing against either offer, so it does not charge.
    sys = nem_toy_system(
        [TOY_EXPENSIVE => toy_unit(100.0, [(100.0, 80.0)]; initial = 60.0, ramp_up = 100.0)],
        100.0;
        batteries = [
            TOY_BATTERY => toy_battery(
                60.0, 20.0, 10.0, 1.0; initial = 0.0, ramp_up = 100.0,
            ),
        ],
    )
    out = solve_toy(sys)

    @test out.battery_out_mw[TOY_BATTERY] ≈ 60.0 atol = TOY_TOLERANCE
    @test out.battery_in_mw[TOY_BATTERY] ≈ 0.0 atol = TOY_TOLERANCE
    @test out.dispatch_mw[TOY_EXPENSIVE] ≈ 40.0 atol = TOY_TOLERANCE
    @test out.price ≈ 80.0 atol = TOY_TOLERANCE
    @test out.objective ≈ (60.0 * 20.0 + 40.0 * 80.0) * DISPATCH_INTERVAL_HOURS atol = TOY_TOLERANCE
end

@testset "a battery charges when its load bid is above the marginal generator's price" begin
    # Alta's $20/MWh offer covers the 40 MW load plus the battery's full 30 MW charge, since
    # the battery's $50/MWh load bid values that charge above Alta's cost. Charging lowers the
    # objective by (50 - 20) * 30 = 900 $ relative to the no-battery baseline of 40 * 20 = 800 $.
    sys = nem_toy_system(
        [TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = 60.0, ramp_up = 100.0)],
        40.0;
        batteries = [
            TOY_BATTERY => toy_battery(
                10.0, 1000.0, 30.0, 50.0; initial = 0.0, ramp_up = 100.0,
            ),
        ],
    )
    out = solve_toy(sys)

    @test out.battery_in_mw[TOY_BATTERY] ≈ 30.0 atol = TOY_TOLERANCE
    @test out.battery_out_mw[TOY_BATTERY] ≈ 0.0 atol = TOY_TOLERANCE
    @test out.dispatch_mw[TOY_CHEAP] ≈ 70.0 atol = TOY_TOLERANCE
    @test out.price ≈ 20.0 atol = TOY_TOLERANCE
    baseline_objective = 40.0 * 20.0 * DISPATCH_INTERVAL_HOURS
    @test out.objective ≈ baseline_objective - (50.0 - 20.0) * 30.0 * DISPATCH_INTERVAL_HOURS atol = TOY_TOLERANCE
    @test out.objective ≈ (70.0 * 20.0 - 30.0 * 50.0) * DISPATCH_INTERVAL_HOURS atol = TOY_TOLERANCE
end

@testset "a net ramp limit binding across zero" begin
    # INITIALMW = -10 (charging 10 MW net); ramp_up = 1 MW/min-convention over the 5-minute
    # interval allows a +5 MW move, so net cannot exceed -10 + 5 = -5 (still a net 5 MW
    # charge). The battery's own gen availability is zero, so Out = 0 and In is pinned to
    # exactly 5 by the ramp floor (In >= Out + 5) and the load availability ceiling (In <= 5)
    # at once. Alta supplies the 5 MW the battery's net charging still needs off a 0 MW load.
    sys = nem_toy_system(
        [TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = 60.0, ramp_up = 100.0)],
        0.0;
        batteries = [
            TOY_BATTERY => toy_battery(
                10.0, 20.0, 10.0, 30.0;
                initial = -10.0, ramp_up = 1.0, ramp_down = 100.0, gen_avail = 0.0, load_avail = 5.0,
            ),
        ],
    )
    out = solve_toy(sys)

    @test out.battery_out_mw[TOY_BATTERY] ≈ 0.0 atol = TOY_TOLERANCE
    @test out.battery_in_mw[TOY_BATTERY] ≈ 5.0 atol = TOY_TOLERANCE
    @test out.dispatch_mw[TOY_CHEAP] ≈ 5.0 atol = TOY_TOLERANCE
    @test out.price ≈ 20.0 atol = TOY_TOLERANCE
    @test out.objective ≈ (5.0 * 20.0 - 5.0 * 30.0) * DISPATCH_INTERVAL_HOURS atol = TOY_TOLERANCE
end

@testset "a net ramp-down floor above generation availability raises the generation ceiling" begin
    # INITIALMW = 20 (discharging); ramp_down = 1 MW/min over the 5-minute interval gives a net
    # ramp-down floor of 20 - 5 = 15, above the battery's own 10 MW generation availability. The
    # generation ceiling is raised to the floor, so the battery covers the full 15 MW load at its
    # $5/MWh offer instead of being capped at 10 MW.
    sys = nem_toy_system(
        [TOY_CHEAP => toy_unit(100.0, [(100.0, 100.0)]; initial = 0.0, ramp_up = 100.0)],
        15.0;
        batteries = [
            TOY_BATTERY => toy_battery(
                100.0, 5.0, 100.0, 1.0;
                initial = 20.0, ramp_up = 100.0, ramp_down = 1.0, gen_avail = 10.0,
            ),
        ],
    )
    out = solve_toy(sys)

    @test out.battery_out_mw[TOY_BATTERY] ≈ 15.0 atol = TOY_TOLERANCE
    @test out.battery_in_mw[TOY_BATTERY] ≈ 0.0 atol = TOY_TOLERANCE
    @test out.dispatch_mw[TOY_CHEAP] ≈ 0.0 atol = TOY_TOLERANCE
    @test out.objective ≈ 15.0 * 5.0 * DISPATCH_INTERVAL_HOURS atol = TOY_TOLERANCE
end

@testset "a net ramp-up ceiling below negative load availability raises the load ceiling" begin
    # INITIALMW = -20 (charging); ramp_up = 1 MW/min over the 5-minute interval gives a net
    # ramp-up ceiling of -20 + 5 = -15, below the negative of the battery's own 10 MW load
    # availability (-10). The load ceiling is raised to 15, so the battery charges the full 15 MW
    # its $1000/MWh load bid values, off Alta's $20/MWh supply, instead of being capped at 10 MW.
    sys = nem_toy_system(
        [TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = 60.0, ramp_up = 100.0)],
        0.0;
        batteries = [
            TOY_BATTERY => toy_battery(
                100.0, 1.0, 100.0, 1000.0;
                initial = -20.0, ramp_up = 1.0, ramp_down = 100.0, gen_avail = 0.0, load_avail = 10.0,
            ),
        ],
    )
    out = solve_toy(sys)

    @test out.battery_in_mw[TOY_BATTERY] ≈ 15.0 atol = TOY_TOLERANCE
    @test out.battery_out_mw[TOY_BATTERY] ≈ 0.0 atol = TOY_TOLERANCE
    @test out.dispatch_mw[TOY_CHEAP] ≈ 15.0 atol = TOY_TOLERANCE
    @test out.objective ≈ (15.0 * 20.0 - 15.0 * 1000.0) * DISPATCH_INTERVAL_HOURS atol = TOY_TOLERANCE
end

@testset "a per-direction availability binding" begin
    @testset "discharge is capped by the generation-side MAXAVAIL, not the cheaper price" begin
        # The battery's $5/MWh offer is cheaper than Alta's $20/MWh, so it would fill first
        # without a cap; its 10 MW generation availability caps it well below the 50 MW load,
        # and its load availability is zero, so it never charges.
        sys = nem_toy_system(
            [TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = 60.0, ramp_up = 100.0)],
            50.0;
            batteries = [
                TOY_BATTERY => toy_battery(
                    10.0, 5.0, 10.0, 1.0; initial = 0.0, ramp_up = 100.0, load_avail = 0.0,
                ),
            ],
        )
        out = solve_toy(sys)

        @test out.battery_out_mw[TOY_BATTERY] ≈ 10.0 atol = TOY_TOLERANCE
        @test out.battery_in_mw[TOY_BATTERY] ≈ 0.0 atol = TOY_TOLERANCE
        @test out.dispatch_mw[TOY_CHEAP] ≈ 40.0 atol = TOY_TOLERANCE
        @test out.price ≈ 20.0 atol = TOY_TOLERANCE
        @test out.objective ≈ (40.0 * 20.0 + 10.0 * 5.0) * DISPATCH_INTERVAL_HOURS atol = TOY_TOLERANCE
    end

    @testset "charge is capped by the load-side MAXAVAIL, not the attractive price" begin
        # The battery's $1000/MWh load bid is far above Alta's $20/MWh cost, so it would
        # charge without limit; its 8 MW load availability caps it, and its generation
        # availability is zero, so it never discharges.
        sys = nem_toy_system(
            [TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = 60.0, ramp_up = 100.0)],
            0.0;
            batteries = [
                TOY_BATTERY => toy_battery(
                    10.0, 1.0, 20.0, 1000.0; initial = 0.0, ramp_up = 100.0, gen_avail = 0.0, load_avail = 8.0,
                ),
            ],
        )
        out = solve_toy(sys)

        @test out.battery_in_mw[TOY_BATTERY] ≈ 8.0 atol = TOY_TOLERANCE
        @test out.battery_out_mw[TOY_BATTERY] ≈ 0.0 atol = TOY_TOLERANCE
        @test out.dispatch_mw[TOY_CHEAP] ≈ 8.0 atol = TOY_TOLERANCE
        @test out.price ≈ 20.0 atol = TOY_TOLERANCE
        @test out.objective ≈ (8.0 * 20.0 - 8.0 * 1000.0) * DISPATCH_INTERVAL_HOURS atol = TOY_TOLERANCE
    end
end

@testset "a generic constraint binds against NEMReplayDispatch" begin
    function constrained_toy(rhs_mw)
        return nem_toy_system(
            [
                TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = 60.0, ramp_up = 100.0),
                TOY_EXPENSIVE => toy_unit(100.0, [(100.0, 80.0)]; initial = 60.0, ramp_up = 100.0),
            ],
            120.0;
            mutate! = (sys, stamps) -> add_toy_generic_constraint!(sys, stamps, TOY_CHEAP, rhs_mw),
        )
    end

    @testset "a 70 MW cap on the cheap unit binds, forcing the expensive unit up" begin
        out = solve_toy(constrained_toy(70.0))

        @test out.dispatch_mw[TOY_CHEAP] ≈ 70.0 atol = TOY_TOLERANCE
        @test out.dispatch_mw[TOY_EXPENSIVE] ≈ 50.0 atol = TOY_TOLERANCE
        @test out.price ≈ 80.0 atol = TOY_TOLERANCE
        @test out.objective ≈ (70.0 * 20.0 + 50.0 * 80.0) * DISPATCH_INTERVAL_HOURS atol = TOY_TOLERANCE

        # A binding `<=` carries a negative dual under minimisation.
        @test out.constraint_price["N_TOY_LIMIT"] ≈ -60.0 atol = TOY_TOLERANCE
    end

    @testset "a 120 MW cap is slack, and merit order is unaffected" begin
        out = solve_toy(constrained_toy(120.0))

        @test out.dispatch_mw[TOY_CHEAP] ≈ 100.0 atol = TOY_TOLERANCE
        @test out.dispatch_mw[TOY_EXPENSIVE] ≈ 20.0 atol = TOY_TOLERANCE
        @test out.price ≈ 80.0 atol = TOY_TOLERANCE
        @test out.constraint_price["N_TOY_LIMIT"] ≈ 0.0 atol = TOY_TOLERANCE
    end
end
