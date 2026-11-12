# Per-step updates of the state-dependent parameters. The reference is the custom path, forced by a test
# switch: the stock path, which `ObservedState` uses, must write the same values. No snapshot is stored.

const STATE_UPDATE_PARAMETER_TYPES = (
    InitialPowerTimeSeriesParameter,
    RampRateTimeSeriesParameter,
    FixedLoadTimeSeriesParameter,
    FixedLoadInvokedTimeSeriesParameter,
    FCASOfferLimitParameter,
    FCASBandWidthParameter,
    FCASUpperSlopeParameter,
    FCASLowerSlopeParameter,
    FCASRampingLimitParameter,
    MNSPOperatingParameter,
)

const STATE_UPDATE_STEPS = TOY_START:TOY_RESOLUTION:(TOY_START + TOY_RESOLUTION)

# The parameter type of a container key, from the key's type parameters.
_parameter_type(key::PSI.ParameterKey) = first(typeof(key).parameters)

_is_state_update_key(key::PSI.ParameterKey) = any(T -> _parameter_type(key) === T, STATE_UPDATE_PARAMETER_TYPES)

# The values a parameter holds, as a matrix: the last axis is the time steps, and any additional axes
# (such as the FCAS offer fields) are stacked along the rows.
function _parameter_values(container, key::PSI.ParameterKey)
    data = PSI.get_parameter_array_data(PSI.get_parameter(container, key))
    values = eltype(data) <: Float64 ? copy(data) : Float64[JuMP.fix_value(x) for x in data]
    return reshape(values, :, size(values, ndims(values)))
end

# Builds a decision model of `template` on `sys` at `t` and runs one parameter update on it.
function _state_update_model(sys, template, t::DateTime)
    model = PSI.DecisionModel(
        AEMS.NEMDispatchProblem, template, sys; optimizer = HiGHS.Optimizer, initial_time = t, name = "state_update",
    )
    status = PSI.build!(model; output_dir = mktempdir())
    status == PSI.ModelBuildStatus.BUILT || error("The state-update model at $t failed to build ($status).")
    _update_step_parameters!(model)
    return model
end

# Builds the model at `t` and returns the snapshot of each state-update parameter, keyed by its container key.
function _state_update_snapshot(sys, template, t::DateTime)
    model = _state_update_model(sys, template, t)
    container = PSI.get_optimization_container(model)
    snapshot = Dict{PSI.ParameterKey, Matrix{Float64}}(
        key => _parameter_values(container, key) for key in keys(PSI.get_parameters(model)) if _is_state_update_key(key)
    )
    steps = length(PSI.get_time_steps(container))
    @test all(values -> size(values, 2) == steps, values(snapshot))
    return snapshot
end

# The snapshot at `t` on the custom path (`custom = true`) or the stock path, and the number of custom
# per-step writes the update made.
function _snapshot_on_path(sys, template, t::DateTime; custom::Bool)
    previous = AEMS._FORCE_CUSTOM_STATE_UPDATES[]
    AEMS._FORCE_CUSTOM_STATE_UPDATES[] = custom
    calls = AEMS._CUSTOM_STATE_UPDATE_CALLS[]
    try
        snapshot = _state_update_snapshot(sys, template, t)
        return snapshot, AEMS._CUSTOM_STATE_UPDATE_CALLS[] - calls
    finally
        AEMS._FORCE_CUSTOM_STATE_UPDATES[] = previous
    end
end

# A label for a container key that is stable across models built from the same system.
_key_label(key::PSI.ParameterKey) = (string(typeof(key)), key.meta)

# One snapshot per step of `steps`, each from a decision model built at that step's stamp.
function run_steps!(sys, template, steps)
    return [_state_update_snapshot(sys, template, t) for t in steps]
end

