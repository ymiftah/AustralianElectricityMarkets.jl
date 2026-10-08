# Shared toy `System` fixture: a two-unit `5_bus_hydro_ed_sys` under `NEMReplayDispatch`, used by
# `nem_dispatch_toy.jl` and `fcas_market.jl`.

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

# A scheduled load's one-band decremental offer and dispatch limits, in MW, MW/min and $/MWh.
# `initial` is `INITIALMW` (consumed MW, positive); `availability` is the load-side `MAXAVAIL`.
function toy_load(capacity, price; initial, ramp_up, ramp_down = 100.0, availability = capacity)
    return (; capacity, price, initial, ramp_up, ramp_down, availability)
end

# `5_bus_hydro_ed_sys` reduced to one area, the load on bus4 and the given `ThermalStandard`
# units, each carrying its bid stack and the four dispatch-limit series over two 5-minute
# intervals. `batteries` is a vector of `name => toy_battery(...)` pairs, each built as an
# `EnergyReservoirStorage` on bus1 with a generous static rating (never the binding limit),
# an incremental/decremental offer curve, and the ramp/initial/energy-availability series.
# `mutate!(sys, stamps)`, when given, runs just before the fixture's
# `transform_single_time_series!`, so it can attach raw two-timestamp series of its own.
function nem_toy_system(units, load_mw; batteries = Pair{String, Any}[], loads = Pair{String, Any}[], mutate! = nothing)
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
        add_series!(gen, "availability", unit.availability / base_power)
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

    # Scheduled loads (`InterruptiblePowerLoad`) on bus1, priced on their decremental offer only.
    for (name, ld) in loads
        scheduled = PSY.InterruptiblePowerLoad(;
            name = name, available = true, bus = bus1, active_power = ld.initial / base_power,
            reactive_power = 0.0, max_active_power = ld.capacity / base_power,
            max_reactive_power = 0.0, base_power = base_power,
            operation_cost = PSY.MarketBidCost(;
                no_load_cost = 0.0, start_up = (hot = 0.0, warm = 0.0, cold = 0.0), shut_down = 0.0,
            ),
        )
        PSY.add_component!(sys, scheduled)
        offer = PSY.PiecewiseStepData([0.0, ld.capacity], [ld.price])
        AustralianElectricityMarkets._set_decremental_bid_cost!(
            sys, scheduled, (piecewise_step_data = fill(offer, length(stamps)),),
            TOY_START, TOY_RESOLUTION,
        )
        add_series!(
            scheduled, "max_active_power", ld.availability / ld.capacity;
            multiplier = PSY.get_max_active_power,
        )
        add_series!(scheduled, "ramp_up_rate", ld.ramp_up / base_power)
        add_series!(scheduled, "ramp_down_rate", ld.ramp_down / base_power)
        add_series!(scheduled, "initial_mw", ld.initial / base_power)
        add_series!(scheduled, "availability", ld.availability / base_power)
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
    has_units = !isempty(PSY.get_components(PSY.ThermalStandard, sys))
    ramp_slack_mw = (;
        up = has_units ? sum(read_variable(results, "UnitRampUpSlack__ThermalStandard").value) : 0.0,
        down = has_units ? sum(read_variable(results, "UnitRampDownSlack__ThermalStandard").value) : 0.0,
    )
    load_mw = Dict{String, Float64}()
    if !isempty(PSY.get_components(PSY.InterruptiblePowerLoad, sys))
        for row in eachrow(read_variable(results, "ActivePowerVariable__InterruptiblePowerLoad"))
            load_mw[row.name] = row.value
        end
    end
    has_batteries = !isempty(PSY.get_components(PSY.EnergyReservoirStorage, sys))
    storage_ramp_slack_mw = (;
        up = has_batteries ? sum(read_variable(results, "UnitRampUpSlack__EnergyReservoirStorage").value) : 0.0,
        down = has_batteries ? sum(read_variable(results, "UnitRampDownSlack__EnergyReservoirStorage").value) : 0.0,
    )
    nem_keys = [
        k for k in PSI.get_constraint_keys(container)
            if PSI.IS.Optimization.get_entry_type(k) === NEMConstraintLimit
    ]
    return (;
        dispatch_mw = dispatch_mw,
        battery_out_mw = battery_out_mw,
        battery_in_mw = battery_in_mw,
        ramp_slack_mw = ramp_slack_mw,
        load_mw = load_mw,
        results = results,
        container = container,
        storage_ramp_slack_mw = storage_ramp_slack_mw,
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
