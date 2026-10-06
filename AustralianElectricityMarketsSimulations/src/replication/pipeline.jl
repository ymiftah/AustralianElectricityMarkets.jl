"""
    replication_template(sys) -> PSI.ProblemTemplate

Builds the `ProblemTemplate` that replicates NEMDE on `sys`: [`AbstractNEMDispatch`](@ref) devices
(via [`set_nem_dispatch_models!`](@ref)), `PSI.StaticPowerLoad` demand, [`NEMInterconnectorLoss`](@ref)
on every `PSY.AreaInterchange`, an [`FCASMarket`](@ref) per registered `FCASService`, and a
[`LinearFactorLimit`](@ref) per `GenericConstraint` whose terms the template can model.
Regions balance through `PSI.AreaBalancePowerModel` with slacks, and the balance duals are
recorded as regional prices.

# Arguments
- `sys`: a `PSY.System` from `nem_system(db, ConstrainedNetworkConfiguration(); ...)`, after its
  demand, bids, FCAS scaling inputs and dispatch limits are set.

# Returns
A `PSI.ProblemTemplate`.
"""
function replication_template(sys::PSY.System)
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
    for gc in filter_buildable_generic_constraints(sys, template; allow_partial_coverage = true)
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
  dispatch-limit, interconnector-limit and FCAS-scaling reads; demand and bids carry no intervention run.
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
    all(isfinite, duals.value) ||
        error("Interval $settlement_date has non-finite regional price duals; the dual pass failed.")
    return nothing
end

"""
    replicate_interval(db, settlement_date; intervention = 0, optimizer = HiGHS.Optimizer)
    replicate_interval(sys, db, settlement_date; intervention = 0, optimizer = HiGHS.Optimizer)

Solves one historical NEM dispatch interval with [`replication_template`](@ref) on `sys` (by
default [`replication_system`](@ref)) and compares the solution with AEMO's published outcome.
The model spans the interval and the one after it; the first is reported.

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
A `NamedTuple` with the solved `model`, its `results`, and `comparison`, a `NamedTuple` of
`DataFrame`s with one row per published key and `_solved` and `_published` columns, `missing`
where the model has no solved value: `prices` (`REGIONID`; solved `ROP`, published `ROP` and
`RRP`), `dispatch` (`DUID`, `TOTALCLEARED`), `interconnectors` (`INTERCONNECTORID`, `MWFLOW`,
`MWLOSSES`) and `fcas_prices` (`REGIONID`, `BIDTYPE`, `ROP`). `ramp_violations` lists every
non-zero unit ramp slack of the model (`DUID`, `DateTime`, `MW`, `direction`). The solved balance dual is the
unadjusted price, so it is compared with `ROP`; `RRP` differs only under an administered price.
Throws if the model does not build or solve.
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
    resolution = DISPATCH_INTERVAL
    template = replication_template(sys)
    check_fcas_services(sys, template)
    model = PSI.DecisionModel(
        template, sys;
        optimizer = optimizer, horizon = _REPLICATION_HORIZON, resolution = resolution,
        interval = resolution, initial_time = settlement_date, name = "replication",
    )
    output_dir = mktempdir()
    status = Base.CoreLogging.with_logger(() -> PSI.build!(model; output_dir = output_dir), _DropMILPWarning())
    status == PSI.ModelBuildStatus.BUILT ||
        error("Interval $settlement_date failed to build ($status); see the PSI error log and $output_dir.")
    run_status = PSI.solve!(model)
    run_status == PSI.RunStatus.SUCCESSFULLY_FINALIZED ||
        error("Interval $settlement_date failed to solve: $run_status")
    results = PSI.OptimizationProblemResults(model)
    _check_prices_finite(results, settlement_date)
    return (;
        model, results,
        comparison = _compare_to_published(db, sys, results, settlement_date, intervention),
        ramp_violations = _ramp_violations(results),
    )
end

# `DUID`, `DateTime`, `MW` and `direction` of every non-zero unit ramp slack, in every interval.
function _ramp_violations(results::PSI.OptimizationProblemResults)
    kinds = Dict(UnitRampUpSlack => "up", UnitRampDownSlack => "down")
    rows = NamedTuple{(:DUID, :DateTime, :MW, :direction), Tuple{String, DateTime, Float64, String}}[]
    for key in PSI.list_variable_keys(results)
        direction = get(kinds, PSI.IS.Optimization.get_entry_type(key), nothing)
        isnothing(direction) && continue
        for r in eachrow(PSI.read_variable(results, key))
            r.value > _RAMP_VIOLATION_TOLERANCE_MW &&
                push!(rows, (; DUID = r.name, DateTime = r.DateTime, MW = r.value, direction))
        end
    end
    return DataFrame(rows)
end

"MW of unit ramp slack below which a ramp row counts as satisfied."
const _RAMP_VIOLATION_TOLERANCE_MW = 1.0e-6

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