# Toy system with an MNSP link in both directions, as the stock simulation tests build it.
function state_update_mnsp_system()
    units = [
        TOY_CHEAP => toy_unit(300.0, [(300.0, 20.0)]; initial = 100.0, ramp_up = 100.0),
        "Solitude" => toy_unit(200.0, [(200.0, 50.0)]; initial = 50.0, ramp_up = 100.0),
    ]
    forward = [(200.0, [(30.0, 10.0), (100.0, 40.0)]), (60.0, [(100.0, 5.0)])]
    reverse_link = (100.0, [(100.0, 10.0)])
    return nem_toy_system(
        units, 50.0; horizon = TOY_RESOLUTION,
        interchange = toy_interchange(; load_mw = 80.0, breakpoints = [-1000.0, 1000.0], mnsp = (forward, reverse_link)),
    )
end

# Toy system whose cheap unit bids a fixed loading on its generation side, as the energy limit tests do.
function state_update_fixed_load_system()
    return nem_toy_system(
        [
            TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = 60.0, ramp_up = 100.0, availability = 45.0),
            TOY_EXPENSIVE => toy_unit(100.0, [(100.0, 80.0)]; initial = 20.0, ramp_up = 100.0),
        ],
        80.0; horizon = TOY_RESOLUTION,
        mutate! = function (sys, stamps)
            cheap = PSY.get_component(ThermalStandard, sys, TOY_CHEAP)
            _toy_energy_bid!(
                sys, cheap, AustralianElectricityMarkets.BidDirection.GEN, stamps,
                fill(PSY.PiecewiseStepData([0.0, 100.0], [20.0]), 2), [45.0, 45.0];
                fixed_load = [60.0, 60.0],
            )
            return
        end,
    )
end

# The three toy systems that together carry all ten state-update parameter types: the FCAS
# system (a battery bidding both regulation sides, a scheduled load), the MNSP system and the fixed-loading system.
const STATE_UPDATE_SYSTEMS = (
    "fcas" => fcas_toy_system,
    "mnsp" => state_update_mnsp_system,
    "fixed_load" => state_update_fixed_load_system,
)

@testset "state-update parameters are finite and sized by their steps, for every toy system" begin
    seen = Set{DataType}()
    for (name, build) in STATE_UPDATE_SYSTEMS
        sys = build()
        template = replay_template(sys)
        snapshots = run_steps!(sys, template, STATE_UPDATE_STEPS)
        @test length(snapshots) == length(STATE_UPDATE_STEPS)
        for snapshot in snapshots
            @test !isempty(snapshot)
            for (key, values) in snapshot
                push!(seen, _parameter_type(key))
                @test all(isfinite, values)
                @test size(values, 1) >= 1
                @test size(values, 2) >= 1
            end
        end
        @info "state-update snapshot" system = name parameters = length(first(snapshots))
    end
    @test seen == Set{DataType}(collect(STATE_UPDATE_PARAMETER_TYPES))
end

@testset "observed path equals the custom path" begin
    for (name, build) in STATE_UPDATE_SYSTEMS
        sys = build()
        template = replay_template(sys)
        for t in STATE_UPDATE_STEPS
            stock, stock_calls = _snapshot_on_path(sys, template, t; custom = false)
            custom, custom_calls = _snapshot_on_path(sys, template, t; custom = true)
            @test stock_calls == 0
            @test custom_calls > 0
            stock_by_label = Dict(_key_label(key) => values for (key, values) in stock)
            custom_by_label = Dict(_key_label(key) => values for (key, values) in custom)
            @test Set(keys(stock_by_label)) == Set(keys(custom_by_label))
            for (label, values) in custom_by_label
                @test isapprox(stock_by_label[label], values; atol = 1.0e-12, rtol = 0)
            end
        end
    end
end

