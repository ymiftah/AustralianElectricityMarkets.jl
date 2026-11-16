using TimeSeries: TimeArray

const _ST_IS = PowerSystems.IS
const _ST_STAMPS = collect(DateTime(2025, 1, 1):Minute(5):DateTime(2025, 1, 1, 0, 30))
_st_series(name, values) = SingleTimeSeries(; name, data = TimeArray(_ST_STAMPS, values))
_st_key(component, name::String) = only(k for k in _ST_IS.get_time_series_keys(component) if k.name == name)

_st_bus() = ACBus(;
    number = 1, name = "bus", available = true, bustype = ACBusTypes.REF, angle = 0.0,
    magnitude = 1.0, voltage_limits = (min = 0.9, max = 1.1), base_voltage = 230.0,
)

function _st_thermal(name, bus)
    return ThermalStandard(;
        name, available = true, status = true, bus, active_power = 50.0, reactive_power = 0.0,
        rating = 120.0, active_power_limits = (min = 10.0, max = 100.0), reactive_power_limits = nothing,
        ramp_limits = nothing, operation_cost = ThermalGenerationCost(nothing), base_power = 100.0,
    )
end


# Two 5-minute steps, the shortest range a replay can run one interval per step.
const _ST_STEP_RANGE = TOY_START:TOY_RESOLUTION:(TOY_START + TOY_RESOLUTION)
const _ST_OPTIMIZER = optimizer_with_attributes(HiGHS.Optimizer, "output_flag" => false)

# `DUID => MW` per step, from the solved intervals in step order.
function _st_dispatch_by_step(out)
    dispatch = read_solved_interval(out.results, PSI.get_system(out.model)).dispatch
    sort!(dispatch, :SETTLEMENTDATE)
    return Dict(name => Float64.(filter(:DUID => ==(name), dispatch).TOTALCLEARED) for name in unique(dispatch.DUID))
end


@testset "each step's ramp base is the observed initial MW of that step" begin
    # Alta's ramp-up limit falls from 2 to 1 MW/min and its observed initial MW from 50 to 10, so
    # its step-2 ceiling is 15 MW.
    sys = nem_toy_system(
        [
            TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = [50.0, 10.0], ramp_up = [2.0, 1.0]),
            TOY_EXPENSIVE => toy_unit(100.0, [(100.0, 80.0)]; initial = [50.0, 50.0], ramp_up = 100.0),
        ],
        100.0; horizon = TOY_RESOLUTION,
    )
    out = run_replay(sys, _ST_STEP_RANGE; optimizer = _ST_OPTIMIZER)
    dispatch = _st_dispatch_by_step(out)
    @test dispatch[TOY_CHEAP] ≈ [60.0, 15.0] atol = 1.0e-6
    @test dispatch[TOY_EXPENSIVE] ≈ [40.0, 85.0] atol = 1.0e-6
    objectives = PSI.read_optimizer_stats(out.results).objective_value
    @test objectives[1] ≈ 4400.0 / 12 atol = 1.0e-4
    @test objectives[2] ≈ 7100.0 / 12 atol = 1.0e-4

    container = PSI.get_optimization_container(out.model)
    initial = PSI.get_parameter(container, PSI.ParameterKey(AEMS.InitialPowerTimeSeriesParameter, ThermalStandard))
    @test only(PSI.get_parameter_column_values(initial, TOY_CHEAP)) === 10.0
    @test only(PSI.get_parameter_column_values(initial, TOY_EXPENSIVE)) === 50.0
end


