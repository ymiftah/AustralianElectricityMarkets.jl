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
    # its step-2 ceiling is 15 MW. The state source's keyed series, not the series the state was
    # first read from, carries the step-2 value the update must find.
    sys = nem_toy_system(
        [
            TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = [50.0, 10.0], ramp_up = [2.0, 1.0]),
            TOY_EXPENSIVE => toy_unit(100.0, [(100.0, 80.0)]; initial = [50.0, 50.0], ramp_up = 100.0),
        ],
        100.0; horizon = TOY_RESOLUTION,
        mutate! = function (sys, stamps)
            alta = PSY.get_component(ThermalStandard, sys, TOY_CHEAP)
            replace_single_series_with!(sys, alta, "observed_initial_mw", [50.0, 50.0], stamps)
            replace_single_series_with!(sys, alta, "state_initial_mw", [50.0, 10.0], stamps)
            observed = get_observed_state(alta)
            set_observed_state!(
                alta,
                AustralianElectricityMarkets.NEMObservedState(;
                    initial_mw = AustralianElectricityMarkets._series_key(alta, "state_initial_mw"),
                    dispatch_mode = observed.dispatch_mode,
                ),
            )
            return
        end,
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
            # The shape an old build wrote: Park held at 40 MW in both steps. It is not read; the
            # parameter comes from the bid and the step's dispatch mode.
            replace_single_series_with!(sys, park, "fixed_load", [0.4, 0.4], stamps)
            replace_single_series_with!(sys, park, "fixed_load_invoked", [1.0, 1.0], stamps)
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


# A test-only objective coefficient: the device's `"toy_state_price"`, $/MWh, added to the objective
# of every step from the state source. Its update mirrors what a formulation would register.
struct ToyStatePriceParameter <: PSI.ObjectiveFunctionParameter end

PSI._param_to_vars(::ToyStatePriceParameter, ::AEMS.NEMReplayDispatch) = (PSI.ActivePowerVariable,)

PSI.get_multiplier_value(::ToyStatePriceParameter, ::PSY.StaticInjection, ::AEMS.NEMReplayDispatch) = 1.0

function PSI.update_container_parameter_values!(
        container::PSI.OptimizationContainer,
        model::PSI.OperationModel,
        key::PSI.ParameterKey{ToyStatePriceParameter, T},
        ::PSI.DatasetContainer{PSI.InMemoryDataset},
    ) where {T <: PSY.StaticInjection}
    parameter_array = PSI.get_parameter_array(container, key)
    power = PSI.get_variable(container, PSI.ActivePowerVariable(), T)
    scale = PSI.get_base_power(container) * AEMS.interval_cost_coefficient(1.0, PSI.get_resolution(model))
    system = PSI.get_system(model)
    for name in axes(parameter_array)[1]
        device = PSY.get_component(T, system, name)
        series = AustralianElectricityMarkets._series_key(device, "toy_state_price")
        for t in PSI.get_time_steps(container)
            price = only(PSI.IS.get_time_series_values(device, series; start_time = PSI.get_current_timestamp(model) + (t - 1) * PSI.get_resolution(model), len = 1))
            parameter_array[name, t] = price
            PSI.add_to_objective_variant_expression!(container, price * scale, power[name, t])
        end
    end
    return
end

@testset "a per-step state price survives the objective unsynchronisation" begin
    stamps = [TOY_START, TOY_START + TOY_RESOLUTION]
    sys = nem_toy_system(
        [TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = 100.0, ramp_up = 100.0)],
        100.0; horizon = TOY_RESOLUTION,
        mutate! = (sys, stamps) -> replace_single_series_with!(sys, PSY.get_component(ThermalStandard, sys, TOY_CHEAP), "toy_state_price", [12.0, 60.0], stamps),
    )
    template = replay_template(sys)
    model = PSI.DecisionModel(
        template, sys;
        optimizer = _ST_OPTIMIZER, horizon = TOY_RESOLUTION, resolution = TOY_RESOLUTION,
        interval = TOY_RESOLUTION, initial_time = TOY_START,
    )
    @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
    container = PSI.get_optimization_container(model)

    unit = PSY.get_component(ThermalStandard, sys, TOY_CHEAP)
    names = Dict{Type{<:PSI.ParameterType}, String}(PSI.get_time_series_names(PSI.get_model(template, ThermalStandard)))
    names[ToyStatePriceParameter] = "toy_state_price"
    PSI.add_parameters!(container, ToyStatePriceParameter, [unit], PSI.DeviceModel(ThermalStandard, AEMS.NEMReplayDispatch; time_series_names = names))
    price = PSI.get_parameter(container, PSI.ParameterKey(ToyStatePriceParameter, ThermalStandard))
    @test eltype(PSI.get_parameter_array(price)) === Float64

    objectives = Float64[]
    for (i, _) in enumerate(stamps)
        PSI.set_execution_count!(model, i - 1)
        _update_step_parameters!(model)
        PSI.solve_impl!(model)
        @test PSI.get_run_status(model) == PSI.RunStatus.SUCCESSFULLY_FINALIZED
        push!(objectives, PSI.JuMP.objective_value(PSI.get_jump_model(container)))
    end
    # 100 MW at the unit's $20/MWh offer plus the state price of the step.
    @test objectives[1] ≈ 3200.0 / 12 atol = 1.0e-4
    @test objectives[2] ≈ 8000.0 / 12 atol = 1.0e-4
    @test PSI.get_parameter_array(price)[TOY_CHEAP, 1] === 60.0
    power = PSI.get_variable(container, PSI.ActivePowerVariable(), ThermalStandard)[TOY_CHEAP, 1]
    @test PSI.JuMP.coefficient(PSI.get_variant_terms(PSI.get_objective_expression(container)), power) ≈ 60.0 * 100.0 / 12
