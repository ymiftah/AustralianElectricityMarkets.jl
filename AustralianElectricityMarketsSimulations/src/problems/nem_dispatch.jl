"""
    AbstractNEMDispatchProblem <: PSI.DefaultDecisionProblem

The PSI decision problems of a NEM dispatch replay interval. The concrete problem type selects the replay
mode: [`NEMDispatchProblem`](@ref) replays each interval from AEMO's observed state, and
[`NEMClosedLoopDispatchProblem`](@ref) from the previous solved interval.
"""
abstract type AbstractNEMDispatchProblem <: PSI.DefaultDecisionProblem end

"""
    NEMDispatchProblem <: AbstractNEMDispatchProblem

The open-loop NEM dispatch replay problem: every interval starts from AEMO's observed initial MW and MNSP
flows. Building it checks the template against the system and prices the area-balance slacks and every
penalty at the Market Price Cap, resolved from the model's initial time unless the model sets one.
"""
struct NEMDispatchProblem <: AbstractNEMDispatchProblem end

"""
    NEMClosedLoopDispatchProblem <: AbstractNEMDispatchProblem

The closed-loop NEM dispatch replay problem, where each interval starts from the previous solved interval.
It is not implemented yet: building a model of it throws `ArgumentError`.
"""
struct NEMClosedLoopDispatchProblem <: AbstractNEMDispatchProblem end

const _CLOSED_LOOP_UNSUPPORTED = "closed-loop replay is not implemented"
const _FIXED_TIME_SETTINGS = (:horizon, :interval, :resolution)

"""
    PSI.DecisionModel{M}(template, sys, jump_model = nothing; name = "dispatch", market_price_cap = nothing, kwargs...) where {M <: AbstractNEMDispatchProblem} -> PSI.DecisionModel{M}

Constructs the one-interval NEM dispatch model of `template` on `sys`. The horizon, resolution and interval
are one dispatch interval, and the `"closed_loop"` setting records whether `M` is
[`NEMClosedLoopDispatchProblem`](@ref). Extra keyword arguments are passed to `PSI.Settings`, e.g.
`optimizer` and `initial_time`.

# Arguments
- `template`: a `PSI.ProblemTemplate`, e.g. [`template_nemde`](@ref)`()`.
- `sys`: the system the template is checked against when the model is built.
- `jump_model`: the `JuMP.Model` to build into, or `nothing`.
- `name`: the name of the decision problem, used to retrieve its results.
- `market_price_cap`: a Market Price Cap in `\$/MWh` that replaces the one dated by the initial time, or `nothing`.
- `kwargs...`: keyword arguments of `PSI.Settings`. Passing `ext`, `horizon`, `interval` or `resolution` throws
  `ArgumentError`; use `market_price_cap` for the cap.

# Returns
A `PSI.DecisionModel{M}`. An invalid `market_price_cap` throws `ArgumentError`.
"""
function PSI.DecisionModel{M}(
        template::PSI.AbstractProblemTemplate, sys::PSY.System, jump_model::Union{Nothing, JuMP.Model} = nothing;
        name = "dispatch", market_price_cap = nothing, kwargs...,
    ) where {M <: AbstractNEMDispatchProblem}
    haskey(kwargs, :ext) &&
        throw(ArgumentError("DecisionModel{$M}: pass the Market Price Cap with `market_price_cap`, not `ext`"))
    for kw in _FIXED_TIME_SETTINGS
        haskey(kwargs, kw) && throw(
            ArgumentError("DecisionModel{$M}: `$kw` is fixed at one dispatch interval and cannot be given"),
        )
    end
    ext = Dict{String, Any}("closed_loop" => M === NEMClosedLoopDispatchProblem)
    isnothing(market_price_cap) || (ext["market_price_cap_override"] = _checked_market_price_cap(market_price_cap))
    settings = PSI.Settings(
        sys; horizon = DISPATCH_INTERVAL, resolution = DISPATCH_INTERVAL, interval = DISPATCH_INTERVAL, ext = ext, kwargs...,
    )
    return PSI.DecisionModel{M}(template, sys, settings, jump_model; name = name)