@testset "each step's fixed loading is recomputed from the bid and the dispatch mode" begin
    sys = nem_toy_system(
        [
            TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = 20.0, ramp_up = 100.0),
            TOY_EXPENSIVE => toy_unit(100.0, [(100.0, 80.0)]; initial = [40.0, 0.0], ramp_up = 100.0),
        ],
        60.0; horizon = TOY_RESOLUTION,
        mutate! = function (sys, stamps)
            park = PSY.get_component(ThermalStandard, sys, TOY_EXPENSIVE)
            _toy_energy_bid!(
                sys, park, AustralianElectricityMarkets.BidDirection.GEN, stamps,
                fill(_toy_offer([(100.0, 80.0)]), length(stamps)), fill(100.0, length(stamps));
                fixed_load = fill(40.0, length(stamps)),
            )
            set_toy_unit_field!(sys, park, stamps, :dispatch_mode, [0.0, 2.0])
            return
        end,
    )
    out = run_replay(sys, _ST_STEP_RANGE; optimizer = _ST_OPTIMIZER)
    dispatch = _st_dispatch_by_step(out)
    @test dispatch[TOY_EXPENSIVE] ≈ [40.0, 0.0] atol = 1.0e-6
    @test dispatch[TOY_CHEAP] ≈ [20.0, 60.0] atol = 1.0e-6
    objectives = PSI.read_optimizer_stats(out.results).objective_value
    @test objectives[1] ≈ 3600.0 / 12 atol = 1.0e-4
    @test objectives[2] ≈ 1200.0 / 12 atol = 1.0e-4

    container = PSI.get_optimization_container(out.model)
    target = PSI.get_parameter(container, PSI.ParameterKey(AEMS.FixedLoadTimeSeriesParameter, ThermalStandard))
    invoked = PSI.get_parameter(container, PSI.ParameterKey(AEMS.FixedLoadInvokedTimeSeriesParameter, ThermalStandard))
    @test only(PSI.get_parameter_column_values(target, TOY_EXPENSIVE)) === 0.0
    @test only(PSI.get_parameter_column_values(invoked, TOY_EXPENSIVE)) === 0.0
end


@testset "the keyed state series must be dispatch-interval series on the five-minute grid" begin
    check = AustralianElectricityMarketsSimulations._check_state_series_alignment
    sys = System(100.0)
    bus = _st_bus()
    add_component!(sys, bus)
    gen = _st_thermal("aligned", bus)
    add_component!(sys, gen)
    AustralianElectricityMarkets.attach_nem_unit_data!(sys, gen)
    add_time_series!(sys, gen, _st_series("initial_mw", fill(50.0, 7)))
    observed(gen, name) = AustralianElectricityMarkets.NEMObservedState(;
        initial_mw = _st_key(gen, name), dispatch_mode = 4,
    )
    AustralianElectricityMarkets.set_observed_state!(gen, observed(gen, "initial_mw"))
    @test isnothing(check(gen))

    # A five-minute series off the grid cannot name the interval it starts.
    off_grid = [DateTime(2025, 1, 1, 0, 2, 30) + k * Minute(5) for k in 0:6]
    add_time_series!(sys, gen, SingleTimeSeries(; name = "off_grid", data = TimeArray(off_grid, fill(50.0, 7))))
    AustralianElectricityMarkets.set_observed_state!(gen, observed(gen, "off_grid"))
    @test_throws r"not aligned to the 5 minutes dispatch interval" check(gen)

    # A longer resolution cannot supply a value for every dispatch interval.
    half_hour = collect(DateTime(2025, 1, 1):Minute(30):DateTime(2025, 1, 1, 3))
    add_time_series!(sys, gen, SingleTimeSeries(; name = "half_hourly", data = TimeArray(half_hour, fill(50.0, length(half_hour)))))
    AustralianElectricityMarkets.set_observed_state!(gen, observed(gen, "half_hourly"))
    @test_throws r"resolution 30 minutes, expected 5 minutes" check(gen)
end


@testset "a starting output at the enablement maximum keeps the offer enabled" begin
    # Park City's starting output equals its RAISE6SEC enablement maximum (95 MW), which the stranded
    # pre-condition keeps enabled (`EnablementMin <= output <= EnablementMax`). The build seed must
    # scale the state the way the FCAS accessor scales the trapezium; one rounding step above the
    # bound would disable the offer.
    sys = fcas_toy_system(park_initial = [95.0, 95.0], park_trap = (5.0, 10.0, 90.0, 95.0, 25.0))
    model = PSI.DecisionModel(
        replay_template(sys), sys; optimizer = _ST_OPTIMIZER, horizon = TOY_RESOLUTION,
        resolution = TOY_RESOLUTION, interval = TOY_RESOLUTION, initial_time = TOY_START,
    )
    @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
    container = PSI.get_optimization_container(model)
    park_limit = PSI.get_parameter(container, PSI.ParameterKey(AEMS.FCASOfferLimitParameter, ThermalStandard, "RAISE6SEC"))

    PSI.set_execution_count!(model, 0)
    PSI.solve_impl!(model)
    @test PSI.get_run_status(model) == PSI.RunStatus.SUCCESSFULLY_FINALIZED
    @test vec(Array(PSI.get_parameter_column_values(park_limit, TOY_EXPENSIVE))) ≈ [0.25, 0.05, 0.95]
end
