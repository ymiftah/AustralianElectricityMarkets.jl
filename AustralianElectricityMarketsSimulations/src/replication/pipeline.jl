"""
    replication_template(sys; skipped = nothing) -> PSI.ProblemTemplate

Builds the `ProblemTemplate` that replicates NEMDE on `sys`: [`AbstractNEMDispatch`](@ref) devices
(via [`set_nem_dispatch_models!`](@ref)), `PSI.StaticPowerLoad` demand, [`NEMInterconnectorLoss`](@ref)
on every `PSY.AreaInterchange`, an [`FCASMarket`](@ref) per registered `FCASService`, and a
[`LinearFactorLimit`](@ref) per `GenericConstraint` whose terms the template can model.
Regions balance through `PSI.AreaBalancePowerModel` with slacks, and the balance duals are
recorded as regional prices. Price-tied energy bands are dispatched pro rata
([`add_tie_break_constraints!`](@ref)).

# Arguments
- `sys`: a `PSY.System` from `nem_system(db, ConstrainedNetworkConfiguration(); ...)`, after its
  demand, bids, FCAS scaling inputs and dispatch limits are set.
- `skipped`: a vector that receives one `(constraint, reason, n_missing)` named tuple per generic
  constraint left out of the template, or `nothing`.

# Returns
A `PSI.ProblemTemplate`.
"""
function replication_template(sys::PSY.System; skipped::Union{Nothing, AbstractVector} = nothing)
    template = PSI.ProblemTemplate(
        PSI.NetworkModel(
            PSI.AreaBalancePowerModel;
            use_slacks = true,
            duals = [PSI.CopperPlateBalanceConstraint],
        ),
    )
    set_nem_dispatch_models!(template, sys)
    PSI.set_device_model!(template, PSY.PowerLoad, PSI.StaticPowerLoad)
    PSI.set_device_model!(template, PSY.AreaInterchange, NEMInterconnectorLoss)
    for svc in PSY.get_components(FCASService, sys)
        name = PSY.get_name(svc)
        PSI.set_service_model!(
            template, name,
            PSI.ServiceModel(FCASService, FCASMarket, name; duals = [FCASJointCapacityConstraint], use_slacks = true),
        )
    end
    for gc in filter_buildable_generic_constraints(
            sys, template; allow_partial_coverage = true, skipped = skipped,
        )
        name = PSY.get_name(gc)
        PSI.set_service_model!(
            template, name,
            PSI.ServiceModel(
                GenericConstraint, LinearFactorLimit, name; duals = [NEMConstraintLimit], use_slacks = true,
            ),
        )
    end
    return template
end

const _REPLICATION_HORIZON = 2DISPATCH_INTERVAL

"""
    replication_system(db, settlement_date; intervention = 0) -> PSY.System

Builds the `System` [`replicate_interval`](@ref) solves: the constrained system from
`nem_system(db, ConstrainedNetworkConfiguration(); ...)` over the interval and the one after it,
with demand, bids, FCAS scaling inputs and dispatch limits set and the time series transformed
into one forecast window.

# Arguments
- `db`: an `AEMDB` connection. Its cache must hold data at `settlement_date` and at
  `settlement_date + 5 minutes`, so the last cached interval cannot be replicated.
- `settlement_date`: the `SETTLEMENTDATE` of the interval (`DateTime`).
- `intervention`: 0 for the pricing run, 1 for the physical run. Applies to the constraint,
  dispatch-limit, interconnector-limit and FCAS-scaling reads; demand, bids and MNSP offers carry no intervention run.
- `interval_flow_limits`: bound each interconnector's flow by the published per-interval
  `IMPORTLIMIT`/`EXPORTLIMIT` ([`set_interconnector_flow_limits!`](@ref)). Those limits are
  computed after NEMDE's solve, so this pins flows to NEMDE's answer: a diagnostic, not for
  validating flows. Default `false` (static limits).

# Returns
A `PSY.System`.
"""
function replication_system(
        db, settlement_date::DateTime; intervention::Integer = 0, interval_flow_limits::Bool = false,
    )
    resolution = DISPATCH_INTERVAL
    date_range = settlement_date:resolution:(settlement_date + _REPLICATION_HORIZON)
    sys = nem_system(
        db, ConstrainedNetworkConfiguration(); date_range = date_range, intervention = intervention,
    )
    set_demand!(sys, db, date_range; resolution = resolution)
    set_market_bids!(sys, db, date_range; resolution = resolution)
    set_fcas_scaling_inputs!(sys, db, date_range; intervention = intervention)
    set_nem_dispatch_limits!(sys, db, date_range; intervention = intervention)
    set_mnsp_offers!(sys, db, date_range)
    interval_flow_limits &&
        set_interconnector_flow_limits!(sys, db, date_range; intervention = intervention)
    PSY.transform_single_time_series!(sys, _REPLICATION_HORIZON, resolution)
    return sys
