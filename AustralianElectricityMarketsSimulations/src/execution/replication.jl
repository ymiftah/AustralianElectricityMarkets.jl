"""
The optional families of [`replication_template`](@ref) that its `parts` argument selects:
`:batteries` (`PSY.Storage` devices under [`AbstractNEMDispatch`](@ref)), `:fcas` (an
[`FCASMarket`](@ref) per `FCASService`), `:losses` ([`NEMInterconnectorLoss`](@ref) on each
`PSY.AreaInterchange`), `:tie_breaks` (the [`TieBreakMarket`](@ref) service model) and
`:generic_constraints` (a [`LinearFactorLimit`](@ref) per `GenericConstraint`).
"""
const REPLICATION_PARTS = (:batteries, :fcas, :losses, :tie_breaks, :generic_constraints)


"""
    replication_template(sys; skipped = nothing, parts = REPLICATION_PARTS, exclude_constraints = Dict{String, Symbol}()) -> PSI.ProblemTemplate

Builds the `ProblemTemplate` that replicates NEMDE on `sys`: [`AbstractNEMDispatch`](@ref) devices
(via [`set_nem_dispatch_models!`](@ref)), `PSI.StaticPowerLoad` demand, [`NEMInterconnectorLoss`](@ref)
on every `PSY.AreaInterchange`, an [`FCASMarket`](@ref) per registered `FCASService`, and a
[`LinearFactorLimit`](@ref) per `GenericConstraint` with an available contributing device.
Regions balance through `PSI.AreaBalancePowerModel` with slacks, and the balance duals are
recorded as regional prices. Price-tied energy bands are dispatched pro rata by the
[`TieBreakMarket`](@ref) service model when `sys` carries the [`EnergyTieBreak`](@ref) of
[`set_tie_break_scales!`](@ref). `parts` selects the [`REPLICATION_PARTS`](@ref) to model; without
`:losses` no `PSY.AreaInterchange` is modeled and the regions are uncoupled.

# Arguments
- `sys`: a `PSY.System` from `nem_system(db, ConstrainedNetworkConfiguration(); ...)`, after its
  demand, bids, FCAS scaling inputs, dispatch limits and separate energy limits are set.
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
        sys::PSY.System; skipped::Union{Nothing, AbstractVector} = nothing, parts = REPLICATION_PARTS,
        exclude_constraints::AbstractDict{<:AbstractString, Symbol} = Dict{String, Symbol}(),
    )
    _check_replication_parts(parts)
    _check_replay_system_inputs(sys, parts)
    template = PSI.ProblemTemplate(
        PSI.NetworkModel(
            PSI.AreaBalancePowerModel;
            use_slacks = true,
            duals = [PSI.CopperPlateBalanceConstraint],
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


# The span `replication_system` reads after the last interval it is built for.
const _REPLICATION_HORIZON = 2DISPATCH_INTERVAL


"""
    replication_system(db, date_range; intervention = 0, interval_flow_limits = false,
        time_series_in_memory = true, time_series_directory = nothing) -> PSY.System

Builds the `System` [`replicate_range`](@ref) steps through: the constrained system from
`nem_system(db, ConstrainedNetworkConfiguration(); ...)` over `date_range`, with demand,
interconnector loss demand coefficients, bids, FCAS scaling inputs, dispatch limits, battery
dispatch ceilings, effective FCAS offers, tie-break scales and MNSP offers set and the time series
transformed into one-interval forecast windows, one per stamp of `date_range`.

# Arguments
- `db`: an `AEMDB` connection whose cache holds data over `date_range`.
- `date_range`: a `StepRange{DateTime}` stepping by 5 minutes over at least two stamps.
- `intervention`: 0 for the pricing run, 1 for the physical run. Applies to the constraint,
  dispatch-limit, interconnector-limit and FCAS-scaling reads; demand, bids and MNSP offers carry no intervention run.
- `interval_flow_limits`: bound each interconnector's flow by the published per-interval
  `IMPORTLIMIT`/`EXPORTLIMIT` ([`set_interconnector_flow_limits!`](@ref)). Those limits are
  computed after NEMDE's solve, so this pins flows to NEMDE's answer: a diagnostic, not for
  validating flows. Default `false` (static limits).
- `time_series_in_memory`: keep the time series in memory (`true`) or in a file.
- `time_series_directory`: the directory of that file when `time_series_in_memory` is `false`;
  `nothing` uses PowerSystems' default.

