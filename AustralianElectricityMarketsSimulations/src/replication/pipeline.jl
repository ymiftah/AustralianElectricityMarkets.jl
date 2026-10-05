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
    replication_system(db, settlement_date) -> PSY.System

Builds the `System` [`replicate_interval`](@ref) solves: the constrained system from
`nem_system(db, ConstrainedNetworkConfiguration(); ...)` over the interval and the one after it
(a single-point forecast cannot be built), with demand, bids, FCAS scaling inputs and dispatch
limits set and the time series transformed into one forecast window.

# Arguments
- `db`: an `AEMDB` connection.
- `settlement_date`: the `SETTLEMENTDATE` of the interval (`DateTime`).

# Returns
A `PSY.System`.
"""
function replication_system(db, settlement_date::DateTime)
    resolution = DISPATCH_INTERVAL
    date_range = settlement_date:resolution:(settlement_date + _REPLICATION_HORIZON)
    sys = nem_system(db, ConstrainedNetworkConfiguration(); date_range = date_range)
    set_demand!(sys, db, date_range; resolution = resolution)
    set_market_bids!(sys, db, date_range; resolution = resolution)
    set_fcas_scaling_inputs!(sys, db, date_range)
    set_nem_dispatch_limits!(sys, db, date_range)
    PSY.transform_single_time_series!(sys, _REPLICATION_HORIZON, resolution)
    return sys
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
  plus `DISPATCHLOAD`, `DISPATCHPRICE` and `DISPATCHINTERCONNECTORRES`.
- `settlement_date`: the `SETTLEMENTDATE` of the interval (`DateTime`).
- `intervention`: 0 for the pricing run, 1 for the physical run.
- `optimizer`: the JuMP optimizer, e.g. `optimizer_with_attributes(HiGHS.Optimizer, ...)`.

# Returns
A `NamedTuple` with the solved `model`, its `results`, and `comparison`, a `NamedTuple` of
`DataFrame`s whose columns carry `_solved` and `_published` suffixes: `prices` (`REGIONID`,
`RRP`), `dispatch` (`DUID`, `TOTALCLEARED`), `interconnectors` (`INTERCONNECTORID`, `MWFLOW`,
`MWLOSSES`) and `fcas_prices` (`REGIONID`, `BIDTYPE`, `ROP`). Throws if the model does not
build or solve.
"""
function replicate_interval(db, settlement_date::DateTime; kwargs...)
    return replicate_interval(replication_system(db, settlement_date), db, settlement_date; kwargs...)
end

function replicate_interval(
        sys::PSY.System, db, settlement_date::DateTime;
        intervention::Integer = 0, optimizer = HiGHS.Optimizer,
    )
    resolution = DISPATCH_INTERVAL
    model = PSI.DecisionModel(
        replication_template(sys), sys;
        optimizer = optimizer, horizon = _REPLICATION_HORIZON, resolution = resolution,
        interval = resolution, initial_time = settlement_date, name = "replication",
    )
    status = PSI.build!(model; output_dir = mktempdir())
    if status != PSI.ModelBuildStatus.BUILT
        # `build!` swallows the exception behind a `FAILED` status; building again surfaces it.
        PSI.set_output_dir!(model, mktempdir())
        PSI.build_impl!(model)
        error("Interval $settlement_date failed to build: $status")
    end
    run_status = PSI.solve!(model)
    run_status == PSI.RunStatus.SUCCESSFULLY_FINALIZED ||
        error("Interval $settlement_date failed to solve: $run_status")
    results = PSI.OptimizationProblemResults(model)
    return (;
        model, results,
        comparison = _compare_to_published(db, sys, results, settlement_date, intervention),
    )
end

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
    interval = settlement_date:resolution:(settlement_date + resolution)
    join_on(on) = (; on, renamecols = "_solved" => "_published")

    # A balance dual is per per-unit-interval; dividing gives $/MWh.
    scale = PSY.get_base_power(sys) * interval_hours(resolution)
    duals = _first_interval(PSI.read_dual(results, "CopperPlateBalanceConstraint__Area"), settlement_date)
    prices = innerjoin(
        DataFrame(; REGIONID = collect(keys(duals)), RRP = collect(values(duals)) ./ scale),
        AustralianElectricityMarkets.read_prices(db, interval; intervention = intervention);
        join_on(:REGIONID)...,
    )

    net = _solved_dispatch(results, settlement_date)
    dispatch = innerjoin(
        DataFrame(; DUID = collect(keys(net)), TOTALCLEARED = collect(values(net))),
        published.dispatch; join_on(:DUID)...,
    )

    flows = _first_interval(PSI.read_variable(results, "FlowActivePowerVariable__AreaInterchange"), settlement_date)
    losses = _first_interval(PSI.read_variable(results, "InterconnectorLossVariable__AreaInterchange"), settlement_date)
    interconnectors = innerjoin(
        DataFrame(;
            INTERCONNECTORID = collect(keys(flows)), MWFLOW = collect(values(flows)),
            MWLOSSES = [get(losses, id, missing) for id in keys(flows)],
        ),
        published.interconnectors; join_on(:INTERCONNECTORID)...,
    )

    fcas_prices = innerjoin(
        compute_fcas_prices(results, sys; resolution = resolution),
        AustralianElectricityMarkets.read_fcas_prices(db, interval; intervention = intervention);
        join_on([:SETTLEMENTDATE, :REGIONID, :BIDTYPE])...,
    )
    return (; prices, dispatch, interconnectors, fcas_prices)
end
