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

# One value per stamp: a scalar repeats, a vector gives one value per stamp.
function _toy_values(x::Real, n)
    return fill(Float64(x), n)
end
function _toy_values(x::AbstractVector{<:Real}, n)
    length(x) == n || error("expected $n per-stamp values, got $(length(x))")
    return Float64.(x)
end
# Offer curves per stamp from `(MW, price)` bands: one band list for all stamps, or one list per stamp.
function _toy_offer(bands)
    return PSY.PiecewiseStepData([0.0; cumsum(first.(bands))], last.(bands))
end
function _toy_offers(bands, n)
    first(bands) isa Tuple && return fill(_toy_offer(bands), n)
    length(bands) == n || error("expected $n per-stamp band lists, got $(length(bands))")
    return [_toy_offer(b) for b in bands]
end

# A battery's one-band GEN/LOAD offers and dispatch limits, in MW, MW/min (net) and $/MWh.
# `initial` is `INITIALMW` (net MW, negative when charging). `gen_avail`/`load_avail` are the
# per-direction energy bid `MAXAVAIL`, defaulting to the offer band width. Fields except the
# capacities and prices take a scalar or one value per stamp.
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
# Unit fields except `capacity`, and `load_mw`, take a scalar or one value per stamp;
# `horizon` is the transform horizon. With `ceilings` (default), the batteries' dispatch ceilings
# are attached after `mutate!`, and with `tie_break_scales` (default) the tie-break scales.
function nem_toy_system(
        units, load_mw; batteries = Pair{String, Any}[], loads = Pair{String, Any}[], mutate! = nothing,
        horizon = 2 * TOY_RESOLUTION, ceilings = true, tie_break_scales = true,
    )
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
                data = PSY.TimeSeries.TimeArray(stamps, _toy_values(value, length(stamps))),
                scaling_factor_multiplier = multiplier,
            ),
        )
        return
    end
    function add_forecast!(component, name, value)
        PSY.add_time_series!(
            sys, component,
            AustralianElectricityMarkets._single_series(name, TOY_START, _toy_values(value, length(stamps)), TOY_RESOLUTION),
        )
        return
    end

    for (name, unit) in units
        gen = PSY.get_component(PSY.ThermalStandard, sys, name)
        PSY.set_active_power_limits!(gen, (min = 0.0, max = unit.capacity))
        AustralianElectricityMarkets._set_incremental_bid_cost!(
            sys, gen, (piecewise_step_data = _toy_offers(unit.bands, length(stamps)),),
            TOY_START, TOY_RESOLUTION,
        )
        add_series!(
            gen, "max_active_power", unit.availability ./ unit.capacity;
            multiplier = PSY.get_max_active_power,
        )
        add_series!(gen, "ramp_up_rate", unit.ramp_up ./ base_power)
        add_series!(gen, "ramp_down_rate", unit.ramp_down ./ base_power)
        add_series!(gen, "initial_mw", unit.initial ./ base_power)
        add_series!(gen, "availability", unit.availability ./ base_power)
    end

    load = PSY.get_component(PSY.PowerLoad, sys, "bus4")
    PSY.set_available!(load, true)
    peak = maximum(load_mw)
    PSY.set_max_active_power!(load, peak)
    PSY.set_active_power!(load, first(load_mw))
    add_series!(load, "max_active_power", peak > 0 ? load_mw ./ peak : 1.0; multiplier = PSY.get_max_active_power)

    bus1 = PSY.get_component(PSY.ACBus, sys, "bus1")
    for (name, bat) in batteries
        battery = PSY.EnergyReservoirStorage(;
            name = name, available = true, bus = bus1, prime_mover_type = PSY.PrimeMovers.BA,
            storage_technology_type = PSY.StorageTech.LIB, storage_capacity = 1.0,
            storage_level_limits = (min = 0.0, max = 1.0), initial_storage_capacity_level = 0.5,
            rating = 1.0, active_power = first(bat.initial) / base_power,
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
        decr = AustralianElectricityMarkets._single_series(
            "decremental_variable_cost", TOY_START, fill(load_offer, length(stamps)), TOY_RESOLUTION,
        )
        PSY.set_decremental_variable_cost!(sys, battery, decr, PSY.UnitSystem.NATURAL_UNITS)
        decr_init = AustralianElectricityMarkets._single_series(
            "decremental_initial_input", TOY_START, fill(0.0, length(stamps)), TOY_RESOLUTION,
        )
        PSY.set_decremental_initial_input!(sys, battery, decr_init)

        add_forecast!(battery, "energy_max_avail", bat.gen_avail ./ base_power)
        add_forecast!(battery, "energy_max_avail_decremental", bat.load_avail ./ base_power)
        add_series!(battery, "ramp_up_rate", bat.ramp_up ./ base_power)
        add_series!(battery, "ramp_down_rate", bat.ramp_down ./ base_power)
        add_series!(battery, "initial_mw", bat.initial ./ base_power)
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
    ceilings && set_storage_dispatch_ceilings!(sys)
    set_fcas_effective_offers!(sys)
    tie_break_scales && set_tie_break_scales!(sys)

    # One window per `horizon`.
    PSY.transform_single_time_series!(sys, horizon, TOY_RESOLUTION)
    return sys
end

# A single ENERGY `UnitTerm` `GenericConstraint` `name` of `sense` on `duid`'s ENERGY output at
# `rhs_mw`, with "rhs"/"invoked" series on `stamps`, in the form `add_nem_constraints!`
# would produce. `rhs_mw` is a natural-MW value, stored per-unit of the system base. `rhs_mw` and
# `invoked` take a scalar or one value per stamp.
function add_toy_generic_constraint!(
        sys, stamps, duid, rhs_mw; invoked = 1.0, sense = ConstraintSense.LE, name = "N_TOY_LIMIT",
    )
    base_power = PSY.get_base_power(sys)
    rhs_pu = _toy_values(rhs_mw, length(stamps)) ./ base_power
    duids = duid isa AbstractString ? [duid] : collect(duid)
    gc = GenericConstraint(;
        name = name,
        sense = sense,
        rhs = first(rhs_pu),
        terms = ConstraintTerm[UnitTerm(d, BidType.ENERGY, 1.0) for d in duids],
    )
    PSY.add_service!(sys, gc, [PSY.get_component(PSY.ThermalStandard, sys, d) for d in duids])
    PSY.add_time_series!(
        sys, gc,
        PSY.SingleTimeSeries(; name = "rhs", data = PSY.TimeSeries.TimeArray(stamps, rhs_pu)),
    )
    PSY.add_time_series!(
        sys, gc,
        PSY.SingleTimeSeries(; name = "invoked", data = PSY.TimeSeries.TimeArray(stamps, _toy_values(invoked, length(stamps)))),
    )
    return
end

# Solves one 5-minute interval under `NEMReplayDispatch`. Returns dispatch and per-band offers in
# MW, the area price in $/MWh, the objective in $, and each `GenericConstraint`'s shadow price in
# $/MWh, keyed by name (empty if `sys` carries none). Any `GenericConstraint` in `sys` is registered
# under `LinearFactorLimit`.
function solve_toy(
        sys;
        formulation = NEMReplayDispatch,
        optimizer = optimizer_with_attributes(HiGHS.Optimizer, "output_flag" => false),
    )
    network = PSI.NetworkModel(
        PSI.AreaBalancePowerModel;
        use_slacks = true,
        duals = [PSI.CopperPlateBalanceConstraint],
    )
    template = PSI.ProblemTemplate(network)
    set_nem_dispatch_models!(template, sys; formulation = formulation)
    PSI.set_device_model!(template, PSY.PowerLoad, PSI.StaticPowerLoad)
    if !isempty(PSY.get_components(GenericConstraint, sys))
        PSI.set_service_model!(
            template,
            PSI.ServiceModel(GenericConstraint, LinearFactorLimit; duals = [NEMConstraintLimit]),
        )
    end
    model = PSI.DecisionModel(
        template, sys;
        optimizer = optimizer,
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

# --- FCAS on the toy system: one `(MW, ...)` value or band list per stamp. ---

# Attaches `device`'s `"fcas_trapezium_*"`/`"fcas_curve_*"` series: `trapeziums` are
# `(EnablementMin, LowBreakpoint, HighBreakpoint, EnablementMax, MaxAvail)` in MW, `bands` `(MW, price)` lists.
function add_toy_fcas_offer!(sys, device, stamps, bid_type, trapeziums, bands; decremental = false)
    base_power = PSY.get_base_power(sys)
    suffix = decremental ? "$(string(bid_type))_decremental" : string(bid_type)
    traps = [
        Tuple(FCASTrapezium(; enablement_min = a / base_power, low_breakpoint = b / base_power, high_breakpoint = c / base_power, enablement_max = d / base_power, max_avail = e / base_power))
            for (a, b, c, d, e) in trapeziums
    ]
    curves = [PSY.PiecewiseStepData([0.0; cumsum(first.(bs))] ./ base_power, last.(bs)) for bs in bands]
    for (name, values) in (("fcas_trapezium_$suffix", traps), ("fcas_curve_$suffix", curves))
        PSY.add_time_series!(sys, device, AustralianElectricityMarkets._single_series(name, stamps[1], values, TOY_RESOLUTION))
    end
    return
end
# Attaches a per-stamp `SingleTimeSeries` `name`, per-unitised unless `scale` says otherwise.
function add_toy_series!(sys, component, stamps, name, values; scale = 1 / PSY.get_base_power(sys))
    PSY.add_time_series!(sys, component, PSY.SingleTimeSeries(; name, data = PSY.TimeSeries.TimeArray(stamps, Float64.(values) .* scale)))
    return
end
# An `FCASService` `"1_<BIDTYPE>"` over `duids` and its GE requirement `name` of `rhs_mw` per stamp.
function add_toy_fcas_market!(sys, stamps, bid_type, duids, name, rhs_mw)
    base_power = PSY.get_base_power(sys)
    devices = [PSY.get_component(PSY.Device, sys, d) for d in duids]
    PSY.add_service!(sys, FCASService(; name = "1_$(string(bid_type))", region = "1", bid_type), devices)
    gc = GenericConstraint(;
        name, sense = ConstraintSense.GE, rhs = rhs_mw[1] / base_power,
        terms = ConstraintTerm[UnitTerm(d, bid_type, 1.0) for d in duids], fcas_requirements = [FCASRequirement("1", bid_type)],
    )
    PSY.add_service!(sys, gc, devices)
    add_toy_series!(sys, gc, stamps, "rhs", rhs_mw)
    add_toy_series!(sys, gc, stamps, "invoked", [1.0, 1.0]; scale = 1.0)
    return
end
# Alta and Park City offer RAISE6SEC, Alta also RAISEREG and LOWERREG, `TOY_BATTERY` RAISEREG on both
# sides and RAISE6SEC, the scheduled load "pump" LOWER6SEC; each market has a requirement.
function fcas_toy_system(;
        reverse_order = false, alta_reg_avail = [15.0, 8.0], alta_agc = [1, 1], park_initial = [40.0, 40.0],
        batt_initial = [5.0, 5.0], batt_ramp = [240.0, 240.0], reg_req = [20.0, 20.0], r6_req = [30.0, 30.0],
        alta_ramp = [240.0, 240.0], agc_emax = [90.0, 90.0], horizon = TOY_RESOLUTION,
    )
    r(x) = reverse_order ? reverse(x) : x
    units = [
        TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = 50.0, ramp_up = 100.0, ramp_down = 100.0),
        TOY_EXPENSIVE => toy_unit(100.0, [(100.0, 80.0)]; initial = r(park_initial), ramp_up = 100.0, ramp_down = 100.0),
    ]
    batteries = [TOY_BATTERY => toy_battery(50.0, 30.0, 50.0, 0.0; initial = r(batt_initial), ramp_up = 100.0)]
    loads = ["pump" => toy_load(40.0, 300.0; initial = 20.0, ramp_up = 100.0)]
    return nem_toy_system(
        units, r([60.0, 80.0]); batteries, loads, horizon, mutate! = (sys, stamps) -> begin
            alta = PSY.get_component(PSY.ThermalStandard, sys, TOY_CHEAP)
            park = PSY.get_component(PSY.ThermalStandard, sys, TOY_EXPENSIVE)
            bat = PSY.get_component(PSY.EnergyReservoirStorage, sys, TOY_BATTERY)
            pump = PSY.get_component(PSY.InterruptiblePowerLoad, sys, "pump")
            add_toy_fcas_offer!(sys, alta, stamps, BidType.RAISEREG, r([(10.0, 20.0, 80.0, 95.0, a) for a in alta_reg_avail]), fill([(10.0, 5.0), (10.0, 12.0)], 2))
            add_toy_fcas_offer!(sys, alta, stamps, BidType.LOWERREG, fill((10.0, 20.0, 80.0, 95.0, 10.0), 2), fill([(10.0, 6.0)], 2))
            add_toy_fcas_offer!(sys, alta, stamps, BidType.RAISE6SEC, fill((5.0, 10.0, 70.0, 100.0, 20.0), 2), fill([(20.0, 3.0)], 2))
            add_toy_fcas_offer!(sys, park, stamps, BidType.RAISE6SEC, fill((5.0, 10.0, 90.0, 100.0, 25.0), 2), fill([(15.0, 1.0), (10.0, 9.0)], 2))
            add_toy_fcas_offer!(sys, bat, stamps, BidType.RAISEREG, fill((0.0, 5.0, 20.0, 25.0, 10.0), 2), fill([(10.0, 15.0)], 2))
            add_toy_fcas_offer!(sys, bat, stamps, BidType.RAISEREG, fill((-25.0, -20.0, -5.0, 0.0, 10.0), 2), fill([(10.0, 12.0)], 2); decremental = true)
            add_toy_fcas_offer!(sys, bat, stamps, BidType.RAISE6SEC, fill((-50.0, -40.0, 40.0, 50.0, 20.0), 2), fill([(20.0, 2.0)], 2))
            add_toy_fcas_offer!(sys, pump, stamps, BidType.LOWER6SEC, fill((0.0, 5.0, 35.0, 40.0, 10.0), 2), fill([(10.0, 4.0)], 2); decremental = true)
            add_toy_series!(sys, alta, stamps, "fcas_agc_ramp_rate_RAISEREG", r(alta_ramp))
            add_toy_series!(sys, alta, stamps, "fcas_agc_ramp_rate_LOWERREG", [240.0, 240.0])
            add_toy_series!(sys, alta, stamps, "fcas_agc_enablement_max_RAISEREG", r(agc_emax))
            add_toy_series!(sys, alta, stamps, "fcas_agc_status", r(alta_agc); scale = 1.0)
            add_toy_series!(sys, bat, stamps, "fcas_agc_ramp_rate_RAISEREG", r(batt_ramp))
            add_toy_series!(sys, bat, stamps, "fcas_agc_status", [1, 1]; scale = 1.0)
            add_toy_fcas_market!(sys, stamps, BidType.RAISEREG, [TOY_CHEAP, TOY_BATTERY], "F_REG", r(reg_req))
            add_toy_fcas_market!(sys, stamps, BidType.RAISE6SEC, [TOY_CHEAP, TOY_EXPENSIVE, TOY_BATTERY], "F_R6", r(r6_req))
            add_toy_fcas_market!(sys, stamps, BidType.LOWER6SEC, ["pump"], "F_L6", [5.0, 5.0])
            PSY.add_service!(sys, FCASService(; name = "1_LOWERREG", region = "1", bid_type = BidType.LOWERREG), [alta])
        end,
    )
end