end


@testset "the build's fixed-load series and the per-step derivation agree" begin
    # One FIXEDLOAD row per device and interval feeds the build's series; the same MW in the bids
    # feeds the per-step derivation. They must agree on the netting and invocation rules.
    derivation_range = TOY_START:TOY_RESOLUTION:(TOY_START + 2 * TOY_RESOLUTION)
    sys = nem_toy_system(
        [TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = 50.0, ramp_up = 100.0)],
        60.0; horizon = TOY_RESOLUTION,
        batteries = [TOY_BATTERY => toy_battery(50.0, 30.0, 50.0, 0.0; initial = 5.0, ramp_up = 100.0)],
        mutate! = function (sys, stamps)
            alta = PSY.get_component(ThermalStandard, sys, TOY_CHEAP)
            _toy_energy_bid!(
                sys, alta, AustralianElectricityMarkets.BidDirection.GEN, stamps,
                fill(_toy_offer([(100.0, 20.0)]), length(stamps)), fill(100.0, length(stamps));
                fixed_load = fill(40.0, length(stamps)),
            )
            battery = PSY.get_component(EnergyReservoirStorage, sys, TOY_BATTERY)
            _toy_energy_bid!(
                sys, battery, AustralianElectricityMarkets.BidDirection.GEN, stamps,
                fill(PSY.PiecewiseStepData([0.0, 50.0], [30.0]), length(stamps)), fill(50.0, length(stamps));
                fixed_load = fill(10.0, length(stamps)),
            )
            _toy_energy_bid!(
                sys, battery, AustralianElectricityMarkets.BidDirection.LOAD, stamps,
                fill(PSY.PiecewiseStepData([0.0, 50.0], [0.0]), length(stamps)), fill(50.0, length(stamps));
                fixed_load = fill(4.0, length(stamps)),
            )
            rows = DataFrame(
                DUID = [TOY_CHEAP, TOY_CHEAP, TOY_BATTERY, TOY_BATTERY, TOY_BATTERY, TOY_BATTERY],
                DIRECTION = ["GEN", "GEN", "GEN", "GEN", "LOAD", "LOAD"],
                FIXEDLOAD = [40.0, 40.0, 10.0, 10.0, 4.0, 4.0],
                INTERVAL_DATETIME = [stamps; stamps; stamps],
                IN_PROFILE = fill(false, 6),
            )
            AustralianElectricityMarkets._set_nem_fixed_loads!(sys, rows, derivation_range)

            base_power = PSY.get_base_power(sys)
            for device in (alta, battery)
                series = PSY.get_time_series(PSY.SingleTimeSeries, device, "fixed_load")
                derived = collect(values(PSY.get_time_series_array(device, series)))
                per_step = [step.target / base_power for step in AustralianElectricityMarkets._fixed_load_step_series(device, stamps)]
                @test derived ≈ per_step
                @test !all(iszero, derived)
            end
            return
        end,
    )
end


@testset "each step's FCAS enablement and ramping limit are recomputed from the state" begin
    # Park City moves from 40 MW to 200 MW, outside its RAISE6SEC enablement band, so its offer is
    # disabled at step 2. The battery's starting output rises from 5 MW to 10 MW, so its regulation
    # joint ramping limit rises by the same 5 MW. Both differ from the build's seed.
    inactive = FCAS_INACTIVE_LIMIT_MW / 100.0
    sys = fcas_toy_system(park_initial = [40.0, 200.0], batt_initial = [5.0, 10.0])
    model = PSI.DecisionModel(
        replay_template(sys), sys; optimizer = _ST_OPTIMIZER, horizon = TOY_RESOLUTION,
        resolution = TOY_RESOLUTION, interval = TOY_RESOLUTION, initial_time = TOY_START,
    )
    @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
    container = PSI.get_optimization_container(model)
    park_limit = PSI.get_parameter(container, PSI.ParameterKey(AEMS.FCASOfferLimitParameter, ThermalStandard, "RAISE6SEC"))
    battery_ramp = PSI.get_parameter(container, PSI.ParameterKey(AEMS.FCASRampingLimitParameter, EnergyReservoirStorage, "RAISEREG"))

    PSI.set_execution_count!(model, 0)
    PSI.solve_impl!(model)
    @test PSI.get_run_status(model) == PSI.RunStatus.SUCCESSFULLY_FINALIZED
    # The additional axis is the field list: max_avail, enablement_min, enablement_max.
    @test vec(Array(PSI.get_parameter_column_values(park_limit, TOY_EXPENSIVE))) ≈ [0.25, 0.05, 1.0]
    @test vec(Array(PSI.get_parameter_column_values(battery_ramp, TOY_BATTERY))) ≈ [0.25, 0.2]

    PSI.set_execution_count!(model, 1)
    _update_step_parameters!(model)
    PSI.solve_impl!(model)
    @test PSI.get_run_status(model) == PSI.RunStatus.SUCCESSFULLY_FINALIZED
    @test vec(Array(PSI.get_parameter_column_values(park_limit, TOY_EXPENSIVE))) ≈ [0.0, -inactive, inactive]
    @test vec(Array(PSI.get_parameter_column_values(battery_ramp, TOY_BATTERY))) ≈ [0.3, 0.2]
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
