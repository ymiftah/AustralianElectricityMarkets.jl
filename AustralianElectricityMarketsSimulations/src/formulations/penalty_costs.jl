# The `MarketPriceCapPenaltyParameter` meta of the slack container keyed `(V, T, meta)`, and back.
_mpc_parameter_meta(::Type{V}, meta::String) where {V} = isempty(meta) ? string(nameof(V)) : "$(nameof(V))_$(meta)"
_mpc_slack_meta(::Type{V}, parameter_meta::String) where {V} = String(chopprefix(chopprefix(parameter_meta, string(nameof(V))), "_"))


"""
    _add_mpc_penalty!(container, V, T, names, cvp_factor; meta, rate = nothing)

Prices the slack variables of the container keyed `(V, T, meta)` for `names` at `cvp_factor` times
the Market Price Cap per MW of one dispatch interval. With a `rate`, the cap is that fixed value and
the cost is invariant. Otherwise each interval takes its own cap
([`_container_market_price_cap`](@ref)) through a [`MarketPriceCapPenaltyParameter`](@ref) of meta
[`_mpc_parameter_meta`](@ref), whose values are the caps and whose multiplier is `cvp_factor` times
the system base power times the interval length in hours, re-priced at each simulation step.

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
    slack = PSI.get_variable(container, V(), T, meta)
    time_steps = PSI.get_time_steps(container)
    coefficient = PSI.get_base_power(container) * interval_cost_coefficient(cvp_factor, PSI.get_resolution(container))
    if !isnothing(fixed_rate)
        cost = coefficient * fixed_rate
        for name in names, t in time_steps
            PSI.add_to_objective_invariant_expression!(container, cost * slack[name, t])
        end
        return
    end
    param = PSI.add_param_container!(
        container, MarketPriceCapPenaltyParameter(), T, (V,), PSI.SOSStatusVariable.NO_VARIABLE,
        false, Float64, collect(names), time_steps; meta = _mpc_parameter_meta(V, meta),
    )
    fill!(PSI.get_multiplier_array(param), coefficient)
    _price_mpc_penalty!(container, PSI.get_parameter_array(param), PSI.get_multiplier_array(param), slack, PSI.get_initial_time(container))
    return
end


# Writes each interval's cap from `initial_time` into `caps` and adds `caps x multiplier x slack` to the variant objective.
function _price_mpc_penalty!(container::PSI.OptimizationContainer, caps, multiplier, slack, initial_time::DateTime)
    resolution = PSI.get_resolution(container)
    for t in axes(caps)[2]
        mpc = _container_market_price_cap(container, initial_time + resolution * (t - 1))
        for name in axes(caps)[1]
            caps[name, t] = mpc
            PSI.add_to_objective_variant_expression!(container, mpc * multiplier[name, t] * slack[name, t])
        end
    end
    return
end


"""
    PSI.update_container_parameter_values!(container, model, key::PSI.ParameterKey{MarketPriceCapPenaltyParameter}, input)

Simulation-step update of a [`MarketPriceCapPenaltyParameter`](@ref): writes each interval's Market
Price Cap for the window at the model's current time and re-adds its slack costs to the variant
objective.

# Returns
`nothing`.
"""
function PSI.update_container_parameter_values!(
        container::PSI.OptimizationContainer, model::PSI.OperationModel,
        key::PSI.ParameterKey{MarketPriceCapPenaltyParameter, T}, ::PSI.DatasetContainer{PSI.InMemoryDataset},
    ) where {T <: PSY.Component}
    return _update_mpc_penalty!(container, model, key)
end
function PSI.update_container_parameter_values!(
        container::PSI.OptimizationContainer, model::PSI.OperationModel,
        key::PSI.ParameterKey{MarketPriceCapPenaltyParameter, T}, ::PSI.DatasetContainer{PSI.InMemoryDataset},
    ) where {T <: PSY.Service}
    return _update_mpc_penalty!(container, model, key)
end


function _update_mpc_penalty!(container::PSI.OptimizationContainer, model::PSI.OperationModel, key::PSI.ParameterKey{MarketPriceCapPenaltyParameter, T}) where {T}
    PSI.is_synchronized(container) && error(
        "Cannot update MarketPriceCapPenaltyParameter on a synchronized container; the penalty costs would be added twice.",
    )
    V = only(PSI.get_variable_types(PSI.get_parameter_attributes(container, key)))
    slack = PSI.get_variable(container, V(), T, _mpc_slack_meta(V, key.meta))
    _price_mpc_penalty!(
        container, PSI.get_parameter_array(container, key), PSI.get_parameter_multiplier_array(container, key),
        slack, PSI.get_current_time(model),
    )
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
    _financial_year_mpc(t::DateTime) -> Float64

The published Market Price Cap for the financial year of the dispatch interval ending at `t` (a
`SETTLEMENTDATE`). The interval ending 00:00 on 1 July runs 23:55-00:00 on 30 June, so it takes the
earlier year's cap.

# Returns
A `\$/MWh` value.
"""
function _financial_year_mpc(t::DateTime)
    start = t - DISPATCH_INTERVAL
    year_start = Date(year(start) - (month(start) < 7), 7, 1)
    idx = findfirst(p -> p[1] == year_start, MARKET_PRICE_CAP_BY_FINANCIAL_YEAR)
    isnothing(idx) && throw(
        ArgumentError(
            "No published Market Price Cap covers $t; extend MARKET_PRICE_CAP_BY_FINANCIAL_YEAR " *
                "or set the \"market_price_cap\" entry of `PSI.get_ext(PSI.get_settings(model))`.",
        ),
    )
    return MARKET_PRICE_CAP_BY_FINANCIAL_YEAR[idx][2]
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


function _checked_market_price_cap(rate)
    value = rate isa Real ? Float64(rate) : NaN
    isfinite(value) && value > 0.0 ||
        throw(ArgumentError("market_price_cap must be finite and strictly positive, got $rate."))
    return value
end


"""
    PSI.objective_function!(container, sys, network_model::PSI.NetworkModel{PSI.AreaBalancePowerModel})

Override of `PowerSimulations.jl`'s `AreaBalancePowerModel` slack objective, which prices
`SystemBalanceSlackUp`/`SystemBalanceSlackDown` at the fixed `BALANCE_SLACK_COST`. Prices each
slack at [`AREA_BALANCE_CVP_FACTOR`](@ref) times the Market Price Cap of the interval's financial
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
