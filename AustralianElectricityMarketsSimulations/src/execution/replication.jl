"""
The optional families of [`replication_template`](@ref) that its `parts` argument selects:
`:batteries` (storage devices as [`AbstractNEMDispatch`](@ref)), `:fcas` (an [`FCASMarket`](@ref) per
`FCASService`), `:losses` ([`NEMInterconnectorLoss`](@ref) on each interchange), `:tie_breaks`
(energy tie-break links, carried by the model settings) and `:generic_constraints`.
"""
const REPLICATION_PARTS = (:batteries, :fcas, :losses, :tie_breaks, :generic_constraints)


"""
    replication_template(sys; skipped = nothing, parts = REPLICATION_PARTS, exclude_constraints = ()) -> PSI.ProblemTemplate

Builds the `ProblemTemplate` that replicates NEMDE on `sys`: [`AbstractNEMDispatch`](@ref) devices
(via [`set_nem_dispatch_models!`](@ref)), `PSI.StaticPowerLoad` demand, [`NEMInterconnectorLoss`](@ref)
on every `PSY.AreaInterchange`, an [`FCASMarket`](@ref) per registered `FCASService`, and a
[`LinearFactorLimit`](@ref) per `GenericConstraint` whose terms the template can model.
Regions balance through `PSI.AreaBalancePowerModel` with slacks, and the balance duals are
recorded as regional prices. Price-tied energy bands are dispatched pro rata
([`add_tie_break_constraints!`](@ref)). `parts` selects the [`REPLICATION_PARTS`](@ref) to model;
without `:losses` no `PSY.AreaInterchange` is modeled and the regions are uncoupled.
Missing dispatch inputs, skipped constraints, dropped terms and defaulted penalty weights throw
`ArgumentError` before model construction.

# Arguments
- `sys`: a `PSY.System` from `nem_system(db, ConstrainedNetworkConfiguration(); ...)`, after its
  demand, bids, FCAS scaling inputs and dispatch limits are set.
- `skipped`: a vector that receives one `(constraint, reason, n_missing)` named tuple per generic
  constraint left out of the template, or `nothing`.
- `parts`: the [`REPLICATION_PARTS`](@ref) to model; default all. `:tie_breaks` acts through the
  model settings, not the template.
- `exclude_constraints`: a `Dict` from the names of generic constraints to leave out to the `reason`
  each is recorded with in `skipped`.

# Returns
A `PSI.ProblemTemplate`.
"""
function replication_template(
        sys::PSY.System; skipped::Union{Nothing, AbstractVector} = nothing,
        parts = REPLICATION_PARTS, exclude_constraints = Dict{String, Symbol}(),
    )
    if :generic_constraints in parts
        missing_intervals = get(PSY.get_ext(sys), "missing_constraint_intervals", DateTime[])
        isempty(missing_intervals) || throw(
            ArgumentError(
                "replication_template: missing dispatch constraint intervals: $(join(string.(missing_intervals), ", ")); populate DISPATCHCONSTRAINT for the requested range",
            )
        )
        skipped_inputs = get_skipped_constraints(sys)
        dropped_inputs = get_dropped_terms(sys)
        defaulted_weights = get(PSY.get_ext(sys), "defaulted_constraint_weights", String[])
        isempty(defaulted_weights) || throw(
            ArgumentError(
                "replication_template: incomplete constraint weights: $(join(defaulted_weights, ", "))",
            )
        )
        isempty(skipped_inputs) || throw(
            ArgumentError(
                "replication_template: incomplete constraint inputs: $(join(skipped_inputs.constraint, ", "))",
            )
        )
        isempty(dropped_inputs) || throw(
            ArgumentError(
                "replication_template: incomplete constraint terms: $(join(dropped_inputs.constraint .* ": " .* dropped_inputs.key, ", "))",
            )
        )
    end
    uncovered = String[]
    for device in AustralianElectricityMarkets._nem_dispatch_devices(sys)
        device isa PSY.Storage && !(:batteries in parts) && continue
        _has_nem_dispatch_limits(device, NEMReplayDispatch) || push!(uncovered, PSY.get_name(device))
    end
    isempty(uncovered) || throw(
        ArgumentError(
            "replication_template: incomplete dispatch inputs for $(join(sort!(uncovered), ", ")); attach every dispatch-limit series before replay",
        )
    )
    if :losses in parts
        for device in PSY.get_components(PSY.get_available, PSY.AreaInterchange, sys)
            _has_mnsp_offers(device)
        end
    end
    unknown = setdiff(parts, REPLICATION_PARTS)
    isempty(unknown) || throw(ArgumentError("replication_template: unknown parts $(Tuple(unknown)); choose from $REPLICATION_PARTS."))
    template = PSI.ProblemTemplate(
        PSI.NetworkModel(
            PSI.AreaBalancePowerModel;
            use_slacks = true,
            duals = [PSI.CopperPlateBalanceConstraint],
        ),
    )
    if :batteries in parts
        set_nem_dispatch_models!(template, sys)
    else
        for T in nem_dispatch_participants(sys)
            T <: PSY.Storage || PSI.set_device_model!(template, T, NEMReplayDispatch)
        end
    end
    PSI.set_device_model!(template, PSY.PowerLoad, PSI.StaticPowerLoad)
    # Without `:losses` no interchange is modeled, so the regions are uncoupled.
    :losses in parts && PSI.set_device_model!(template, PSY.AreaInterchange, NEMInterconnectorLoss)
    if :fcas in parts
        for svc in PSY.get_components(FCASService, sys)
            name = PSY.get_name(svc)
            PSI.set_service_model!(
                template, name,
                PSI.ServiceModel(FCASService, FCASMarket, name; duals = [FCASJointCapacityConstraint], use_slacks = true),
            )
        end
    end
    :generic_constraints in parts || return template
    for gc in filter_buildable_generic_constraints(sys, template; skipped = skipped)
        name = PSY.get_name(gc)
        if haskey(exclude_constraints, name)
            isnothing(skipped) || push!(skipped, (constraint = name, reason = exclude_constraints[name], n_missing = 0))
            continue
        end
        PSI.set_service_model!(
            template, name,
            PSI.ServiceModel(
                GenericConstraint, LinearFactorLimit, name; duals = [NEMConstraintLimit], use_slacks = true,
            ),
        )
    end
    return template