# Returns
A `PSY.System`. Throws an `ArgumentError` on a `date_range` that does not step by 5 minutes over
at least two stamps, and before setting any input when a scheduled unit of the system lacks an
energy offer, or a region its demand, at an interval of the range.
"""
function replication_system(
        db, date_range::StepRange{DateTime}; intervention::Integer = 0, interval_flow_limits::Bool = false,
        time_series_in_memory::Bool = true, time_series_directory::Union{Nothing, AbstractString} = nothing,
    )
    (step(date_range) == DISPATCH_INTERVAL && length(date_range) >= 2) || throw(
        ArgumentError(
            "replication_system: the date range must step by $DISPATCH_INTERVAL over at least two stamps, got $date_range.",
        ),
    )
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


# Zero gap tolerances: the loss encoding makes the problem a MILP, and HiGHS' default relative gap
# lets dispatch stop short of the optimum.
const _DEFAULT_OPTIMIZER = JuMP.optimizer_with_attributes(
    HiGHS.Optimizer, "mip_rel_gap" => 0.0, "mip_abs_gap" => 1.0e-10,
)


# A one-interval `DecisionModel` of `template` on `sys` from `initial_time`.
function _replication_decision_model(
        template::PSI.ProblemTemplate, sys::PSY.System, initial_time::DateTime;
        optimizer = _DEFAULT_OPTIMIZER, name = "replication",
    )
    return PSI.DecisionModel(
        template, sys;
        optimizer = optimizer, horizon = DISPATCH_INTERVAL, resolution = DISPATCH_INTERVAL,
        interval = DISPATCH_INTERVAL, initial_time = initial_time, name = name,
    )
end


# PSI ignores a failed dual LP and leaves the duals NaN, so check them before reporting prices.
function _check_prices_finite(prices::DataFrame)
    bad = prices[.!isfinite.(prices.ROP), :]
    isempty(bad) || error(
        "Interval $(minimum(bad.SETTLEMENTDATE)) has non-finite regional price duals; the dual pass failed.",
    )
    return
end


# Logs the skipped-constraint count by reason and the table, for a build or solve that failed.
function _log_skipped_constraints(skipped::DataFrame)
    by_reason = combine(groupby(skipped, :reason), nrow => :n)
    counts = join(("$(r.reason)=$(r.n)" for r in eachrow(sort(by_reason, :reason))), ", ")
    @error "Skipped constraints at failure: $(nrow(skipped)) ($counts)" skipped
    return
end


# Every elastic slack family, as `slack variable type => (family, direction)`. `direction` is
# `"up"` for a slack that relaxes a `<=` row and `"down"` for one that relaxes a `>=` row; the
# FCAS families whose rows have both senses refine it per key in `_violation_direction`.
const _VIOLATION_FAMILIES = (
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


# The long-format (`DateTime`, `name`, `value`) frame of each of `keys`: solved values of a model,
# realized values of a simulation's decision problem.
function _read_variable_frames(results::PSI.OptimizationProblemResults, keys)
    return Dict(key => PSI.read_variable(results, key) for key in keys)
end
function _read_variable_frames(results::PSI.SimulationProblemResults, keys)
    isempty(keys) && return Dict{PSI.VariableKey, DataFrame}()
    names = Dict(key => PSI.IS.Optimization.encode_key_as_string(key) for key in keys)
    vals = PSI.read_realized_variables(results, collect(values(names)))
    return Dict(key => vals[name] for (key, name) in names)
end


# The stamps at which `sys`'s generic constraint `name` is invoked.
function _invoked_stamps(sys::PSY.System, name::AbstractString)
    ts = PSY.get_time_series(PSY.SingleTimeSeries, PSY.get_component(GenericConstraint, sys, name), "invoked")
    data = PSY.get_data(ts)
    return Set(t for (t, v) in zip(PSY.TimeSeries.timestamp(data), PSY.TimeSeries.values(data)) if v != 0.0)
end


# `family`, `name`, `DateTime`, `MW`, `direction` and `variable` (the slack variable's key) of
# every slack above the tolerance, in every interval and every family of `_VIOLATION_FAMILIES`;
# a generic constraint's slack counts only where it is invoked.
function _constraint_violations(
        results::Union{PSI.OptimizationProblemResults, PSI.SimulationProblemResults}, sys::PSY.System,
    )
    kinds = Dict(_VIOLATION_FAMILIES)
    rows = NamedTuple{
        (:family, :name, :DateTime, :MW, :direction, :variable),
        Tuple{String, String, DateTime, Float64, String, String},
    }[]
    slack_keys = [key for key in PSI.list_variable_keys(results) if haskey(kinds, PSI.IS.Optimization.get_entry_type(key))]
    frames = _read_variable_frames(results, slack_keys)
    invoked = Dict{String, Set{DateTime}}()
    for key in slack_keys
        type = PSI.IS.Optimization.get_entry_type(key)
        kind = kinds[type]
        for r in eachrow(frames[key])
            r.value > _VIOLATION_TOLERANCE_MW || continue
            kind[1] == "generic_constraint" && !(r.DateTime in get!(() -> _invoked_stamps(sys, r.name), invoked, r.name)) &&
                continue
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


# Each dispatch variable's sign in net MW: generation (or discharge) minus charge.
const _DISPATCH_SIGNS = Dict(
    PSI.ActivePowerVariable => 1.0, PSI.ActivePowerOutVariable => 1.0, PSI.ActivePowerInVariable => -1.0,
)


function _read_balance_duals(results::PSI.OptimizationProblemResults)
    return PSI.read_dual(results, PSI.CopperPlateBalanceConstraint, PSY.Area)
end
function _read_balance_duals(results::PSI.SimulationProblemResults)
    return only(values(PSI.read_realized_duals(results, [PSI.ConstraintKey(PSI.CopperPlateBalanceConstraint, PSY.Area)])))
end


# The solved side of `_compare_to_published`, over every interval of `results`: `prices`
# (`SETTLEMENTDATE`, `REGIONID`, `ROP`), `dispatch` (`DUID`, net `TOTALCLEARED`), `interconnectors`
# (`INTERCONNECTORID`, `MWFLOW`, `MWLOSSES`) and `fcas_prices` ([`compute_fcas_prices`](@ref)).
# With `:losses` in `parts`, the interchange flow and loss variables must be in `results`.
function _solved_tables(results, sys::PSY.System, parts)
    keys_of(T, C) = [
        k for k in PSI.list_variable_keys(results)
            if PSI.IS.Optimization.get_entry_type(k) === T && (isnothing(C) || PSI.IS.Optimization.get_component_type(k) === C)
    ]
    interchange_keys = [only(keys_of(T, PSY.AreaInterchange)) for T in (PSI.FlowActivePowerVariable, InterconnectorLossVariable) if !isempty(keys_of(T, PSY.AreaInterchange))]
    if :losses in parts && !isempty(PSY.get_components(PSY.get_available, PSY.AreaInterchange, sys)) && length(interchange_keys) != 2
        error("Losses are modeled but the results lack the AreaInterchange flow or loss variables.")
    end
    dispatch_keys = PSI.VariableKey[k for T in keys(_DISPATCH_SIGNS) for k in keys_of(T, nothing)]
    frames = _read_variable_frames(results, [dispatch_keys; interchange_keys])

    # A balance dual is per per-unit-interval; dividing gives $/MWh.
    scale = PSY.get_base_power(sys) * interval_hours(DISPATCH_INTERVAL)
    prices = @chain _read_balance_duals(results) begin
        select(:DateTime => :SETTLEMENTDATE, :name => :REGIONID, :value => ByRow(v -> v / scale) => :ROP)
    end
    signed = [transform(frames[k], :value => (v -> _DISPATCH_SIGNS[PSI.IS.Optimization.get_entry_type(k)] .* v) => :value) for k in dispatch_keys]
    dispatch = @chain reduce(vcat, signed; init = DataFrame(DateTime = DateTime[], name = String[], value = Float64[])) begin
        groupby([:DateTime, :name])
        combine(:value => sum => :TOTALCLEARED)
        rename(:DateTime => :SETTLEMENTDATE, :name => :DUID)
    end
    interconnectors = if length(interchange_keys) == 2
        flow, loss = (rename(frames[k], :value => c) for (k, c) in zip(interchange_keys, (:MWFLOW, :MWLOSSES)))
        @chain flow begin
            leftjoin(loss; on = [:DateTime, :name])
            rename(:DateTime => :SETTLEMENTDATE, :name => :INTERCONNECTORID)
        end
    else
        DataFrame(SETTLEMENTDATE = DateTime[], INTERCONNECTORID = String[], MWFLOW = Float64[], MWLOSSES = Union{Missing, Float64}[])
    end
    fcas_prices = compute_fcas_prices(results, sys; resolution = DISPATCH_INTERVAL)
    return (; prices, dispatch, interconnectors, fcas_prices)
end


# Every published row of `steps` with its solved value, `missing` where the model has none. Every
# table is keyed by `SETTLEMENTDATE` and its own key column.
function _compare_to_published(published, solved, steps)
    at_steps(df) = filter(:SETTLEMENTDATE => in(Set(steps)), df)
    compare(table, on) = leftjoin(
        at_steps(published[table]), at_steps(solved[table]);
        on = [:SETTLEMENTDATE, on], renamecols = "_published" => "_solved",
    )
    return (;
        prices = compare(:prices, :REGIONID),
        dispatch = compare(:dispatch, :DUID),
        interconnectors = compare(:interconnectors, :INTERCONNECTORID),
        fcas_prices = leftjoin(
            at_steps(select(published.fcas_prices, :SETTLEMENTDATE, :REGIONID, :BIDTYPE, :ROP)),
            at_steps(solved.fcas_prices); on = [:SETTLEMENTDATE, :REGIONID, :BIDTYPE], renamecols = "_published" => "_solved",
        ),
    )
end