end

# Zero gap tolerances: the loss encoding makes the problem a MILP, and HiGHS' default relative gap
# lets dispatch stop short of the optimum.
const _DEFAULT_OPTIMIZER = JuMP.optimizer_with_attributes(
    HiGHS.Optimizer, "mip_rel_gap" => 0.0, "mip_abs_gap" => 1.0e-10,
)

# Drops PSI's per-container "resulted in a MILP" warning, emitted once per dual container.
struct _DropMILPWarning <: Base.CoreLogging.AbstractLogger
    inner::Base.CoreLogging.AbstractLogger
end
_DropMILPWarning() = _DropMILPWarning(Base.CoreLogging.current_logger())
Base.CoreLogging.min_enabled_level(l::_DropMILPWarning) = Base.CoreLogging.min_enabled_level(l.inner)
Base.CoreLogging.shouldlog(l::_DropMILPWarning, args...) = Base.CoreLogging.shouldlog(l.inner, args...)
Base.CoreLogging.catch_exceptions(l::_DropMILPWarning) = Base.CoreLogging.catch_exceptions(l.inner)
function Base.CoreLogging.handle_message(l::_DropMILPWarning, level, message, args...; kwargs...)
    occursin("resulted in a MILP", string(message)) && return nothing
    return Base.CoreLogging.handle_message(l.inner, level, message, args...; kwargs...)
end

# PSI ignores a failed dual LP and leaves the duals NaN, so check them before reporting prices.
function _check_prices_finite(results::PSI.OptimizationProblemResults, settlement_date::DateTime)
    duals = PSI.read_dual(results, PSI.CopperPlateBalanceConstraint, PSY.Area)
    _check_prices_finite(duals.value, settlement_date)
    return nothing
end

function _check_prices_finite(duals::AbstractVector, settlement_date::DateTime; pass = "final dispatch")
    all(isfinite, duals) ||
        error("Interval $settlement_date has non-finite regional price duals in the $pass pass; the dual pass failed.")
    return nothing
end

