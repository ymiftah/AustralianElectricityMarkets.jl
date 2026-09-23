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

# A unit's offer and dispatch limits, in MW, MW/min and $/MWh. `bands` is a vector of
# `(MW, price)` pairs in offer order.
function toy_unit(capacity, bands; initial, ramp_up, ramp_down = 100.0, availability = capacity)
    return (; capacity, bands, initial, ramp_up, ramp_down, availability)
end

# `5_bus_hydro_ed_sys` reduced to one area, the load on bus4 and the given `ThermalStandard`
# units, each carrying its bid stack and the four dispatch-limit series over two 5-minute
# intervals.
function nem_toy_system(units, load_mw)
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

    # One two-interval window, matching the single window the bid forecast carries.
    PSY.transform_single_time_series!(sys, 2 * TOY_RESOLUTION, TOY_RESOLUTION)
    return sys
end

# Solves one 5-minute interval under `NEMReplayDispatch`. Returns dispatch and per-band offers in
# MW, the area price in $/MWh, and the objective in $.
function solve_toy(sys)
    network = PSI.NetworkModel(
        PSI.AreaBalancePowerModel;
        use_slacks = true,
        duals = [PSI.CopperPlateBalanceConstraint],
    )
    template = PSI.ProblemTemplate(network)
    set_nem_dispatch_models!(template, sys)
    PSI.set_device_model!(template, PSY.PowerLoad, PSI.StaticPowerLoad)
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
    return (;
        dispatch_mw = Dict(row.name => row.value for row in eachrow(dispatch)),
        band_mw = Dict(
            (name, band) => PSI.JuMP.value(v) * base_power
                for ((name, band, _), v) in pairs(offers.data)
        ),
        price = dual / (base_power * DISPATCH_INTERVAL_HOURS),
        objective = PSI.JuMP.objective_value(PSI.get_jump_model(container)),
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