end


# Period offers identify bidders independently of whether their price join succeeds.
function _check_replay_energy_bid_coverage(sys, db, date_range; intervention::Integer = 0)
    bids = read_energy_bids(db, date_range)
    dispatch = read_dispatch_limits(db, date_range; intervention = intervention)
    units = read_units(db; as_of = first(date_range))
    demand = read_demand(db, date_range)
    demand_stamps = Set(zip(demand.REGIONID, demand.SETTLEMENTDATE))
    grid = collect(date_range)[1:(end - 1)]
    missing_demand = [(region, t) for region in sort!(unique(units.REGIONID)), t in grid if !((region, t) in demand_stamps)]
    isempty(missing_demand) || throw(
        ArgumentError("missing regional demand inputs: $(join(string.(first(missing_demand, 5)), ", "))"),
    )
    non_scheduled = Set(r.DUID for r in eachrow(units) if isequal(r.SCHEDULE_TYPE, "NON-SCHEDULED"))
    required_names = Set(bids.DUID)
    for row in eachrow(dispatch)
        available = !ismissing(row.AVAILABILITY) && row.AVAILABILITY > 0
        metered = !ismissing(row.INITIALMW) && !iszero(row.INITIALMW)
        (available || metered) && push!(required_names, row.DUID)
    end
    coverage = Dict{Tuple{String, String}, Set{DateTime}}()
    for row in eachrow(bids)
        push!(get!(coverage, (row.DUID, row.DIRECTION), Set{DateTime}()), row.INTERVAL_DATETIME)
        row.MAXAVAIL isa Real && isfinite(row.MAXAVAIL) && row.MAXAVAIL >= 0 ||
            throw(ArgumentError("incomplete energy bid MAXAVAIL for $(row.DUID) $(row.DIRECTION) at $(row.INTERVAL_DATETIME)"))
    end
    for T in (PSY.Generator, PSY.InterruptiblePowerLoad, PSY.EnergyReservoirStorage), device in PSY.get_components(T, sys)
        name = PSY.get_name(device)
        name in required_names && !(name in non_scheduled) || continue
        device isa PSY.InterruptiblePowerLoad && AustralianElectricityMarkets._is_non_scheduled_load(device) && continue
        directions = if device isa PSY.Storage
            ("GEN", "LOAD")
        elseif device isa PSY.InterruptiblePowerLoad
            haskey(coverage, (name, "GEN")) ? ("GEN",) : ("LOAD",)
        else
            ("GEN",)
        end
        for direction in directions
            stamps = get(coverage, (name, direction), Set{DateTime}())
            missing_intervals = setdiff(grid, stamps)
            isempty(missing_intervals) || throw(
                ArgumentError(
                    "incomplete energy bid inputs for $name $direction: missing $(length(missing_intervals)) intervals, including $(first(missing_intervals))",
                )
            )
        end
    end
    return