"""
    replicate_interval(db, settlement_date; intervention = 0, optimizer = HiGHS.Optimizer)
    replicate_interval(sys, db, settlement_date; intervention = 0, optimizer = HiGHS.Optimizer)

Solves one historical NEM dispatch interval with [`replication_template`](@ref) on `sys` (by
default [`replication_system`](@ref)) and compares the final solution with AEMO's published outcome.
Supported fast-start profiles use a flexible commitment solve followed by a profile-constrained
dispatch solve; other intervals use one solve.

# Arguments
- `sys`: the `PSY.System` to solve, as built by [`replication_system`](@ref).
- `db`: an `AEMDB` connection whose cache holds the tables of `ConstrainedNetworkConfiguration`
  plus `DISPATCHINTERCONNECTORRES`, with data at `settlement_date` and the interval after it.
- `settlement_date`: the `SETTLEMENTDATE` of the interval (`DateTime`).
- `intervention`: 0 for the pricing run, 1 for the physical run.
- `optimizer`: the JuMP optimizer, e.g. `optimizer_with_attributes(HiGHS.Optimizer, ...)`. Defaults
  to HiGHS with `mip_rel_gap = 0` and `mip_abs_gap = 1e-10`, since the interconnector loss encoding is a MILP.
- `interval_flow_limits`: as in [`replication_system`](@ref); only the `replicate_interval(db, ...)`
  method builds the system.

# Returns
A `NamedTuple` with the final `model`, its `results`, `skipped_constraints`, `comparison` and
`fast_start_diagnostics`.
`skipped_constraints` is a `DataFrame` with one row per invoked constraint left out of the model:
`constraint`, `stage` (`:build` when [`add_nem_constraints!`](@ref) could not resolve a term,
`:template` when the template cannot model it), `reason`, `n_missing` (unresolved keys at the
`:build` stage, failing terms or devices at the `:template` stage) and `missing_keys` (the
unresolved DUIDs, regions or interconnectors; empty at the `:template` stage). `comparison` is a
`NamedTuple` of
`DataFrame`s with one row per published key and `_solved` and `_published` columns, `missing`
where the model has no solved value: `prices` (`REGIONID`; solved `ROP`, published `ROP` and
`RRP`), `dispatch` (`DUID`, `TOTALCLEARED`), `interconnectors` (`INTERCONNECTORID`, `MWFLOW`,
`MWLOSSES`) and `fcas_prices` (`REGIONID`, `BIDTYPE`, `ROP`). `ramp_violations` lists every
non-zero unit ramp slack of the model (`DUID`, `DateTime`, `MW`, `direction`), and
`constraint_violations` lists every non-zero slack of the families below (`family`, `name`,
`DateTime`, `MW`, `direction`, `variable`), where `family` is one of `"unit_ramp"`,
`"interconnector_flow"`, `"fcas_max_avail"`, `"fcas_bdu_ramping"`, `"fcas_joint_ramping"`,
`"fcas_enablement"`, `"fast_start_profile"`, `"thermal_availability"`, `"thermal_offer"`,
`"generic_constraint"` and `"area_balance"`. `direction` is `"up"` for a
slack relaxing a `<=` row and `"down"` for one relaxing a `>=` row. For `"area_balance"`, whose
row is an equality, `"up"` is a deficit (demand left unserved) and `"down"` a surplus (excess
generation). Slacks built outside PowerSimulations containers (the tie-break terms) are not listed. The solved balance dual is the
unadjusted price, so it is compared with `ROP`; `RRP` differs only under an administered price.
`fast_start_diagnostics` has one row per supported fast-start DUID, with its starting mode and
elapsed time, flexible candidate MW, planned and final mode, final MW, profile bounds, and energy
ramp anchor and duration. It is empty when no supported profile is active. Throws if either model
does not build or solve, after logging `skipped_constraints`.
"""
function replicate_interval(
        db, settlement_date::DateTime; intervention::Integer = 0, interval_flow_limits::Bool = false, kwargs...,
    )
    sys = replication_system(
        db, settlement_date; intervention = intervention, interval_flow_limits = interval_flow_limits,
    )
    return replicate_interval(sys, db, settlement_date; intervention = intervention, kwargs...)
end

function replicate_interval(
        sys::PSY.System, db, settlement_date::DateTime;
        intervention::Integer = 0, optimizer = _DEFAULT_OPTIMIZER,
    )
    inputs = read_fast_start_inputs(db, settlement_date; intervention = intervention)
    (; model, results, skipped_constraints, fast_start_diagnostics) = _solve_fast_start_replay(
        sys, inputs, settlement_date; optimizer = optimizer,
    )
    return (;
        model, results, skipped_constraints,
        comparison = _compare_to_published(db, sys, results, settlement_date, intervention),
        ramp_violations = _ramp_violations(results, sys),
        constraint_violations = _constraint_violations(results, sys),
        fast_start_diagnostics,
    )
