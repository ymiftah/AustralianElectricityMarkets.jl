# Validates a Market Price Cap override given as a settings entry.
function _checked_market_price_cap(rate)
    value = rate isa Real ? Float64(rate) : NaN
    isfinite(value) && value > 0.0 ||
        throw(ArgumentError("market_price_cap must be finite and strictly positive, got $rate."))
    return value
end


"""
    _add_mpc_penalty!(container, V, T, names, cvp_factor; meta, rate = nothing)

Prices the slack variables of the container keyed `(V, T, meta)` for `names` at `cvp_factor` times
the Market Price Cap per MW of one dispatch interval, as a constant of the invariant objective. The
cap is `rate` when given, else [`_container_market_price_cap`](@ref) at the container's initial time.

# Arguments
- `container`: the `PSI.OptimizationContainer` being built.
- `V`, `T`, `meta`: the key of the slack variable container, indexed `[name, t]`, in system-base per-unit.
- `names`: the names of the slack container to price.
- `cvp_factor`: the AEMO CVP factor of the constraint the slack relaxes.
- `rate`: a Market Price Cap that replaces the dated one, or `nothing`.

# Returns
`nothing`.
"""
function _add_mpc_penalty!(
        container::PSI.OptimizationContainer, ::Type{V}, ::Type{T}, names, cvp_factor::Real;
        meta::String = IS.Optimization.CONTAINER_KEY_EMPTY_META, rate = nothing,
    ) where {V <: PSI.VariableType, T <: PSY.Component}
    fixed_rate = isnothing(rate) ? nothing : _checked_market_price_cap(rate)
    isempty(names) && return
    cap = isnothing(fixed_rate) ? _container_market_price_cap(container, PSI.get_initial_time(container)) : fixed_rate
    slack = PSI.get_variable(container, V(), T, meta)
    cost = PSI.get_base_power(container) * interval_cost_coefficient(cvp_factor, PSI.get_resolution(container)) * cap
    invariant = _invariant_objective(container)
    for name in names, t in PSI.get_time_steps(container)
        JuMP.add_to_expression!(invariant, cost, slack[name, t])
    end
    return
end


"""
    _container_market_price_cap(container, t::DateTime) -> Float64

The `"market_price_cap"` entry of the model's `PSI.get_ext(PSI.get_settings(model))`, or
[`_financial_year_mpc`](@ref)`(t)` if unset. The cap of every penalty priced by
[`_add_mpc_penalty!`](@ref).

# Arguments
  - `container`: the `PSI.OptimizationContainer` being built.
  - `t`: the interval's timestamp.

# Returns
A finite, strictly positive `\$/MWh` value; invalid overrides throw `ArgumentError`.
"""
function _container_market_price_cap(container::PSI.OptimizationContainer, t::DateTime)
    rate = get(PSI.get_ext(PSI.get_settings(container)), "market_price_cap", nothing)
    return _checked_market_price_cap(isnothing(rate) ? _financial_year_mpc(t) : rate)
end


"""
    _resolved_market_price_cap(t::DateTime, market_price_cap = nothing) -> Float64

The Market Price Cap of a build whose first interval is `t`: `market_price_cap` when given, else
[`_financial_year_mpc`](@ref)`(t)`. A run resolves its cap once through this function; `validate_template` writes the result to the
model's `"market_price_cap"` setting, which prices every penalty of the build.

# Returns
A finite, strictly positive `\$/MWh` value; invalid overrides throw `ArgumentError`, and a financial
year absent from `MARKET_PRICE_CAP_BY_FINANCIAL_YEAR` with no override throws.
"""
function _resolved_market_price_cap(t::DateTime, market_price_cap = nothing)
    isnothing(market_price_cap) && return _financial_year_mpc(t)
    return _checked_market_price_cap(market_price_cap)
end


"""
    _area_balance_network_model(; duals = Vector{DataType}()) -> PSI.NetworkModel{PSI.AreaBalancePowerModel}

The `AreaBalancePowerModel` network model of a run, with PSI's own balance slacks on. A build with a
formulation of this package that adds [`AreaBalanceSlack`](@ref) replaces them at the Market Price Cap.

# Arguments
- `duals`: the dual constraints to record on the network model.

# Returns
A `PSI.NetworkModel{PSI.AreaBalancePowerModel}`.
"""
function _area_balance_network_model(; duals = Vector{DataType}())
    return PSI.NetworkModel(PSI.AreaBalancePowerModel; use_slacks = true, duals = duals)
end
