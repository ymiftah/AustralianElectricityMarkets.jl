# Per-step updates of the state-dependent parameters. Each toy system is built as a decision model at
# each of its stamps, the parameter update runs once, and every parameter of the state-update types is
# snapshotted. Later changes to how those parameters are refreshed must reproduce these snapshots.

const STATE_UPDATE_PARAMETER_TYPES = (
    InitialPowerTimeSeriesParameter,
    RampUpRateTimeSeriesParameter,
    RampDownRateTimeSeriesParameter,
    FixedLoadTimeSeriesParameter,
    FixedLoadInvokedTimeSeriesParameter,
    FCASOfferLimitParameter,
    FCASBandWidthParameter,
    FCASUpperSlopeParameter,
    FCASLowerSlopeParameter,
    FCASRampingLimitParameter,
    MNSPInitialFlowParameter,
    MNSPForwardRampRateParameter,
    MNSPReverseRampRateParameter,
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

# Builds a decision model of `template` on `sys` at `t`, runs one parameter update and returns the
# snapshot of each state-update parameter, keyed by its container key.
function _state_update_snapshot(sys, template, t::DateTime)
    model = PSI.DecisionModel(
        AEMS.NEMDispatchProblem, template, sys; optimizer = HiGHS.Optimizer, initial_time = t, name = "state_update",
    )
    status = PSI.build!(model; output_dir = mktempdir())
    status == PSI.ModelBuildStatus.BUILT || error("The state-update model at $t failed to build ($status).")
    _update_step_parameters!(model)
    container = PSI.get_optimization_container(model)
    snapshot = Dict{PSI.ParameterKey, Matrix{Float64}}(
        key => _parameter_values(container, key) for key in keys(PSI.get_parameters(model)) if _is_state_update_key(key)
    )
    steps = length(PSI.get_time_steps(container))
    @test all(values -> size(values, 2) == steps, values(snapshot))
    return snapshot
end

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

# The three toy systems that together carry all thirteen state-update parameter types: the FCAS
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