end


const _REPLICATION_HORIZON = 2DISPATCH_INTERVAL


"""
    replication_system(db, settlement_date; intervention = 0) -> PSY.System
    replication_system(db, date_range; intervention = 0) -> PSY.System

Builds the `System` [`replicate_interval`](@ref) solves: the constrained system from
`nem_system(db, ConstrainedNetworkConfiguration(); ...)` over the interval and the one after it,
with demand, interconnector loss demand coefficients, bids, FCAS scaling inputs, dispatch limits,
battery dispatch ceilings, effective FCAS offers and tie-break scales set and the time series transformed
into one-interval windows. The `date_range` method builds over exactly that 5-minute range, one window per timestamp.

# Arguments
- `db`: an `AEMDB` connection. Its cache must hold data at `settlement_date` and at
  `settlement_date + 5 minutes`, so the last cached interval cannot be replicated.
- `settlement_date`: the `SETTLEMENTDATE` of the interval (`DateTime`).
- `date_range`: a `StepRange{DateTime}` stepping by 5 minutes.
- `intervention`: 0 for the pricing run, 1 for the physical run. Applies to the constraint,
  dispatch-limit, interconnector-limit and FCAS-scaling reads; demand, bids and MNSP offers carry no intervention run.
- `interval_flow_limits`: bound each interconnector's flow by the published per-interval
  `IMPORTLIMIT`/`EXPORTLIMIT` ([`set_interconnector_flow_limits!`](@ref)). Those limits are
  computed after NEMDE's solve, so this pins flows to NEMDE's answer: a diagnostic, not for
  validating flows. Default `false` (static limits).
- `time_series_in_memory`: keep the time series in memory (`true`) or in a file under
  `time_series_directory`.
- `time_series_directory`: the directory of the time-series file when `time_series_in_memory` is `false`;
  `nothing` uses PowerSystems' default.

# Returns
A `PSY.System`.
"""
function replication_system(
        db, date_range::StepRange{DateTime}; intervention::Integer = 0, interval_flow_limits::Bool = false,
        time_series_in_memory::Bool = true, time_series_directory::Union{Nothing, AbstractString} = nothing,
    )
    step(date_range) == DISPATCH_INTERVAL ||
        throw(ArgumentError("replication_system: the date range must step by $DISPATCH_INTERVAL, got $(step(date_range))."))
    resolution = DISPATCH_INTERVAL
    storage = isnothing(time_series_directory) ? (;) : (; time_series_directory = time_series_directory)
    sys = nem_system(
        db, ConstrainedNetworkConfiguration(); date_range = date_range, intervention = intervention,
        time_series_in_memory = time_series_in_memory, storage...,
    )
    _check_replay_energy_bid_coverage(sys, db, date_range; intervention = intervention)
    set_demand!(sys, db, date_range; resolution = resolution)
    set_loss_demand_coefficients!(sys)
    set_market_bids!(sys, db, date_range; resolution = resolution)
    set_fcas_scaling_inputs!(sys, db, date_range; intervention = intervention)
    set_nem_dispatch_limits!(sys, db, date_range; intervention = intervention)
    set_nem_energy_limits!(sys, db, date_range; intervention = intervention)
    set_storage_dispatch_ceilings!(sys)
    set_fcas_effective_offers!(sys)
    set_tie_break_scales!(sys)
    set_mnsp_offers!(sys, db, date_range)
    interval_flow_limits &&
        set_interconnector_flow_limits!(sys, db, date_range; intervention = intervention)
    PSY.transform_single_time_series!(sys, DISPATCH_INTERVAL, resolution)
    return sys