end

function _solve_fast_start_replay(sys::PSY.System, inputs, settlement_date::DateTime; optimizer = _DEFAULT_OPTIMIZER)
    prepared = _prepare_fast_start_inputs(sys, inputs, settlement_date)
    if isempty(prepared)
        (; model, results, skipped_constraints) = _solve_replication_pass(
            sys, settlement_date; optimizer = optimizer, pass = :final_dispatch,
        )
        return (; model, results, skipped_constraints, fast_start_diagnostics = _empty_fast_start_diagnostics())
    end

    commitment_context = (; pass = :commitment, inputs = prepared, envelopes = Dict())
    commitment = _solve_replication_pass(
        sys, settlement_date; optimizer = optimizer, pass = :commitment,
        fast_start_context = commitment_context,
    )
    candidates = _solved_dispatch(commitment.results, settlement_date)
    envelopes = Dict{String, Any}()
    for (duid, input) in prepared
        candidate_mw = get(candidates, duid, NaN)
        isfinite(candidate_mw) || error("Interval $settlement_date commitment pass has no finite solved MW for fast-start DUID $duid.")
        envelopes[duid] = plan_fast_start(input, candidate_mw; _preprocessed = true)
    end

    dispatch_context = (; pass = :dispatch, inputs = prepared, envelopes)
    final = _solve_replication_pass(
        sys, settlement_date; optimizer = optimizer, pass = :final_dispatch,
        fast_start_context = dispatch_context,
    )
    diagnostics = _fast_start_diagnostics(prepared, candidates, envelopes, final.results, settlement_date)
    return (; model = final.model, results = final.results, skipped_constraints = final.skipped_constraints, fast_start_diagnostics = diagnostics)
end

function _prepare_fast_start_inputs(sys::PSY.System, inputs, settlement_date::DateTime)
    thermal = Dict(PSY.get_name(d) => d for d in PSY.get_components(PSY.ThermalStandard, sys))
    injections = Dict(PSY.get_name(d) => d for d in PSY.get_components(PSY.StaticInjection, sys))
    prepared = Dict{String, FastStartInput}()
    for (duid, input) in inputs
        profile = input.profile
        all(iszero, (profile.t1_minutes, profile.t2_minutes, profile.t3_minutes, profile.t4_minutes)) && continue
        device = get(injections, duid, nothing)
        (isnothing(device) || !PSY.get_available(device)) && continue
        if !haskey(thermal, duid)
            error("Interval $settlement_date has an active fast-start profile for unsupported non-thermal device $duid.")
        end
        missing = String[]
        _has_nem_dispatch_limits(device, NEMReplayDispatch) || push!(missing, "NEM dispatch limits")
        PSY.has_time_series(device, PSY.SingleTimeSeries, "availability") || push!(missing, "availability")
        isempty(missing) || error("Interval $settlement_date fast-start profile coverage for $duid is missing $(join(missing, ", ")).")
        prepared[duid] = preprocess_fast_start(input)
    end
    return prepared
end

function _empty_fast_start_diagnostics()
    return DataFrame(
        DUID = String[], DateTime = DateTime[], start_mode = Int[], start_elapsed_minutes = Float64[],
        candidate_mw = Float64[], target_mode = Int[], target_elapsed_minutes = Float64[],
        final_mode = Int[], final_elapsed_minutes = Float64[], profile_lower_mw = Float64[],
        profile_upper_mw = Union{Missing, Float64}[], ramp_initial_mw = Float64[],
        ramp_minutes = Union{Missing, Float64}[], final_mw = Float64[],
    )
end

