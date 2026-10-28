# Validates a Market Price Cap override given as a PSI model attribute or setting.
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
cap is `rate` when given, else [`_container_market_price_cap`](@ref) at the container's initial time:
a simulation keeps the cap of its first interval, since its range lies within one financial year.

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
    for name in names, t in PSI.get_time_steps(container)
        PSI.add_to_objective_invariant_expression!(container, cost * slack[name, t])
    end
    return
end


"""
    _service_market_price_cap(service_model, container, t::DateTime) -> Float64

The `"market_price_cap"` attribute of `service_model` when set, else
[`_container_market_price_cap`](@ref)`(container, t)`.

# Returns
A `\$/MWh` value.
"""
function _service_market_price_cap(service_model::PSI.ServiceModel, container::PSI.OptimizationContainer, t::DateTime)
    rate = get(PSI.get_attributes(service_model), "market_price_cap", nothing)
    return isnothing(rate) ? _container_market_price_cap(container, t) : _checked_market_price_cap(rate)
end


"""
    _container_market_price_cap(container, t::DateTime) -> Float64

The `"market_price_cap"` entry of the model's `PSI.get_ext(PSI.get_settings(model))`, or
[`_financial_year_mpc`](@ref)`(t)` if unset. The cap of every penalty priced by
[`_add_mpc_penalty!`](@ref), and the fallback of [`_service_market_price_cap`](@ref).

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
    PSI.objective_function!(container, sys, network_model::PSI.NetworkModel{PSI.AreaBalancePowerModel})

Override of `PowerSimulations.jl`'s `AreaBalancePowerModel` slack objective, which prices
`SystemBalanceSlackUp`/`SystemBalanceSlackDown` at the fixed `BALANCE_SLACK_COST`. Prices each
slack at [`AREA_BALANCE_CVP_FACTOR`](@ref) times the Market Price Cap of the build's initial financial
year, or the `"market_price_cap"` entry of the model's settings `ext`
([`_container_market_price_cap`](@ref)), in `\$/MW` per dispatch interval. Throws for a financial
year absent from `MARKET_PRICE_CAP_BY_FINANCIAL_YEAR` with no override. `AreaPTDFPowerModel` keeps
PSI's flat `BALANCE_SLACK_COST`.

# Returns
`nothing`.
"""
function PSI.objective_function!(
        container::PSI.OptimizationContainer, sys::PSY.System,
        network_model::PSI.NetworkModel{PSI.AreaBalancePowerModel},
    )
    areas = PSY.get_name.(PSI.get_available_components(network_model, PSY.Area, sys))
    _add_mpc_penalty!(container, PSI.SystemBalanceSlackDown, PSY.Area, areas, AREA_BALANCE_CVP_FACTOR)
    _add_mpc_penalty!(container, PSI.SystemBalanceSlackUp, PSY.Area, areas, AREA_BALANCE_CVP_FACTOR)
    return nothing
end
