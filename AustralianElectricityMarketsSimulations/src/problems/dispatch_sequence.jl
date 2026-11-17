"""
    nem_dispatch_sequence(::Type{M}, template, sys; name = "dispatch", commitment_name = FAST_START_COMMITMENT_NAME, fast_start = true, ini_cond_chronology = PSI.InterProblemChronology(), kwargs...) where {M <: AbstractNEMDispatchProblem} -> NamedTuple

The decision models of a NEM dispatch run of `template` on `sys` and the `PSI.SimulationSequence` that runs
them. When an available unit of a non-battery device type that `template` models under an
[`AbstractNEMDispatch`](@ref) formulation has a fast-start profile (`has_fast_start_profile`), every interval runs
NEMDE's two dispatch runs at the same timestamp. The commitment run, named `commitment_name`, leaves out the energy
ramp rows of the fast-start units starting in mode 0, 1 or 2. The dispatch run, named `name`, reads the commitment
run's energy targets through a `PSI.FixValueFeedforward` and holds each fast-start unit to the inflexibility
profile of its end mode, elastic at `FAST_START_CVP_FACTOR` times the Market Price Cap, with the ramp rows of that
end mode. Prices and results are the dispatch run's. Without a fast-start unit, or with `fast_start = false`, the
sequence holds one model, named `name`, built as [`PSI.DecisionModel{M}`](@ref) builds it, with no inflexibility
profile.

# Arguments
- `M`: [`NEMDispatchProblem`](@ref) or [`NEMClosedLoopDispatchProblem`](@ref).
- `template`: a `PSI.ProblemTemplate`, e.g. [`template_nemde`](@ref)`()`; each model builds from its own copy.
- `sys`: the NEMDE system, built by `nem_system(db, NEMDEConfiguration(); date_range)`.
- `name`: the name of the dispatch run, whose results a run reads.
- `commitment_name`: the name of the commitment run.
- `fast_start`: run NEMDE's two fast-start runs when `sys` has a fast-start unit; `false` builds the single model.
- `ini_cond_chronology`: the initial-condition chronology of the sequence.
- `kwargs...`: keyword arguments of [`PSI.DecisionModel{M}`](@ref), e.g. `optimizer`, `initial_time` and
  `market_price_cap`, given to both models.

# Returns
A `NamedTuple` of `models` (the `PSI.SimulationModels`), `sequence` (the `PSI.SimulationSequence`), `dispatch`
(the dispatch run's `PSI.DecisionModel{M}`) and `commitment` (the commitment run's model, or `nothing` for a
single model).

# Example
```julia
(; models, sequence, dispatch) = nem_dispatch_sequence(NEMDispatchProblem, template_nemde(), sys;
    optimizer = nemde_optimizer(), initial_time = first(steps))
simulation = PSI.Simulation(; name = "run", steps = length(steps), models, sequence,
    simulation_folder = mktempdir(), initial_time = first(steps))
```
"""
function nem_dispatch_sequence(
        ::Type{M}, template::PSI.ProblemTemplate, sys::PSY.System;
        name = "dispatch", commitment_name = FAST_START_COMMITMENT_NAME, fast_start::Bool = true,
        ini_cond_chronology = PSI.InterProblemChronology(), kwargs...,
    ) where {M <: AbstractNEMDispatchProblem}
    haskey(kwargs, :fast_start_run) &&
        throw(ArgumentError("nem_dispatch_sequence: `fast_start_run` is set by the sequence and cannot be given"))
    types = fast_start ? _fast_start_device_types(template, sys) : DataType[]
    if isempty(types)
        dispatch = PSI.DecisionModel{M}(template, sys; name, kwargs...)
        models = PSI.SimulationModels(; decision_models = [dispatch])
        sequence = PSI.SimulationSequence(; models, ini_cond_chronology)
        return (; models, sequence, dispatch, commitment = nothing)
    end
    string(commitment_name) == string(name) &&
        throw(ArgumentError("nem_dispatch_sequence: the two runs need different names, got \"$name\" for both"))
    commitment = PSI.DecisionModel{M}(template, sys; name = commitment_name, fast_start_run = :commitment, kwargs...)
    dispatch = PSI.DecisionModel{M}(template, sys; name, fast_start_run = :dispatch, kwargs...)
    PSI.get_ext(PSI.get_settings(dispatch))["fast_start_feedforward"] = true
    models = PSI.SimulationModels(; decision_models = [commitment, dispatch])
    feedforwards = Dict(
        string(name) => [
            PSI.FixValueFeedforward(;
                component_type = T, source = PSI.ActivePowerVariable,
                affected_values = [FastStartCommitmentTargetParameter],
            )
                for T in types
        ],
    )
    sequence = PSI.SimulationSequence(; models, feedforwards, ini_cond_chronology)
    return (; models, sequence, dispatch, commitment)
end


"""
    _fast_start_device_types(template, sys) -> Vector{DataType}

The non-battery device types `template` models under an [`AbstractNEMDispatch`](@ref) formulation that have an
available unit with a fast-start profile in `sys` (`has_fast_start_profile`).

# Returns
A sorted `Vector{DataType}`, empty when `sys` has no such unit.
"""
function _fast_start_device_types(template::PSI.ProblemTemplate, sys::PSY.System)
    types = DataType[]
    for model in values(PSI.get_device_models(template))
        T = PSI.get_component_type(model)
        (PSI.get_formulation(model) <: AbstractNEMDispatch && !(T <: PSY.Storage)) || continue
        any(has_fast_start_profile, PSY.get_components(PSY.get_available, T, sys)) && push!(types, T)
    end
    return sort!(types; by = string)
end