function _fast_start_diagnostics(inputs, candidates, envelopes, results, settlement_date::DateTime)
    final_mw = _solved_dispatch(results, settlement_date)
    rows = NamedTuple[]
    for (duid, input) in inputs
        envelope = envelopes[duid]
        dispatch_mw = get(final_mw, duid, NaN)
        isfinite(dispatch_mw) || error("Interval $settlement_date final dispatch pass has no finite solved MW for fast-start DUID $duid.")
        final_state = finalize_fast_start_state(envelope, dispatch_mw)
        push!(
            rows, (
                DUID = duid, DateTime = settlement_date, start_mode = input.state.mode,
                start_elapsed_minutes = input.state.elapsed_minutes, candidate_mw = candidates[duid],
                target_mode = envelope.state.mode, target_elapsed_minutes = envelope.state.elapsed_minutes,
                final_mode = final_state.mode, final_elapsed_minutes = final_state.elapsed_minutes,
                profile_lower_mw = envelope.profile_lower_mw,
                profile_upper_mw = envelope.profile_upper_mw,
                ramp_initial_mw = envelope.ramp_initial_mw, ramp_minutes = envelope.ramp_minutes,
                final_mw = dispatch_mw,
            )
        )
    end
    return isempty(rows) ? _empty_fast_start_diagnostics() : DataFrame(rows)
end

function _solve_replication_pass(
        sys::PSY.System, settlement_date::DateTime; optimizer, pass::Symbol, fast_start_context = nothing,
    )
    (; model, skipped_constraints, status, output_dir) = _replication_model(
        sys, settlement_date; optimizer = optimizer, name = "replication_$pass",
        fast_start_context = fast_start_context,
    )
    if status != PSI.ModelBuildStatus.BUILT
        _log_skipped_constraints(skipped_constraints)
        _require_replication_status(status, PSI.ModelBuildStatus.BUILT, pass, :build, settlement_date)
        error("Interval $settlement_date failed to build in the $pass pass; see the PSI error log and $output_dir.")
    end
    run_status = PSI.solve!(model)
    if run_status != PSI.RunStatus.SUCCESSFULLY_FINALIZED
        _log_skipped_constraints(skipped_constraints)
        _require_replication_status(run_status, PSI.RunStatus.SUCCESSFULLY_FINALIZED, pass, :solve, settlement_date)
    end
    results = PSI.OptimizationProblemResults(model)
    pass == :final_dispatch && _check_prices_finite(results, settlement_date)
    return (; model, results, skipped_constraints)
end

function _require_replication_status(status, expected, pass::Symbol, stage::Symbol, settlement_date::DateTime)
    status == expected || error("Interval $settlement_date failed to $stage in the $pass pass: $status")
    return nothing
end
# The model `replicate_interval` solves: template, FCAS check, `DecisionModel` and its build.
function _replication_model(
        sys::PSY.System, settlement_date::DateTime; optimizer = _DEFAULT_OPTIMIZER, name = "replication",
        fast_start_context = nothing,
    )
    template_skipped = @NamedTuple{constraint::String, reason::Symbol, n_missing::Int}[]
    template = replication_template(sys; skipped = template_skipped)
    skipped_constraints = _skipped_constraints_table(sys, template_skipped)
    check_fcas_services(sys, template)
    if !isnothing(fast_start_context)
        thermal_model = get(PSI.get_device_models(template), :ThermalStandard, nothing)
        !isnothing(thermal_model) && (PSI.get_attributes(thermal_model)["fast_start"] = fast_start_context)
    end
    model = PSI.DecisionModel(
        template, sys;
        optimizer = optimizer, horizon = DISPATCH_INTERVAL, resolution = DISPATCH_INTERVAL,
        interval = DISPATCH_INTERVAL, initial_time = settlement_date, name = name,
    )
    output_dir = mktempdir()
    status = Base.CoreLogging.with_logger(() -> PSI.build!(model; output_dir = output_dir), _DropMILPWarning())
    return (; model, skipped_constraints, status, output_dir)
end