@testset "stock and custom paths agree over two executions of one model" begin
    covered = Set{DataType}()
    for (name, build) in STATE_UPDATE_SYSTEMS
        sys = build()
        template = replay_template(sys)
        model = PSI.DecisionModel(
            AEMS.NEMDispatchProblem, template, sys; optimizer = HiGHS.Optimizer, initial_time = TOY_START, name = "state_update",
        )
        @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
        container = PSI.get_optimization_container(model)
        state_keys = [key for key in keys(PSI.get_parameters(model)) if _is_state_update_key(key)]
        union!(covered, _parameter_type.(state_keys))
        previous = AEMS._FORCE_CUSTOM_STATE_UPDATES[]
        try
            for execution in (0, 1)
                PSI.set_execution_count!(model, execution)
                AEMS._FORCE_CUSTOM_STATE_UPDATES[] = false
                _update_step_parameters!(model)
                stock = Dict(_key_label(key) => _parameter_values(container, key) for key in state_keys)
                AEMS._FORCE_CUSTOM_STATE_UPDATES[] = true
                _update_step_parameters!(model)
                for key in state_keys
                    @test isapprox(stock[_key_label(key)], _parameter_values(container, key); atol = 1.0e-12, rtol = 0)
                end
            end
        finally
            AEMS._FORCE_CUSTOM_STATE_UPDATES[] = previous
        end
        @info "two-execution comparison" system = name parameters = length(state_keys)
    end
    @test covered == Set{DataType}(collect(STATE_UPDATE_PARAMETER_TYPES))
end

@testset "stock update applies the FCAS slope coefficients" begin
    sys = fcas_toy_system()
    template = replay_template(sys)
    checked = 0
    for t in STATE_UPDATE_STEPS
        model = _state_update_model(sys, template, t)
        container = PSI.get_optimization_container(model)
        for key in keys(PSI.get_parameters(model))
            _parameter_type(key) in (FCASUpperSlopeParameter, FCASLowerSlopeParameter) || continue
            param = PSI.get_parameter(container, key)
            data = PSI.get_parameter_array_data(param)
            multipliers = PSI.get_multiplier_array_data(param)
            for target in PSI.get_coefficient_targets(PSI.get_attributes(param))
                expected = target.scale * data[target.param_row, target.time_step] * multipliers[target.multiplier_row, target.time_step]
                @test isapprox(PSI.JuMP.normalized_coefficient(target.constraint, target.variable), expected; atol = 1.0e-12, rtol = 0)
                checked += 1
            end
        end
    end
    @test checked > 0
end

@testset "observed path reads the inputs prepared at build" begin
    later_key = Ref{Any}(nothing)
    sys = nem_toy_system(
        [
            TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = 50.0, ramp_up = 100.0),
            TOY_EXPENSIVE => toy_unit(100.0, [(100.0, 80.0)]; initial = 50.0, ramp_up = 100.0),
        ],
        100.0; horizon = TOY_RESOLUTION,
        mutate! = function (sys, stamps)
            alta = PSY.get_component(ThermalStandard, sys, TOY_CHEAP)
            replace_single_series_with!(sys, alta, "later_initial_mw", [50.0, 10.0], stamps)
            later_key[] = AustralianElectricityMarkets._series_key(alta, "later_initial_mw")
            return
        end,
    )
    model = PSI.DecisionModel(
        replay_template(sys), sys; optimizer = HiGHS.Optimizer, horizon = TOY_RESOLUTION,
        resolution = TOY_RESOLUTION, interval = TOY_RESOLUTION, initial_time = TOY_START,
    )
    @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
    container = PSI.get_optimization_container(model)
    initial = PSI.get_parameter(container, PSI.ParameterKey(InitialPowerTimeSeriesParameter, ThermalStandard))

    PSI.set_execution_count!(model, 0)
    _update_step_parameters!(model)
    PSI.solve_impl!(model)
    @test only(PSI.get_parameter_column_values(initial, TOY_CHEAP)) === 50.0

    alta = PSY.get_component(ThermalStandard, PSI.get_system(model), TOY_CHEAP)
    AustralianElectricityMarkets.set_observed_state!(
        alta,
        AustralianElectricityMarkets.NEMObservedState(;
            initial_mw = later_key[],
            dispatch_mode = AustralianElectricityMarkets.get_observed_state(alta).dispatch_mode,
        ),
    )
    PSI.set_execution_count!(model, 1)
    _update_step_parameters!(model)
    PSI.solve_impl!(model)
    @test PSI.get_run_status(model) == PSI.RunStatus.SUCCESSFULLY_FINALIZED
    @test only(PSI.get_parameter_column_values(initial, TOY_CHEAP)) === 50.0
end

