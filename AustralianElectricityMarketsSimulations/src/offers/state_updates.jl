# Per-step updates of the parameters that read a unit's or link's state. The shared helpers live
# here; the energy, FCAS and MNSP families live in `offers/state_updates/`. PowerSimulations clears
# the objective's variant terms first.

"""
    _step_stamp(model, t) -> DateTime

The stamp of step `t` of `model`'s current horizon; `t = 1` is the horizon's first step.

# Arguments
- `model`: the `PowerSimulations.OperationModel` whose step is being solved.
- `t`: the step index.

# Returns
A `DateTime`.
"""
function _step_stamp(model::PSI.OperationModel, t::Integer)
    return (PSI.get_current_timestamp(model)::DateTime) + (t - 1) * (PSI.get_resolution(model)::Millisecond)
end


# Whether the per-step update takes the stock path: the observed series already hold each value.
_use_stock_state_update() = _precomputes_state_inputs(_state_source()) && !_FORCE_CUSTOM_STATE_UPDATES[]

# Counts the custom per-step writes, so a test can check that the stock path runs none.
const _CUSTOM_STATE_UPDATE_CALLS = Ref(0)

# The `(offers, ramping)` pair of `_fcas_effective_values` for one device and bid type.
const _FCASDerivation = Tuple{Dict{Bool, Vector{NTuple{15, Float64}}}, Union{Nothing, Vector{NTuple{2, Float64}}}}

# The FCAS derivations of one model step, keyed by device UUID and bid type.
struct _StepCache
    timestamp::DateTime
    execution::Int
    fcas::Dict{Tuple{Base.UUID, BidType}, _FCASDerivation}
end

const _STEP_CACHE_KEY = "state_step_cache"

# The cache of `model`'s current step, held in the model's `ext` and replaced when the step changes.
# A step is its timestamp and execution count, so the parameters of one update share one derivation.
function _step_cache(model::PSI.OperationModel)
    timestamp = PSI.get_current_timestamp(model)::DateTime
    execution = PSI.get_execution_count(model)
    ext = PSI.get_ext(model)
    cache = get(ext, _STEP_CACHE_KEY, nothing)
    if !(cache isa _StepCache) || cache.timestamp != timestamp || cache.execution != execution
        cache = _StepCache(timestamp, execution, Dict{Tuple{Base.UUID, BidType}, _FCASDerivation}())
        ext[_STEP_CACHE_KEY] = cache
    end
    return cache
end

# Runs the pinned fork's stock update for `key`. A coefficient parameter's stock method also applies its targets.
function _stock_state_update!(
        container::PSI.OptimizationContainer, model::PSI.OperationModel,
        key::PSI.ParameterKey{<:PSI.ConstraintCoefficientParameter, <:PSY.Component}, input::PSI.DatasetContainer{PSI.InMemoryDataset},
    )
    invoke(
        PSI.update_container_parameter_values!,
        Tuple{
            PSI.OptimizationContainer, PSI.OperationModel,
            PSI.ParameterKey{<:PSI.ConstraintCoefficientParameter, <:PSY.Component}, PSI.DatasetContainer{PSI.InMemoryDataset},
        },
        container, model, key, input,
    )
    return
end

function _stock_state_update!(
        container::PSI.OptimizationContainer, model::PSI.OperationModel,
        key::PSI.ParameterKey{<:PSI.ParameterType, <:PSY.Component}, input::PSI.DatasetContainer{PSI.InMemoryDataset},
    )
    invoke(
        PSI.update_container_parameter_values!,
        Tuple{
            PSI.OptimizationContainer, PSI.OperationModel,
            PSI.ParameterKey{<:PSI.ParameterType, <:PSY.Component}, PSI.DatasetContainer{PSI.InMemoryDataset},
        },
        container, model, key, input,
    )
    return
end

"""
    _update_state_parameters!(value_at, container, model, key) -> nothing

Writes `value_at(device, stamp)` into every row of the time-series parameter `key` at every step of
`model`'s horizon, in the units its multiplier scales. Only the devices the parameter was built for
are written. Throws when a value is not finite.

# Arguments
- `value_at`: `(device, stamp) -> Float64`, the value before the multiplier.
- `container`: the `PowerSimulations.OptimizationContainer` being updated.
- `model`: the `PowerSimulations.OperationModel` whose step is being solved.
- `key`: the `PowerSimulations.ParameterKey` of the parameter to update.

# Returns
`nothing`.
"""
function _update_state_parameters!(value_at::F, container::PSI.OptimizationContainer, model::PSI.OperationModel, key::PSI.ParameterKey{P, T}) where {F, P, T}
    _CUSTOM_STATE_UPDATE_CALLS[] += 1
    parameter_array = PSI.get_parameter_array(container, key)
    parent_param = PSI.get_parameter_array_data(PSI.get_parameter(container, key))
    attributes = PSI.get_parameter_attributes(container, key)
    uuids::Dict{String, String} = attributes.component_name_to_ts_uuid
    _write_state_rows!(value_at, P, T, model, PSI.get_time_steps(container), parameter_array, parent_param, uuids)
    return
end

# Writes the rows of each named device, in a function of the concrete array and value types.
function _write_state_rows!(value_at::F, ::Type{P}, ::Type{T}, model, steps, parameter_array, parent_param, uuids::Dict{String, String}) where {F, P, T}
    system = PSI.get_system(model)
    for (name, uuid) in uuids
        device = PSY.get_component(T, system, name)::T
        i = parameter_array.lookup[1][uuid]
        for t in steps
            stamp = _step_stamp(model, t)
            value = Float64(value_at(device, stamp))
            isfinite(value) || error(
                "The value of $(nameof(P)) for \"$(name)\" at $(stamp) is not finite. " *
                    "Check that the unit's state and bids are valid.",
            )
            PSI._set_param_value_at!(parent_param, value, i, t)
        end
    end
    return
end


"""
    PSI.update_container_parameter_values!(container, model, key, input)

Refreshes [`InitialPowerTimeSeriesParameter`](@ref) from each device's [`NEMUnitState`](@ref) at the
step, read through the configured [`StateSource`](@ref). The value is the unit's starting MW, which the parameter's
multiplier converts to system-base per-unit.

# Arguments
- `container`: the `PowerSimulations.OptimizationContainer` being updated.
- `model`: the `PowerSimulations.OperationModel` whose step is being solved.
- `key`: the `PowerSimulations.ParameterKey` of the parameter, over the device's type.
- `input`: the simulation state, which these methods do not read.

# Returns
`nothing`.
"""
function PSI.update_container_parameter_values!(
        container::PSI.OptimizationContainer,
        model::PSI.OperationModel,
        key::PSI.ParameterKey{InitialPowerTimeSeriesParameter, T},
        input::PSI.DatasetContainer{PSI.InMemoryDataset},
    ) where {T <: PSY.StaticInjection}
    _use_stock_state_update() && return _stock_state_update!(container, model, key, input)
    _update_state_parameters!(container, model, key) do device, stamp
        return unit_state(_state_source(), device, stamp).initial_mw
    end
    return
end


# The value of `device`'s series `key` at `stamp`; a static value is returned as stored.
function _key_value(device, key::IS.TimeSeriesKey, stamp::DateTime)
    return Float64(only((IS.get_time_series_values(device, key; start_time = stamp, len = 1)::Vector{Float64})))
end

function _key_value(device, key::Real, stamp::DateTime)
    return Float64(key)
end
