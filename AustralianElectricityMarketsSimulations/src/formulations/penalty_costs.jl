# The penalties and service rate overrides recorded for `container`'s current JuMP model, kept in its
# settings `ext`; a rebuilt model starts a fresh record.
function _mpc_record(container::PSI.OptimizationContainer)
    ext = PSI.get_ext(PSI.get_settings(container))
    jm = PSI.get_jump_model(container)
    record = get(ext, "mpc_record", nothing)
    if isnothing(record) || record.model !== jm
        record = (; model = jm, penalties = NamedTuple[], service_rates = Dict{String, Float64}())
        ext["mpc_record"] = record
    end
    return record
end

_mpc_penalties(container::PSI.OptimizationContainer) = _mpc_record(container).penalties


"""
    _add_mpc_penalty!(container, slack, names, time_steps, cvp_factor; rate = nothing)

Prices the `slack` container at `cvp_factor` times the Market Price Cap per MW of one dispatch
interval, in the variant objective, and records it so [`MarketPriceCapPenaltyParameter`](@ref)
re-prices it at each simulation step. The cap of interval `t` is `rate` when given, else
[`_container_market_price_cap`](@ref) at that interval's timestamp.

# Arguments
- `container`: the `PSI.OptimizationContainer` being built.
- `slack`: the slack variable container, indexed `[name, t]`, in system-base per-unit.
- `names`, `time_steps`: the names and time steps of `slack` to price.
- `cvp_factor`: the AEMO CVP factor of the constraint the slack relaxes.
- `rate`: a Market Price Cap that replaces the dated one, or `nothing`.

# Returns
`nothing`.
"""
function _add_mpc_penalty!(container::PSI.OptimizationContainer, slack, names, time_steps, cvp_factor::Real; rate = nothing)
    penalty = (; slack, names = collect(names), cvp_factor = Float64(cvp_factor), rate)
    push!(_mpc_penalties(container), penalty)
    _price_mpc_penalty!(container, penalty, PSI.get_initial_time(container), time_steps)
    return
end


# Adds `penalty`'s slack costs for `time_steps`, the first of which starts at `initial_time`.
function _price_mpc_penalty!(container::PSI.OptimizationContainer, penalty, initial_time::DateTime, time_steps)
    resolution = PSI.get_resolution(container)
    base_power = PSI.get_base_power(container)
    for t in time_steps
        mpc = isnothing(penalty.rate) ? _container_market_price_cap(container, initial_time + resolution * (t - 1)) : penalty.rate
        coefficient = base_power * interval_cost_coefficient(penalty.cvp_factor * mpc, resolution)
        for name in penalty.names
            PSI.add_to_objective_variant_expression!(container, penalty.slack[name, t] * coefficient)
        end
    end
    return
end


"""
    _reprice_mpc_penalties!(container, initial_time, horizon)

Re-adds the variant objective cost of every slack recorded by [`_add_mpc_penalty!`](@ref) for the
window of `horizon` intervals starting at `initial_time`, each at its own interval's Market Price Cap.

# Returns
`nothing`.
"""
function _reprice_mpc_penalties!(container::PSI.OptimizationContainer, initial_time::DateTime, horizon::Int)
    for penalty in _mpc_penalties(container)
        _price_mpc_penalty!(container, penalty, initial_time, 1:horizon)
    end
    return
end


"""
    _register_mpc_repricing!(container, areas, time_steps)

Registers the [`MarketPriceCapPenaltyParameter`](@ref) that triggers
[`_reprice_mpc_penalties!`](@ref) at each simulation step, on the `PSY.Area` components `areas`.

# Returns
`nothing`.
"""
function _register_mpc_repricing!(container::PSI.OptimizationContainer, areas, time_steps)
    param = PSI.add_param_container!(
        container, MarketPriceCapPenaltyParameter(), PSY.Area,
        (PSI.SystemBalanceSlackUp, PSI.SystemBalanceSlackDown), PSI.SOSStatusVariable.NO_VARIABLE,
        false, Float64, collect(areas), time_steps,
    )
    # The container only triggers the update; PSI requires every cell to hold a value.
    PSI.get_parameter_array(param) .= 0.0
    PSI.get_multiplier_array(param) .= 1.0
    return
end


"""
    _set_service_mpc_rate!(container, name, rate)

Records the Market Price Cap `rate` that replaces the dated cap for the service `name`, when it is not `nothing`.

# Returns
`nothing`.
"""
function _set_service_mpc_rate!(container::PSI.OptimizationContainer, name::AbstractString, rate)
    isnothing(rate) || (_mpc_record(container).service_rates[String(name)] = rate)
    return
end


"""
    _service_market_price_cap(container, name, t::DateTime) -> Float64

The rate recorded by [`_set_service_mpc_rate!`](@ref) for the service `name`, else
[`_container_market_price_cap`](@ref)`(container, t)`.

# Returns
A `\$/MWh` value.
"""
function _service_market_price_cap(container::PSI.OptimizationContainer, name::AbstractString, t::DateTime)
    return get(() -> _container_market_price_cap(container, t), _mpc_record(container).service_rates, String(name))
end
