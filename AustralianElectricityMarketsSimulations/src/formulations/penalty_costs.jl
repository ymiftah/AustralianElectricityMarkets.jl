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
    checked_rate = isnothing(rate) ? nothing : _checked_market_price_cap(rate)
    penalty = (; slack, names = collect(names), cvp_factor = Float64(cvp_factor), rate = checked_rate)
    push!(_mpc_penalties(container), penalty)
    _register_mpc_repricing!(container, time_steps)
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
    _register_mpc_repricing!(container, time_steps)

Registers, once per container, the [`MarketPriceCapPenaltyParameter`](@ref) that triggers
[`_reprice_mpc_penalties!`](@ref) at each simulation step. Called by [`_add_mpc_penalty!`](@ref),
so any network model that records a penalty gets re-priced at every step.

# Returns
`nothing`.
"""
function _register_mpc_repricing!(container::PSI.OptimizationContainer, time_steps)
    haskey(PSI.get_parameters(container), PSI.ParameterKey(MarketPriceCapPenaltyParameter, PSY.Area)) && return
    param = PSI.add_param_container!(
        container, MarketPriceCapPenaltyParameter(), PSY.Area,
        (PSI.SystemBalanceSlackUp, PSI.SystemBalanceSlackDown), PSI.SOSStatusVariable.NO_VARIABLE,
        false, Float64, ["market_price_cap"], time_steps,
    )
    # The container only triggers the update; PSI requires every cell to hold a value.
    PSI.get_parameter_array(param) .= 0.0
    PSI.get_multiplier_array(param) .= 1.0
    return
end


"""
    _set_service_mpc_rate!(container, name, rate)

Records a finite, strictly positive Market Price Cap `rate` for the service `name`, when it is not `nothing`.

# Returns
`nothing`.
"""
function _set_service_mpc_rate!(container::PSI.OptimizationContainer, name::AbstractString, rate)
    isnothing(rate) || (_mpc_record(container).service_rates[String(name)] = _checked_market_price_cap(rate))
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
    variable_up = PSI.get_variable(container, PSI.SystemBalanceSlackUp(), PSY.Area)
    variable_dn = PSI.get_variable(container, PSI.SystemBalanceSlackDown(), PSY.Area)
    areas = PSY.get_name.(PSI.get_available_components(network_model, PSY.Area, sys))
    time_steps = PSI.get_time_steps(container)
    _add_mpc_penalty!(container, variable_dn, areas, time_steps, AREA_BALANCE_CVP_FACTOR)
    _add_mpc_penalty!(container, variable_up, areas, time_steps, AREA_BALANCE_CVP_FACTOR)
    return nothing
end


"""
    PSI._update_parameter_values!(parameter_array, ::MarketPriceCapPenaltyParameter, parameter_multiplier, attributes, ::Type{PSY.Area}, model, input)

Override of `PowerSimulations.jl`'s private objective-parameter update for the
[`MarketPriceCapPenaltyParameter`](@ref) registered on `PSY.Area`, which has no device model for
the generic method to look up. Re-prices every Market Price Cap penalty slack of the model for the
step's window.

# Returns
`nothing`.
"""
function PSI._update_parameter_values!(
        ::PSI.DenseAxisArray, ::MarketPriceCapPenaltyParameter, ::PSI.JuMPFloatArray,
        ::PSI.CostFunctionAttributes, ::Type{PSY.Area}, model::PSI.DecisionModel,
        ::PSI.DatasetContainer{PSI.InMemoryDataset},
    )
    container = PSI.get_optimization_container(model)
    PSI.is_synchronized(container) && error(
        "Cannot update MarketPriceCapPenaltyParameter on a synchronized container; objective expressions would be double-counted",
    )
    _reprice_mpc_penalties!(container, PSI.get_current_time(model), last(PSI.get_time_steps(container)))
    return
end