@testset "FCAS step cache is not shared across models or rebuilds" begin
    sys = fcas_toy_system()
    template = replay_template(sys)
    fcas_types = (FCASOfferLimitParameter, FCASBandWidthParameter, FCASUpperSlopeParameter, FCASLowerSlopeParameter, FCASRampingLimitParameter)
    function build_model()
        model = PSI.DecisionModel(
            AEMS.NEMDispatchProblem, template, sys; optimizer = HiGHS.Optimizer, initial_time = TOY_START, name = "state_update",
        )
        @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
        PSI.set_execution_count!(model, 0)
        return model
    end
    # The (device, bid type) pairs the FCAS parameters of `model` read, counted once however many parameters read them.
    function fcas_pair_count(model)
        container = PSI.get_optimization_container(model)
        pairs = Set{Tuple}()
        for key in keys(PSI.get_parameters(model)), name in keys(PSI.get_parameter_attributes(container, key).component_name_to_ts_uuid)
            _parameter_type(key) in fcas_types || continue
            push!(pairs, (name, first(AEMS._fcas_meta_offer(key.meta))))
        end
        return length(pairs)
    end

    first_model = build_model()
    second_model = build_model()
    expected = fcas_pair_count(first_model)
    @test expected > 0

    previous = AEMS._FORCE_CUSTOM_STATE_UPDATES[]
    AEMS._FORCE_CUSTOM_STATE_UPDATES[] = true
    try
        AEMS._FCAS_EVALUATIONS[] = 0
        _update_step_parameters!(first_model)
        @test AEMS._FCAS_EVALUATIONS[] == expected

        AEMS._FCAS_EVALUATIONS[] = 0
        _update_step_parameters!(second_model)
        @test AEMS._FCAS_EVALUATIONS[] == expected

        PSI.reset!(first_model)
        @test PSI.build!(first_model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
        PSI.set_execution_count!(first_model, 0)
        AEMS._FCAS_EVALUATIONS[] = 0
        _update_step_parameters!(first_model)
        @test AEMS._FCAS_EVALUATIONS[] == expected
    finally
        AEMS._FORCE_CUSTOM_STATE_UPDATES[] = previous
    end
end

@testset "custom path computes each FCAS derivation once per step" begin
    sys = fcas_toy_system()
    template = replay_template(sys)
    model = PSI.DecisionModel(
        AEMS.NEMDispatchProblem, template, sys; optimizer = HiGHS.Optimizer, initial_time = TOY_START, name = "state_update",
    )
    @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
    container = PSI.get_optimization_container(model)
    fcas_types = (FCASOfferLimitParameter, FCASBandWidthParameter, FCASUpperSlopeParameter, FCASLowerSlopeParameter, FCASRampingLimitParameter)
    fcas_keys = [key for key in keys(PSI.get_parameters(model)) if _parameter_type(key) in fcas_types]
    # Each (device, bid type) pair the FCAS parameters read, counted once however many parameters read it.
    pairs = Set{Tuple}()
    for key in fcas_keys
        bid_type = first(AEMS._fcas_meta_offer(key.meta))
        for name in keys(PSI.get_parameter_attributes(container, key).component_name_to_ts_uuid)
            push!(pairs, (name, bid_type))
        end
    end
    @test !isempty(pairs)

    previous = AEMS._FORCE_CUSTOM_STATE_UPDATES[]
    AEMS._FORCE_CUSTOM_STATE_UPDATES[] = true
    try
        # Execution `n` of the model is the step at `TOY_START + n * TOY_RESOLUTION`, so each is compared
        # with the stock snapshot of that stamp.
        for (execution, stamp) in zip((0, 1), STATE_UPDATE_STEPS)
            stock, _ = _snapshot_on_path(sys, template, stamp; custom = false)
            stock_by_label = Dict(_key_label(key) => values for (key, values) in stock)
            PSI.set_execution_count!(model, execution)
            AEMS._FCAS_EVALUATIONS[] = 0
            _update_step_parameters!(model)
            @test AEMS._FCAS_EVALUATIONS[] == length(pairs)
            for key in fcas_keys
                @test isapprox(stock_by_label[_key_label(key)], _parameter_values(container, key); atol = 1.0e-12, rtol = 0)
            end
        end
    finally
        AEMS._FORCE_CUSTOM_STATE_UPDATES[] = previous
    end
end