end
function replication_system(db, settlement_date::DateTime; kwargs...)
    return replication_system(
        db, settlement_date:DISPATCH_INTERVAL:(settlement_date + _REPLICATION_HORIZON); kwargs...,
    )
end


# Zero gap tolerances: the loss encoding makes the problem a MILP, and HiGHS' default relative gap
# lets dispatch stop short of the optimum.
const _DEFAULT_OPTIMIZER = JuMP.optimizer_with_attributes(
    HiGHS.Optimizer, "mip_rel_gap" => 0.0, "mip_abs_gap" => 1.0e-10,
)


# A one-interval `DecisionModel` of `template` from `initial_time`; the settings `ext` entry
# "tie_breaks" records whether `parts` includes `:tie_breaks`.
function _replication_decision_model(
        template::PSI.ProblemTemplate, sys::PSY.System, initial_time::DateTime;
        optimizer = _DEFAULT_OPTIMIZER, name = "replication", parts = REPLICATION_PARTS,
    )
    model = PSI.DecisionModel(
        template, sys; optimizer = optimizer, horizon = DISPATCH_INTERVAL,
        resolution = DISPATCH_INTERVAL, interval = DISPATCH_INTERVAL, initial_time = initial_time, name = name,
    )
    PSI.get_ext(PSI.get_settings(model))["tie_breaks"] = :tie_breaks in parts
    return model
end


# PSI ignores a failed dual LP and leaves the duals NaN, so check them before reporting prices.
function _check_prices_finite(duals::AbstractDict{DateTime})
    for t in sort!(collect(keys(duals)))
        all(isfinite, duals[t].value) || error("Interval $t has non-finite regional price duals; the dual pass failed.")
    end
    return
end


