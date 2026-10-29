"""
The optional families of [`replication_template`](@ref) that its `parts` argument selects:
`:batteries` (`PSY.Storage` devices under [`AbstractNEMDispatch`](@ref)), `:fcas` (an
[`FCASMarket`](@ref) per `FCASService`), `:losses` ([`NEMInterconnectorLoss`](@ref) on each
`PSY.AreaInterchange`), `:tie_breaks` (the [`TieBreakMarket`](@ref) service model) and
`:generic_constraints` (a [`LinearFactorLimit`](@ref) per `GenericConstraint`).
"""
const REPLICATION_PARTS = (:batteries, :fcas, :losses, :tie_breaks, :generic_constraints)


"""
    replication_template(sys; initial_time = nothing, market_price_cap = nothing, skipped = nothing, parts = REPLICATION_PARTS, exclude_constraints = Dict{String, Symbol}()) -> PSI.ProblemTemplate

Builds the `ProblemTemplate` that replicates NEMDE on `sys`: [`AbstractNEMDispatch`](@ref) devices
(via [`set_nem_dispatch_models!`](@ref)), `PSI.StaticPowerLoad` demand, [`NEMInterconnectorLoss`](@ref)
on every `PSY.AreaInterchange`, an [`FCASMarket`](@ref) per registered `FCASService`, and a
[`LinearFactorLimit`](@ref) per `GenericConstraint` with an available contributing device.
Regions balance through `PSI.AreaBalancePowerModel` with slacks priced at the Market Price Cap of
`initial_time` (see [`_area_balance_network_model`](@ref)), and the balance duals are recorded as
regional prices. Price-tied energy bands are dispatched pro rata by the
[`TieBreakMarket`](@ref) service model when `sys` carries the [`EnergyTieBreak`](@ref) of
[`set_tie_break_scales!`](@ref). `parts` selects the [`REPLICATION_PARTS`](@ref) to model; without
`:losses` no `PSY.AreaInterchange` is modeled and the regions are uncoupled.

# Arguments
- `sys`: a populated `PSY.System` with attached replay inputs, such as one created through
  `NEMDEConfiguration` and prepared with [`prepare_replay_forecasts!`](@ref).
- `initial_time`: the first interval of the build, which dates the Market Price Cap of the slacks;
  default the earliest forecast window of `sys`.
- `market_price_cap`: a Market Price Cap that replaces the one dated by `initial_time`, or `nothing`.
- `skipped`: a vector that receives one `(constraint, reason, n_missing)` named tuple per generic
  constraint left out of the template, or `nothing`. `reason` is `:no_available_device` when all
  its contributing devices are unavailable, the `exclude_constraints` reason, or, when `parts`
  leaves out a family the constraint's terms need, `:unmodeled_fcas_service` or
  `:unmodeled_device_type`.
- `parts`: the [`REPLICATION_PARTS`](@ref) to model; default all.
- `exclude_constraints`: a `Dict` from the names of `GenericConstraint`s of `sys` to leave out to
  the `reason` each is recorded with in `skipped`; default empty. These constraints are excluded
  before term buildability is checked.

# Returns
A `PSI.ProblemTemplate`. Throws `ArgumentError` before model construction on an unknown part, an
unknown excluded constraint, missing inputs of a modeled family (missing dispatch constraint
intervals, skipped constraints, dropped terms, defaulted penalty weights, missing dispatch-limit
series, incomplete MNSP offers), a generic constraint the template cannot model for a reason other
than a left-out part, and `:tie_breaks` without `:batteries` when a battery carries tie-break scales.
"""
function replication_template(
        sys::PSY.System; initial_time::Union{Nothing, DateTime} = nothing, market_price_cap = nothing,
        skipped::Union{Nothing, AbstractVector} = nothing, parts = REPLICATION_PARTS,
        exclude_constraints::AbstractDict{<:AbstractString, Symbol} = Dict{String, Symbol}(),
    )
    _check_replication_parts(parts)
    _check_replay_system_inputs(sys, parts)
    start = isnothing(initial_time) ? _first_forecast_time(sys) : initial_time
    template = PSI.ProblemTemplate(
        _area_balance_network_model(
            sys, start; market_price_cap = market_price_cap, duals = [PSI.CopperPlateBalanceConstraint],
        ),
    )
    _set_replication_device_models!(template, sys, parts)
    PSI.set_device_model!(template, PSY.PowerLoad, PSI.StaticPowerLoad)
    :losses in parts && PSI.set_device_model!(template, PSY.AreaInterchange, NEMInterconnectorLoss)
    if :fcas in parts
        for svc in PSY.get_components(FCASService, sys)
            if !(:batteries in parts)
                devices = filter(PSY.get_available, PSY.get_contributing_devices(sys, svc))
                !isempty(devices) && all(d -> d isa PSY.Storage, devices) && continue
            end
            name = PSY.get_name(svc)
            PSI.set_service_model!(
                template, name,
                PSI.ServiceModel(FCASService, FCASMarket, name; duals = [FCASJointCapacityConstraint], use_slacks = true),
            )
        end
    end
    :generic_constraints in parts &&
        _set_generic_constraint_models!(template, sys, parts, skipped, exclude_constraints)
    return template