# Logs the skipped-constraint count by reason and the table, for a build or solve that failed.
function _log_skipped_constraints(skipped::DataFrame)
    by_reason = combine(groupby(skipped, :reason), nrow => :n)
    counts = join(("$(r.reason)=$(r.n)" for r in eachrow(sort(by_reason, :reason))), ", ")
    @error "Skipped constraints at failure: $(nrow(skipped)) ($counts)" skipped
    return
end

# Build-stage and template-stage skipped constraints as one table.
function _skipped_constraints_table(sys::PSY.System, template_skipped)
    build = get_skipped_constraints(sys)
    build.stage .= :build
    template = DataFrame(;
        constraint = String[r.constraint for r in template_skipped],
        reason = Symbol[r.reason for r in template_skipped],
        n_missing = Int[r.n_missing for r in template_skipped],
        missing_keys = [String[] for _ in template_skipped],
        stage = fill(:template, length(template_skipped)),
    )
    return select(vcat(build, template), :constraint, :stage, :reason, :n_missing, :missing_keys)
end

# Every elastic slack family, as `slack variable type => (family, direction)`. `direction` is
# `"up"` for a slack that relaxes a `<=` row and `"down"` for one that relaxes a `>=` row; the
# FCAS families whose rows have both senses refine it per key in `_violation_direction`.
const _VIOLATION_FAMILIES = (
    UnitRampUpSlack => ("unit_ramp", "up"),
    UnitRampDownSlack => ("unit_ramp", "down"),
    InterconnectorFlowSurplusSlack => ("interconnector_flow", "up"),
    InterconnectorFlowDeficitSlack => ("interconnector_flow", "down"),
    FCASMaxAvailSlack => ("fcas_max_avail", "up"),
    FCASBDURampingSlack => ("fcas_bdu_ramping", "up"),
    FCASJointRampingSlack => ("fcas_joint_ramping", "up"),
    FCASJointCapacitySlack => ("fcas_enablement", "up"),
    FastStartProfileDeficitSlack => ("fast_start_profile", "down"),
    FastStartProfileSurplusSlack => ("fast_start_profile", "up"),
    AvailabilitySurplusSlack => ("thermal_availability", "up"),
    OfferSurplusSlack => ("thermal_offer", "up"),
    GenericConstraintSlackUp => ("generic_constraint", "up"),
    GenericConstraintSlackDown => ("generic_constraint", "down"),
    PSI.SystemBalanceSlackUp => ("area_balance", "up"),
    PSI.SystemBalanceSlackDown => ("area_balance", "down"),
)

# `FCASJointCapacitySlack` keys end in `_lower` for the `>=` EnablementMin rows. A
# `FCASJointRampingSlack` relaxes the upper (`<=`) form for the service a device's
# `_fcas_upper_regulation_service` names and the lower (`>=`) form for the other, so the sense is
# resolved per device from the service's bid type.
function _violation_direction(sys::PSY.System, type, meta::AbstractString, name::AbstractString, default::AbstractString)
    type === FCASJointCapacitySlack && return endswith(meta, "_lower") ? "down" : "up"
    if type === FCASJointRampingSlack
        service = PSY.get_component(FCASService, sys, meta)
        device = PSY.get_component(PSY.Device, sys, name)
        return get_bid_type(service) == _fcas_upper_regulation_service(device) ? "up" : "down"
    end
    return default
end

# `family`, `name`, `DateTime`, `MW`, `direction` and `variable` (the slack variable's key) of
# every slack above the tolerance, in every interval and every family of `_VIOLATION_FAMILIES`.
function _constraint_violations(results::PSI.OptimizationProblemResults, sys::PSY.System)
    kinds = Dict(_VIOLATION_FAMILIES)
    rows = NamedTuple{
        (:family, :name, :DateTime, :MW, :direction, :variable),
        Tuple{String, String, DateTime, Float64, String, String},
    }[]
    for key in PSI.list_variable_keys(results)
        type = PSI.IS.Optimization.get_entry_type(key)
        kind = get(kinds, type, nothing)
        isnothing(kind) && continue
        for r in eachrow(PSI.read_variable(results, key))
            r.value > _VIOLATION_TOLERANCE_MW || continue
            direction = _violation_direction(sys, type, key.meta, r.name, kind[2])
            push!(rows, (; family = kind[1], name = r.name, DateTime = r.DateTime, MW = r.value, direction, variable = string(key)))
        end
    end
    return DataFrame(rows)