end

"""
    PSI.validate_template(model::PSI.DecisionModel{NEMClosedLoopDispatchProblem})

Refuses a closed-loop replay model, which is not implemented.

# Arguments
- `model`: the `PSI.DecisionModel{NEMClosedLoopDispatchProblem}` being built.

# Returns
Never returns; throws `ArgumentError("closed-loop replay is not implemented")`.
"""
function PSI.validate_template(::PSI.DecisionModel{NEMClosedLoopDispatchProblem})
    throw(ArgumentError(_CLOSED_LOOP_UNSUPPORTED))
end

"""
    PSI.validate_template(model::PSI.DecisionModel{NEMDispatchProblem})

Checks that the system carries forecasts and that the availability of its devices and services is the one its
replay inputs were derived for, sets the Market Price Cap and the network model's balance-slack
cost of `model`, then checks that the constraints the template excludes are constraints of the system, and runs
[`check_template_against_sys`](@ref) and [`check_fcas_services`](@ref). It throws when the template cannot model an
available `GenericConstraint` it does not tolerate, deletes the per-name `GenericConstraint` models of the constraints
the template leaves out (see [`replay_skipped_constraints`](@ref)), runs [`check_dispatch_envelope`](@ref) over the
replay intervals of the system, then the default template validation, which prunes device models with no
available devices.
The cap is the `"market_price_cap_override"` setting when set, else the one dated by the initial time, or by the
system's forecast initial timestamp when the initial time is unset. The resolved cap is written to the
`"market_price_cap"` setting on every call, so a rebuild at a later initial time re-dates it. The slack
cost is set on the model's copy of the template, not on the caller's template.

# Arguments
- `model`: the `PSI.DecisionModel{NEMDispatchProblem}` being built.

# Returns
`nothing`. Throws `ArgumentError` from the checks, when the system has no forecasts or its availability changed
after `nem_system`, or when no Market Price Cap is
published for the date. The pruning changes the model's copy of the template, not the caller's template.
"""
function PSI.validate_template(model::PSI.DecisionModel{NEMDispatchProblem})
    sys = PSI.get_system(model)
    PSY.get_time_series_counts(sys).forecast_count > 0 || throw(
        ArgumentError(
            "validate_template: the system has no forecasts; build sys with nem_system(db, NEMDEConfiguration(); date_range)",
        ),
    )
    AustralianElectricityMarkets._check_replay_availability(sys)
    template = PSI.get_template(model)
    ext = PSI.get_ext(PSI.get_settings(model))
    t = PSI.get_initial_time(model)
    t = t == PSI.UNSET_INI_TIME ? PSY.get_forecast_initial_timestamp(sys) : t
    cap = _resolved_market_price_cap(t, get(ext, "market_price_cap_override", nothing))
    ext["market_price_cap"] = cap
    PSI.get_network_model(template).slack_cost = _area_balance_slack_cost(sys, cap)
    _check_excluded_constraints(sys, template)
    check_template_against_sys(template, sys)
    check_fcas_services(template, sys)
    facts = _template_fact_rows(sys, template)
    _check_blocked_constraints(_blocked_constraints(sys, template; facts))
    _prune_generic_constraint_models!(template, Set(r.constraint for r in facts))
    check_dispatch_envelope(template, sys)
    PSI.validate_template_impl!(model)
    return
end


# Deletes the per-name `GenericConstraint` service models of `template` named in `names`.
function _prune_generic_constraint_models!(template::PSI.ProblemTemplate, names::Set{String})
    services = PSI.get_service_models(template)
    for (key, model) in collect(services)
        PSI.get_component_type(model) == GenericConstraint && first(key) in names && delete!(services, key)
    end
    return
end