end


function _check_replication_parts(parts)
    unknown = setdiff(parts, REPLICATION_PARTS)
    isempty(unknown) || throw(
        ArgumentError("replication_template: unknown parts $(Tuple(unknown)); choose from $REPLICATION_PARTS."),
    )
    return
end


# The earliest forecast window of `sys`, the build's initial interval when none is given.
function _first_forecast_time(sys::PSY.System)
    times = PSY.get_forecast_initial_times(sys)
    isempty(times) && throw(ArgumentError("replication_template: sys has no forecast windows; pass initial_time."))
    return minimum(times)
end


# Dispatch device models and, with `:tie_breaks`, the tie-break service model; storage only with `:batteries`.
function _set_replication_device_models!(template::PSI.ProblemTemplate, sys::PSY.System, parts)
    tie_breaks = :tie_breaks in parts
    :batteries in parts && return set_nem_dispatch_models!(template, sys; tie_breaks = tie_breaks)
    service = PSY.get_component(EnergyTieBreak, sys, TIE_BREAK_SERVICE_NAME)
    if tie_breaks && !isnothing(service)
        scaled = sort!(
            [
                PSY.get_name(d) for d in PSY.get_contributing_devices(sys, service)
                    if d isa PSY.Storage && PSY.get_available(d) &&
                    any(k -> startswith(IS.get_name(k), "tie_break_scale_"), IS.get_time_series_keys(d))
            ],
        )
        isempty(scaled) || throw(
            ArgumentError(
                "replication_template: parts include :tie_breaks but not :batteries, and the batteries " *
                    "$(join(scaled, ", ")) carry tie-break scales; add :batteries to parts or leave out :tie_breaks.",
            ),
        )
    end
    types = filter(T -> !(T <: PSY.Storage), nem_dispatch_participants(sys))
    foreach(T -> PSI.set_device_model!(template, T, NEMReplayDispatch), types)
    tie_breaks && !isnothing(service) && PSI.set_service_model!(
        template, TIE_BREAK_SERVICE_NAME, PSI.ServiceModel(EnergyTieBreak, TieBreakMarket, TIE_BREAK_SERVICE_NAME),
    )
    return types
end


# Unbuildable reasons a left-out part causes: FCAS terms without `:fcas`.
function _left_out_part_reasons(parts)
    reasons = Set{Symbol}()
    :fcas in parts || push!(reasons, :unmodeled_fcas_service)
    return reasons
end


# Device types whose terms a left-out part makes unmodeled: storage without `:batteries`, interchange without `:losses`.
function _left_out_part_types(parts)
    types = DataType[]
    :batteries in parts || push!(types, PSY.Storage)
    :losses in parts || push!(types, PSY.AreaInterchange)
    return types
end