end

# `DUID`, `DateTime`, `MW` and `direction` of every non-zero unit ramp slack.
function _ramp_violations(results::PSI.OptimizationProblemResults, sys::PSY.System)
    violations = _constraint_violations(results, sys)
    ramp = violations[violations.family .== "unit_ramp", :]
    return DataFrame(DUID = ramp.name, DateTime = ramp.DateTime, MW = ramp.MW, direction = ramp.direction)
end

"MW of slack below which a constraint row counts as satisfied."
const _VIOLATION_TOLERANCE_MW = 1.0e-6

# `name => value` for the rows of a `read_variable`/`read_dual` frame at `settlement_date`.
function _first_interval(df::DataFrame, settlement_date::DateTime)
    return Dict(r.name => r.value for r in eachrow(df) if r.DateTime == settlement_date)
end

# Solved net MW per DUID: generation (or discharge) minus charge.
function _solved_dispatch(results::PSI.OptimizationProblemResults, settlement_date::DateTime)
    signs = Dict(
        PSI.ActivePowerVariable => 1.0, PSI.ActivePowerOutVariable => 1.0, PSI.ActivePowerInVariable => -1.0,
    )
    net = Dict{String, Float64}()
    for key in PSI.list_variable_keys(results)
        sign = get(signs, PSI.IS.Optimization.get_entry_type(key), nothing)
        isnothing(sign) && continue
        for (duid, mw) in _first_interval(PSI.read_variable(results, key), settlement_date)
            net[duid] = get(net, duid, 0.0) + sign * mw
        end
    end
    return net
end

function _compare_to_published(db, sys, results, settlement_date::DateTime, intervention::Integer)
    resolution = DISPATCH_INTERVAL
    published = read_published_interval(db, settlement_date; intervention = intervention)
    # Every published row is kept; `missing` marks a key the model did not solve.
    compare(published, solved, on) = leftjoin(
        published, solved; on = on, renamecols = "_published" => "_solved",
    )

    # A balance dual is per per-unit-interval; dividing gives $/MWh.
    scale = PSY.get_base_power(sys) * interval_hours(resolution)
    duals = _first_interval(PSI.read_dual(results, PSI.CopperPlateBalanceConstraint, PSY.Area), settlement_date)
    prices = compare(
        published.prices,
        DataFrame(; REGIONID = collect(keys(duals)), ROP = collect(values(duals)) ./ scale),
        :REGIONID,
    )

    net = _solved_dispatch(results, settlement_date)
    dispatch = compare(
        published.dispatch,
        DataFrame(; DUID = collect(keys(net)), TOTALCLEARED = collect(values(net))),
        :DUID,
    )

    flows = _first_interval(PSI.read_variable(results, PSI.FlowActivePowerVariable, PSY.AreaInterchange), settlement_date)
    losses = _first_interval(PSI.read_variable(results, InterconnectorLossVariable, PSY.AreaInterchange), settlement_date)
    interconnectors = compare(
        published.interconnectors,
        DataFrame(;
            INTERCONNECTORID = collect(keys(flows)), MWFLOW = collect(values(flows)),
            MWLOSSES = [get(losses, id, missing) for id in keys(flows)],
        ),
        :INTERCONNECTORID,
    )

    fcas_prices = compare(
        select(published.fcas_prices, :SETTLEMENTDATE, :REGIONID, :BIDTYPE, :ROP),
        compute_fcas_prices(results, sys; resolution = resolution),
        [:SETTLEMENTDATE, :REGIONID, :BIDTYPE],
    )
    return (; prices, dispatch, interconnectors, fcas_prices)
end