"""
    replicate_interval(db, settlement_date; intervention = 0, optimizer = HiGHS.Optimizer)
    replicate_interval(sys, db, settlement_date; intervention = 0, optimizer = HiGHS.Optimizer)

Solves one historical NEM dispatch interval with [`replication_template`](@ref) on `sys` (by
default [`replication_system`](@ref)) and compares the solution with AEMO's published outcome.
The model solves the interval alone, starting from its published `INITIALMW`.

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
A `NamedTuple` with the solved `model`, its `results`, `skipped_constraints` and `comparison`.
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
`constraint_violations` lists every non-zero slack of the families below (for a generic constraint, at an interval where it is invoked) (`family`, `name`,
`DateTime`, `MW`, `direction`, `variable`), where `family` is one of `"energy_offer"`, `"energy_max_avail"`, `"energy_uigf"`, `"unit_ramp"`,
`"interconnector_flow"`, `"fcas_max_avail"`, `"fcas_bdu_ramping"`, `"fcas_joint_ramping"`,
`"fcas_enablement"`, `"generic_constraint"` and `"area_balance"`. `direction` is `"up"` for a
slack relaxing a `<=` row and `"down"` for one relaxing a `>=` row. For `"area_balance"`, whose
row is an equality, `"up"` is a deficit (demand left unserved) and `"down"` a surplus (excess
generation). Slacks built outside PowerSimulations containers (the tie-break terms) are not listed. The solved balance dual is the
unadjusted price, so it is compared with `ROP`; `RRP` differs only under an administered price.
Throws if the model does not build or solve, after logging `skipped_constraints`.
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
    (; model, skipped_constraints, status, output_dir) =
        _replication_model(sys, settlement_date; optimizer = optimizer)
    status == PSI.ModelBuildStatus.BUILT || begin
        _log_skipped_constraints(skipped_constraints)
        error("Interval $settlement_date failed to build ($status); see the PSI error log and $output_dir.")
    end
    run_status = PSI.solve!(model)
    run_status == PSI.RunStatus.SUCCESSFULLY_FINALIZED || begin
        _log_skipped_constraints(skipped_constraints)
        error("Interval $settlement_date failed to solve: $run_status")
    end
    results = PSI.OptimizationProblemResults(model)
    _check_prices_finite(_by_interval(PSI.read_dual(results, PSI.CopperPlateBalanceConstraint, PSY.Area)))
    violations = _constraint_violations(results, sys)
    solved = _solved_interval(_solved_frames(results, sys; losses = true), sys, settlement_date)
    published = read_published_interval(db, settlement_date; intervention = intervention)
    return (;
        model, results, skipped_constraints, comparison = _compare_to_published(published, solved),
        ramp_violations = _ramp_violations(violations), constraint_violations = violations,
    )
end

# The model `replicate_interval` solves: template, FCAS check, `DecisionModel` and its build.
function _replication_model(
        sys::PSY.System, settlement_date::DateTime; optimizer = _DEFAULT_OPTIMIZER, name = "replication",
    )
    template_skipped = @NamedTuple{constraint::String, reason::Symbol, n_missing::Int}[]
    template = replication_template(sys; skipped = template_skipped)
    skipped_constraints = _skipped_constraints_table(sys, template_skipped)
    check_fcas_services(sys, template)
    model = _replication_decision_model(template, sys, settlement_date; optimizer = optimizer, name = name)
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
    EnergyOfferSurplusSlack => ("energy_offer", "up"),
    EnergyOfferDeficitSlack => ("energy_offer", "down"),
    EnergyMaxAvailSlack => ("energy_max_avail", "up"),
    EnergyUIGFSlack => ("energy_uigf", "up"),
    UnitRampUpSlack => ("unit_ramp", "up"),
    UnitRampDownSlack => ("unit_ramp", "down"),
    InterconnectorFlowSurplusSlack => ("interconnector_flow", "up"),
    InterconnectorFlowDeficitSlack => ("interconnector_flow", "down"),
    FCASMaxAvailSlack => ("fcas_max_avail", "up"),
    FCASBDURampingSlack => ("fcas_bdu_ramping", "up"),
    FCASJointRampingSlack => ("fcas_joint_ramping", "up"),
    FCASJointCapacitySlack => ("fcas_enablement", "up"),
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


# Whether `sys`'s generic constraint `name` is invoked at `t`.
function _gc_invoked(sys::PSY.System, name::AbstractString, t::DateTime)
    gc = PSY.get_component(GenericConstraint, sys, name)
    return only(PSY.get_time_series_values(PSY.SingleTimeSeries, gc, "invoked"; start_time = t, len = 1)) != 0.0
end


# Each key's long-format frame (`DateTime`, `name`, `value`), read in one call per results object.
function _read_violation_frames(results::PSI.OptimizationProblemResults, keys)
    return Dict(key => PSI.read_variable(results, key) for key in keys)
end
# Opens the simulation store once and reads every key over the timestamps `read_variable` uses.
function _read_violation_frames(results::PSI.SimulationProblemResults, keys)
    isempty(keys) && return Dict{PSI.OptimizationContainerKey, DataFrame}()
    timestamps = PSI._process_timestamps(results, nothing, nothing)
    vals = PSI._read_results(results, keys, timestamps, nothing)
    return Dict(key => reduce(vcat, values(PSI.make_dataframes(vals[key]; table_format = PSI.TableFormat.LONG))) for key in keys)
end


# every slack above the tolerance, in every interval and every family of `_VIOLATION_FAMILIES`; a
# generic constraint's slack counts only where it is invoked. Accepts the results of a
# `DecisionModel` or of one decision problem of a `PSI.Simulation`.
function _constraint_violations(
        results::Union{PSI.OptimizationProblemResults, PSI.SimulationProblemResults}, sys::PSY.System,
    )
    kinds = Dict(_VIOLATION_FAMILIES)
    rows = NamedTuple{
        (:family, :name, :DateTime, :MW, :direction, :variable),
        Tuple{String, String, DateTime, Float64, String, String},
    }[]
    slack_keys = [key for key in PSI.list_variable_keys(results) if haskey(kinds, PSI.IS.Optimization.get_entry_type(key))]
    frames = _read_violation_frames(results, slack_keys)
    for key in slack_keys
        type = PSI.IS.Optimization.get_entry_type(key)
        kind = kinds[type]
        for r in eachrow(frames[key])
            r.value > _VIOLATION_TOLERANCE_MW || continue
            kind[1] == "generic_constraint" && !_gc_invoked(sys, r.name, r.DateTime) && continue
            direction = _violation_direction(sys, type, key.meta, r.name, kind[2])
            push!(rows, (; family = kind[1], name = r.name, DateTime = r.DateTime, MW = r.value, direction, variable = string(key)))
        end
    end
    return DataFrame(rows)
end


# `DUID`, `DateTime`, `MW` and `direction` of every non-zero unit ramp slack, from the
# `_constraint_violations` table.
function _ramp_violations(violations::DataFrame)
    ramp = violations[violations.family .== "unit_ramp", :]
    return DataFrame(DUID = ramp.name, DateTime = ramp.DateTime, MW = ramp.MW, direction = ramp.direction)
end


"MW of slack below which a constraint row counts as satisfied."
const _VIOLATION_TOLERANCE_MW = 1.0e-6


# `df` split into one frame per value of its `col` column, keyed by that value.
function _by_interval(df::DataFrame, col::Symbol = :DateTime)
    return Dict{DateTime, SubDataFrame}(k[1] => sub for (k, sub) in pairs(groupby(df, col)))
end
# `name => value` for the rows of interval `t` in `by_interval`, empty if the interval has none.
function _first_interval(by_interval::AbstractDict, t::DateTime)
    rows = get(by_interval, t, nothing)
    isnothing(rows) && return Dict{String, Float64}()
    return Dict{String, Float64}(r.name => r.value for r in eachrow(rows))
end
# Variables `_solved_interval` reads, and each dispatch variable's sign in net MW.
const _SOLVED_VARIABLES = (
    PSI.ActivePowerVariable, PSI.ActivePowerOutVariable, PSI.ActivePowerInVariable,
    PSI.FlowActivePowerVariable, InterconnectorLossVariable,
)
const _DISPATCH_SIGNS = Dict(PSI.ActivePowerVariable => 1.0, PSI.ActivePowerOutVariable => 1.0, PSI.ActivePowerInVariable => -1.0)
function _read_variable_frame(results::PSI.OptimizationProblemResults, key)
    return PSI.read_variable(results, key)
end
function _read_variable_frame(results::PSI.SimulationProblemResults, key)
    return only(values(PSI.read_realized_variables(results, [key])))
end
function _balance_duals(results::PSI.OptimizationProblemResults)
    return PSI.read_dual(results, PSI.CopperPlateBalanceConstraint, PSY.Area)
end
function _balance_duals(results::PSI.SimulationProblemResults)
    return only(values(PSI.read_realized_duals(results, ["CopperPlateBalanceConstraint__Area"])))
end
function _empty_fcas_prices()
    return DataFrame(; SETTLEMENTDATE = DateTime[], REGIONID = String[], BIDTYPE = BidType[], ROP = Float64[])
end
function _solved_fcas_prices(results::PSI.OptimizationProblemResults, sys)
    return compute_fcas_prices(results, sys; resolution = DISPATCH_INTERVAL)
end
function _solved_fcas_prices(results::PSI.SimulationProblemResults, sys)
    return compute_fcas_prices(results, sys; resolution = DISPATCH_INTERVAL)
end
# Solved values of every interval: `balance_duals`, `variables` (key => `_by_interval` frames, for
# `_SOLVED_VARIABLES`) and `fcas_prices` (`compute_fcas_prices` columns, by interval). With `losses`,
# the AreaInterchange flow and loss variables must be in `results` when `sys` has interchanges.
function _solved_frames(results, sys::PSY.System; losses::Bool)
    variables = Dict(
        key => _by_interval(_read_variable_frame(results, key)) for key in PSI.list_variable_keys(results)
            if PSI.IS.Optimization.get_entry_type(key) in _SOLVED_VARIABLES
    )
    if losses && !isempty(PSY.get_components(PSY.AreaInterchange, sys))
        for T in (PSI.FlowActivePowerVariable, InterconnectorLossVariable)
            found = any(
                k -> PSI.IS.Optimization.get_entry_type(k) === T &&
                    PSI.IS.Optimization.get_component_type(k) === PSY.AreaInterchange,
                keys(variables),
            )
            found || error("Losses are modeled but the results lack $T on AreaInterchange.")
        end
    end
    return (;
        balance_duals = _by_interval(_balance_duals(results)),
        variables,
        fcas_prices = _by_interval(_solved_fcas_prices(results, sys), :SETTLEMENTDATE),
    )
end
# One interval of `_solved_frames` as the solved side of `_compare_to_published`.
function _solved_interval(frames, sys::PSY.System, settlement_date::DateTime)
    # A balance dual is per per-unit-interval; dividing gives $/MWh.
    scale = PSY.get_base_power(sys) * interval_hours(DISPATCH_INTERVAL)
    duals = _first_interval(frames.balance_duals, settlement_date)
    net, flows, losses = Dict{String, Float64}(), Dict{String, Float64}(), Dict{String, Float64}()
    for (key, by_interval) in frames.variables
        type, component = PSI.IS.Optimization.get_entry_type(key), PSI.IS.Optimization.get_component_type(key)
        at = _first_interval(by_interval, settlement_date)
        if haskey(_DISPATCH_SIGNS, type)
            for (duid, mw) in at
                net[duid] = get(net, duid, 0.0) + _DISPATCH_SIGNS[type] * mw
            end
        elseif type === PSI.FlowActivePowerVariable && component === PSY.AreaInterchange
            merge!(flows, at)
        elseif type === InterconnectorLossVariable && component === PSY.AreaInterchange
            merge!(losses, at)
        end
    end
    ids = collect(keys(flows))
    fcas = get(frames.fcas_prices, settlement_date, nothing)
    return (;
        prices = DataFrame(; REGIONID = collect(keys(duals)), ROP = collect(values(duals)) ./ scale),
        dispatch = DataFrame(; DUID = collect(keys(net)), TOTALCLEARED = collect(values(net))),
        interconnectors = DataFrame(;
            INTERCONNECTORID = ids, MWFLOW = [flows[id] for id in ids],
            MWLOSSES = Union{Missing, Float64}[get(losses, id, missing) for id in ids],
        ),
        fcas_prices = isnothing(fcas) ? _empty_fcas_prices() : DataFrame(fcas),
    )
end
# Every published row with its solved value, `missing` where the model has none.
function _compare_to_published(published, solved)
    compare(p, s, on) = leftjoin(p, s; on = on, renamecols = "_published" => "_solved")
    return (;
        prices = compare(published.prices, solved.prices, :REGIONID),
        dispatch = compare(published.dispatch, solved.dispatch, :DUID),
        interconnectors = compare(published.interconnectors, solved.interconnectors, :INTERCONNECTORID),
        fcas_prices = compare(
            select(published.fcas_prices, :SETTLEMENTDATE, :REGIONID, :BIDTYPE, :ROP),
            solved.fcas_prices, [:SETTLEMENTDATE, :REGIONID, :BIDTYPE],
        ),
    )
end