function _set_generic_constraint_models!(
        template::PSI.ProblemTemplate, sys::PSY.System, parts, skipped, exclude_constraints,
    )
    unknown = sort!([n for n in keys(exclude_constraints) if isnothing(PSY.get_component(GenericConstraint, sys, n))])
    isempty(unknown) || throw(
        ArgumentError(
            "replication_template: exclude_constraints names $(join(unknown, ", ")), which are not GenericConstraints of sys.",
        ),
    )
    tolerated = _left_out_part_reasons(parts)
    tolerated_types = _left_out_part_types(parts)
    blocked = @NamedTuple{constraint::String, reason::Symbol}[]
    rows = @NamedTuple{constraint::String, reason::Symbol, n_missing::Int}[]
    excluded = similar(rows, 0)
    candidates = GenericConstraint[]
    for gc in PSY.get_components(GenericConstraint, sys)
        PSY.get_available(gc) || continue
        name = PSY.get_name(gc)
        if haskey(exclude_constraints, name)
            push!(excluded, (constraint = name, reason = exclude_constraints[name], n_missing = 0))
        else
            push!(candidates, gc)
        end
    end
    buildable = _filter_buildable_generic_constraints(
        sys, template, candidates; allow_partial_coverage = !isempty(tolerated) || !isempty(tolerated_types),
        skipped = rows, tolerated_reasons = tolerated, tolerated_types = tolerated_types, blocked = blocked,
    )
    blocking = blocked
    isempty(blocking) || throw(
        ArgumentError(
            "replication_template: generic constraints the template cannot model: " *
                "$(join(("$(r.constraint) ($(r.reason))" for r in blocking), ", ")).",
        ),
    )
    append!(rows, excluded)
    sort!(rows; by = r -> r.constraint)
    isnothing(skipped) || append!(skipped, rows)
    for gc in buildable
        name = PSY.get_name(gc)
        PSI.set_service_model!(
            template, name,
            PSI.ServiceModel(
                GenericConstraint, LinearFactorLimit, name; duals = [NEMConstraintLimit], use_slacks = true,
            ),
        )
    end
    return
end


"""
    REPLICATION_OPTIMIZER

The default replay optimizer: HiGHS with zero MIP gap tolerances, since the interconnector loss
encoding makes each interval a MILP.
"""
const REPLICATION_OPTIMIZER = JuMP.optimizer_with_attributes(
    HiGHS.Optimizer, "mip_rel_gap" => 0.0, "mip_abs_gap" => 1.0e-10,
)


# A one-interval `DecisionModel` of `template` on `sys` from `initial_time`.
# The model's settings carry the same cap as its network model, so every MPC penalty of a replay is
# priced at one value; a template priced at another cap is refused.
function _replication_decision_model(
        template::PSI.ProblemTemplate, sys::PSY.System, initial_time::DateTime;
        optimizer = REPLICATION_OPTIMIZER, name = "replication", market_price_cap = nothing,
    )
    cap = _resolved_market_price_cap(initial_time, market_price_cap)
    slack_cost = PSI.get_slack_cost(PSI.get_network_model(template))
    slack_cost == _area_balance_slack_cost(sys, cap) || throw(
        ArgumentError(
            "replication model: the template prices balance slacks at a Market Price Cap other than $cap; " *
                "pass the same market_price_cap to replication_template and to the model.",
        ),
    )
    model = PSI.DecisionModel(
        template, sys;
        optimizer = optimizer, horizon = DISPATCH_INTERVAL, resolution = DISPATCH_INTERVAL,
        interval = DISPATCH_INTERVAL, initial_time = initial_time, name = name,
    )
    PSI.get_ext(PSI.get_settings(model))["market_price_cap"] = cap
    return model
end


# Logs the skipped-constraint count by reason and the table, for a build or solve that failed.
function _log_skipped_constraints(skipped::DataFrame)
    by_reason = combine(groupby(skipped, :reason), nrow => :n)
    counts = join(("$(r.reason)=$(r.n)" for r in eachrow(sort(by_reason, :reason))), ", ")
    @error "Skipped constraints at failure: $(nrow(skipped)) ($counts)" skipped
    return
end
