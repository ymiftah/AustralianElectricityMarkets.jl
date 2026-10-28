# `GenericConstraint` as a `PSI.Service` (`LinearFactorLimit`), energy terms only. Built
# against the PSCB fixture (`test/integration/pscb_fixture.jl`/`pscb_nemweb_data.jl`), which
# `runtests.jl` loads.

using HiGHS
using TimeSeries: TimeArray
import PowerSimulations as PSI
const AEMS = AustralianElectricityMarketsSimulations
const ISOPT = PSI.IS.Optimization

@testset "Constraint lookup preserves abstract name resolution and phase lifetime" begin
    sys = augmented_pscb_system()
    device = first(get_components(ThermalStandard, sys))
    name = get_name(device)
    lookup = AEMS._ConstraintComponentLookup(sys)
    @test AEMS._constraint_component(PSY.Device, lookup, name) === device
    @test AEMS._constraint_component(PSY.Device, lookup, name) === device
    @test isnothing(AEMS._constraint_component(PSY.Device, lookup, "missing device"))
    @test isnothing(AEMS._constraint_component(PSY.Device, lookup, "missing device"))

    other = first(get_components(RenewableDispatch, sys))
    remove_component!(sys, other)
    set_name!(other, name)
    add_component!(sys, other)
    fresh = AEMS._ConstraintComponentLookup(sys)
    @test_throws ArgumentError AEMS._constraint_component(PSY.Device, fresh, name)
    @test AEMS._constraint_component(ThermalStandard, fresh, name) === device
    @test AEMS._constraint_component(RenewableDispatch, fresh, name) === other
end

const NEM_CONSTRAINTS_HIVE_DIR = mktempdir()
create_pscb_nemweb_data(NEM_CONSTRAINTS_HIVE_DIR)
const NEM_CONSTRAINTS_DB = aem_connect(
    HiveConfiguration(; hive_location = NEM_CONSTRAINTS_HIVE_DIR, filesystem = "file"),
)
const NEM_CONSTRAINTS_START = DateTime(2025, 1, 1, 0, 0)
const NEM_CONSTRAINTS_DATE_RANGE =
    NEM_CONSTRAINTS_START:Minute(5):(NEM_CONSTRAINTS_START + Hour(2) + Minute(5))
const NEM_CONSTRAINTS_GENCON_IDS =
    ("F_R1_RAISE6SEC", "F_R2_LOWERREG", "N_HYDRO_LIMIT", "N_IC1_LIMIT", "N_PARTIAL")

"""
    _gc(sys, gencon_id) -> GenericConstraint

The one [`GenericConstraint`](@ref) in `sys` whose [`get_gencon_id`](@ref) is `gencon_id`.
`add_nem_constraints!` names components `GENCONID@EFFECTIVEDATE#VERSIONNO`, so bare `GENCONID`
values (this file's own fixture ids) aren't valid component names.
"""
_gc(sys, gencon_id::AbstractString) =
    only(gc for gc in get_components(GenericConstraint, sys) if get_gencon_id(gc) == gencon_id)

"""
    _native_forecast_params(sys)

`augmented_pscb_system()`'s own baked-in forecast shape (read from its `DeterministicSingleTimeSeries`) - PSY requires every
`Forecast`-derived time series in a `System` to share one `(initial_timestamp, resolution,
interval, count, horizon)`, so a `GenericConstraint`'s `"rhs"`/`"invoked"` series (added by
`add_nem_constraints!` on a 2025 NEMWEB grid) can't coexist with the fixture's own 2020-dated
`PowerLoad` demand data unless retimed to match exactly - see [`_retime_gc_series!`](@ref).
"""
function _native_forecast_params(sys)
    load = first(get_components(PowerLoad, sys))
    dts = get_time_series(DeterministicSingleTimeSeries, load, "max_active_power")
    return (
        initial_timestamp = dts.initial_timestamp, interval = dts.interval,
        count = dts.count, horizon = dts.horizon,
    )
end

"The `(times, length)` every raw `SingleTimeSeries` in this file is built on, from `params`."
function _raw_series_times(params)
    n_raw = params.count + Int(params.horizon / params.interval) - 1
    last_time = params.initial_timestamp + params.interval * (n_raw - 1)
    return collect(params.initial_timestamp:params.interval:last_time), n_raw
end

"""
    _retime_gc_series!(sys, params, overrides_mw, invoked_overrides = Dict{String, Vector{Float64}}())

Replaces every added [`GenericConstraint`](@ref)'s `"rhs"`/`"invoked"` `SingleTimeSeries` series
with one anchored to the fixture's own native forecast window (`params`, from
[`_native_forecast_params`](@ref)) instead of NEMWEB's 2025 dates - the only way both can be
fed into the same `DecisionModel`. `overrides_mw` maps a `GENCONID` to a replacement constant
`"rhs"` value in natural MW (e.g. deliberately tightened below its unconstrained flow), converted
to per-unit before storage; every other constraint keeps its `add_nem_constraints!`-assigned
per-unit value. `invoked_overrides` maps a `GENCONID` to a full raw `"invoked"` vector (length
`params.count + params.horizon / params.interval - 1`), letting a test exercise a genuinely
mixed `0.0`/`1.0` series; every other constraint stays `fill(1.0, ...)`.
"""
function _retime_gc_series!(
        sys, params, overrides_mw::Dict{String, Float64},
        invoked_overrides::Dict{String, Vector{Float64}} = Dict{String, Vector{Float64}}(),
    )
    base_power = get_base_power(sys)
    times, n_raw = _raw_series_times(params)
    for name in NEM_CONSTRAINTS_GENCON_IDS
        gc = _gc(sys, name)
        rhs_value = if haskey(overrides_mw, name)
            overrides_mw[name] / base_power
        else
            get_time_series_values(SingleTimeSeries, gc, "rhs")[1]
        end
        invoked_values = get(invoked_overrides, name, fill(1.0, n_raw))
        remove_time_series!(sys, SingleTimeSeries, gc, "rhs")
        remove_time_series!(sys, SingleTimeSeries, gc, "invoked")
        add_time_series!(sys, gc, SingleTimeSeries(; name = "rhs", data = TimeArray(times, fill(rhs_value, n_raw))))
        add_time_series!(sys, gc, SingleTimeSeries(; name = "invoked", data = TimeArray(times, invoked_values)))
    end
    transform_single_time_series!(sys, params.horizon, params.interval)
    return
end

"""
    _remove_unused_pscb_constraints!(sys)

Removes every `N_VERSIONED_LIMIT` [`GenericConstraint`](@ref) `add_nem_constraints!` builds
from the PSCB fixture. This file's own [`NEM_CONSTRAINTS_GENCON_IDS`](@ref) never retimes them
(no test here exercises version switching), so left in place their raw NEMWEB-resolution
`"rhs"`/`"invoked"` series would conflict with every other constraint's retimed series the
moment any `PSI.DecisionModel` is built over this system - regardless of whether a service model
is even registered for [`GenericConstraint`](@ref).
"""
function _remove_unused_pscb_constraints!(sys)
    for gc in collect(get_components(GenericConstraint, sys))
        get_gencon_id(gc) == "N_VERSIONED_LIMIT" && remove_component!(sys, gc)
    end
    return
end

"""
    _prepared_system(overrides_mw = Dict{String, Float64}(), invoked_overrides = Dict{String, Vector{Float64}}())

An `augmented_pscb_system()` with the thermal floor fixed, every PSCB fixture constraint this
file uses added via [`add_nem_constraints!`](@ref) (`N_VERSIONED_LIMIT` removed - see
[`_remove_unused_pscb_constraints!`](@ref)), and their `"rhs"`/`"invoked"` series retimed to the
fixture's own native forecast window (optionally overriding specific constraints' RHS values
and/or supplying a full mixed `"invoked"` series - see [`_retime_gc_series!`](@ref)).
"""
function _prepared_system(
        overrides_mw::Dict{String, Float64} = Dict{String, Float64}(),
        invoked_overrides::Dict{String, Vector{Float64}} = Dict{String, Vector{Float64}}(),
    )
    sys = augmented_pscb_system()
    _fix_thermal_floor!(sys)
    add_nem_constraints!(sys, NEM_CONSTRAINTS_DB, NEM_CONSTRAINTS_DATE_RANGE)
    _remove_unused_pscb_constraints!(sys)
    params = _native_forecast_params(sys)
    _retime_gc_series!(sys, params, overrides_mw, invoked_overrides)
    return sys
end

"""
    _prune_unbuildable_constraints!(sys)

Removes the [`GenericConstraint`](@ref)s that `_area_balance_template()`'s device models can never build
under [`LinearFactorLimit`](@ref): `F_R1_RAISE6SEC`/`F_R2_LOWERREG` carry non-ENERGY terms, and
`N_HYDRO_LIMIT` touches a `HydroTurbine`, which `_area_balance_template()` doesn't model. Used by tests
that exercise the constraint actually binding, not the loud failure for an unbuildable one.
"""
function _prune_unbuildable_constraints!(sys)
    for id in ("F_R1_RAISE6SEC", "F_R2_LOWERREG", "N_HYDRO_LIMIT")
        remove_component!(sys, _gc(sys, id))
    end
    return
end

function _nem_service_template(; use_slacks::Bool = false, market_price_cap::Union{Nothing, Float64} = nothing)
    template = _area_balance_template()
    attributes = isnothing(market_price_cap) ? Dict{String, Any}() :
        Dict{String, Any}("market_price_cap" => market_price_cap)
    PSI.set_service_model!(
        template,
        PSI.ServiceModel(
            GenericConstraint, AEMS.LinearFactorLimit; duals = [AEMS.NEMConstraintLimit],
            use_slacks = use_slacks, attributes = attributes,
        ),
    )
    return template
end

"Builds and returns the `ArgumentError` `PSI.build_impl!(model)` throws, or `nothing` if it
doesn't throw. `PSI.build!` itself swallows every build exception into a `FAILED` status, so
exercising the underlying error requires calling the lower-level entry point directly."
function _build_error(model)
    PSI.set_output_dir!(model, mktempdir())
    try
        PSI.build_impl!(model)
    catch e
        return e
    end
    return nothing
end

@testset "add_nem_constraints! attaches them as Services with resolved contributing devices" begin
    sys = _prepared_system()
    gc = _gc(sys, "N_IC1_LIMIT")
    devices = get_contributing_devices(sys, gc)
    @test Set(typeof.(devices)) == Set([ThermalStandard, AreaInterchange])
end

"""
    _add_fcas_services!(sys)

Adds the [`FCASService`](@ref)s `F_R1_RAISE6SEC`/`F_R2_LOWERREG` reference, one per device area, each
over the constraint's contributing devices in that area.
"""
function _add_fcas_services!(sys)
    for (id, bid_type) in (("F_R1_RAISE6SEC", BidType.RAISE6SEC), ("F_R2_LOWERREG", BidType.LOWERREG))
        by_name = Dict{String, Vector{Device}}()
        for d in get_contributing_devices(sys, _gc(sys, id))
            push!(get!(by_name, fcas_service_name(d, bid_type), Device[]), d)
        end
        for (name, devices) in by_name
            region = get_name(get_area(get_bus(first(devices))))
            add_service!(sys, FCASService(; name = name, region = region, bid_type = bid_type), devices)
        end
    end
    return
end

@testset "an FCAS term whose service the template doesn't model throws, naming the constraint and the term" begin
    sys = _prepared_system()
    for id in ("F_R2_LOWERREG", "N_HYDRO_LIMIT", "N_IC1_LIMIT", "N_PARTIAL")
        remove_component!(sys, _gc(sys, id))
    end
    add_service!(
        sys, FCASService(; name = "1_RAISE6SEC", region = "1", bid_type = BidType.RAISE6SEC),
        get_contributing_devices(sys, _gc(sys, "F_R1_RAISE6SEC")),
    )
    model = _decision_model(_nem_service_template(), sys; optimizer = HiGHS.Optimizer, horizon = Hour(2))
    err = _build_error(model)
    @test err isa ArgumentError
    msg = sprint(showerror, err)
    @test occursin("F_R1_RAISE6SEC", msg)
    @test occursin("1_RAISE6SEC", msg)
end

@testset "a device type this template doesn't model throws, naming the constraint and the device" begin
    sys = _prepared_system()
    for id in ("F_R1_RAISE6SEC", "F_R2_LOWERREG", "N_IC1_LIMIT", "N_PARTIAL")
        remove_component!(sys, _gc(sys, id))
    end
    model = _decision_model(_nem_service_template(), sys; optimizer = HiGHS.Optimizer, horizon = Hour(2))
    err = _build_error(model)
    @test err isa ArgumentError
    msg = sprint(showerror, err)
    @test occursin("N_HYDRO_LIMIT", msg)
    @test occursin("template must model", msg)
end

"""
    _lhs(thermal, flow, t)

`N_IC1_LIMIT`'s LHS (`ParkCity + Sundance - IC1_flow`) at time `t`, from `read_variable` DataFrames.
"""
function _lhs(thermal, flow, t)
    park_city = only(subset(thermal, :DateTime => ByRow(==(t)), :name => ByRow(==("Park City")))).value
    sundance = only(subset(thermal, :DateTime => ByRow(==(t)), :name => ByRow(==("Sundance")))).value
    ic1_flow = only(subset(flow, :DateTime => ByRow(==(t)), :name => ByRow(==("IC1")))).value
    return park_city + sundance - ic1_flow
end

@testset "Step 4: an un-invoked interval reads a dual of 0.0 and never phantom-enforces, with and without slacks" begin
    # The fixture's own retimed grid has exactly 2 (hourly) time steps - see
    # `_native_forecast_params`. Mixing `invoked = 0.0` at the first step and `1.0` at the
    # second exercises the exact branch `add_constraints!` treats specially: without it, PSI's
    # dual read-back would either throw (vacuous, dense container left `#undef`) or read a
    # stale key (sparse, if the cell were mistakenly populated).
    baseline_sys = _prepared_system()
    baseline_template = _area_balance_template()
    baseline_model = _decision_model(baseline_template, baseline_sys; optimizer = HiGHS.Optimizer, horizon = Hour(2))
    @test PSI.build!(baseline_model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
    PSI.solve!(baseline_model)
    @test PSI.get_run_status(baseline_model) == PSI.RunStatus.SUCCESSFULLY_FINALIZED

    baseline_res = PSI.OptimizationProblemResults(baseline_model)
    baseline_thermal = PSI.read_variable(baseline_res, "ActivePowerVariable__ThermalStandard")
    baseline_flow = PSI.read_variable(baseline_res, "FlowActivePowerVariable__AreaInterchange")
    t1, t2 = sort(unique(baseline_flow.DateTime))
    unconstrained_lhs_t2 = _lhs(baseline_thermal, baseline_flow, t2)
    @test unconstrained_lhs_t2 > 0.0  # otherwise there's nothing to tighten below

    # `n_raw` mirrors `_retime_gc_series!`'s own formula exactly, so index 1 lands on `t1`.
    probe_params = _native_forecast_params(augmented_pscb_system())
    n_raw = probe_params.count + Int(probe_params.horizon / probe_params.interval) - 1
    invoked_vec = vcat([0.0], fill(1.0, n_raw - 1))  # t1: not invoked; t2 onward: invoked

    for use_slacks in (false, true)
        tightened_rhs = unconstrained_lhs_t2 / 2
        sys = _prepared_system(
            Dict("N_IC1_LIMIT" => tightened_rhs), Dict("N_IC1_LIMIT" => invoked_vec),
        )
        _prune_unbuildable_constraints!(sys)
        template = _nem_service_template(; use_slacks = use_slacks)
        model = _decision_model(template, sys; optimizer = HiGHS.Optimizer, horizon = Hour(2))
        @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
        PSI.solve!(model)
        @test PSI.get_run_status(model) == PSI.RunStatus.SUCCESSFULLY_FINALIZED

        container = PSI.get_optimization_container(model)
        ic1_name = PSY.get_name(_gc(sys, "N_IC1_LIMIT"))
        nem_keys = [
            k for k in PSI.get_constraint_keys(container)
                if ISOPT.get_entry_type(k) === AEMS.NEMConstraintLimit
        ]
        @test Set(k.meta for k in nem_keys) == Set(PSY.get_name(gc) for gc in get_components(GenericConstraint, sys))
        dual_key = only(k for k in nem_keys if k.meta == ic1_name)
        dual_df = PSI.read_dual(PSI.OptimizationProblemResults(model), dual_key)
        dual_t1 = only(subset(dual_df, :DateTime => ByRow(==(t1)))).value
        dual_t2 = only(subset(dual_df, :DateTime => ByRow(==(t2)))).value

        res = PSI.OptimizationProblemResults(model)
        flow = PSI.read_variable(res, "FlowActivePowerVariable__AreaInterchange")
        thermal = PSI.read_variable(res, "ActivePowerVariable__ThermalStandard")
        lhs_t1 = _lhs(thermal, flow, t1)
        lhs_t2 = _lhs(thermal, flow, t2)

        # Not invoked at t1: the vacuous placeholder constraint reads back a dual of exactly 0.0,
        # and the LHS is free to exceed the RHS that would otherwise bound it - proof the RHS was
        # never actually enforced there, not a coincidence.
        @test isapprox(dual_t1, 0.0; atol = 1.0e-6)
        @test lhs_t1 > tightened_rhs + 1.0e-3
        if use_slacks
            # The row exists and is violated; its free slack makes it vacuous with a dual of zero.
            @test abs(dual_t1) <= 1.0e-9
            slack_t1 = only(subset(PSI.read_variable(res, "GenericConstraintSlackUp__GenericConstraint__$ic1_name"), :DateTime => ByRow(==(t1)))).value
            @test slack_t1 >= lhs_t1 - tightened_rhs - 1.0e-3
        end

        # Invoked at t2: binds exactly like Step 1's single-interval case.
        @test isapprox(lhs_t2, tightened_rhs; atol = 1.0e-3)
        @test isfinite(dual_t2)
        @test !isapprox(dual_t2, 0.0; atol = 1.0e-6)
    end
end

@testset "the slack cost parameter follows the invoked mask and a recurrent build needs slacks" begin
    n_raw = let p = _native_forecast_params(augmented_pscb_system())
        p.count + Int(p.horizon / p.interval) - 1
    end
    invoked_vec = vcat([0.0], fill(1.0, n_raw - 1))
    sys = _prepared_system(Dict("N_IC1_LIMIT" => 100.0), Dict("N_IC1_LIMIT" => invoked_vec))
    _prune_unbuildable_constraints!(sys)
    model = _decision_model(_nem_service_template(; use_slacks = true), sys; optimizer = HiGHS.Optimizer, horizon = Hour(2))
    @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
    container = PSI.get_optimization_container(model)
    gc = _gc(sys, "N_IC1_LIMIT")
    name = PSY.get_name(gc)
    param = PSI.get_parameter(container, AEMS.GenericConstraintSlackCostParameter(), GenericConstraint, name)
    @test PSI.get_parameter_column_refs(param, name)[1:2] == [0.0, 1.0]

    # A recurrent build masks non-invoked intervals with zero-cost slacks, so it needs use_slacks.
    bare = _decision_model(_nem_service_template(; use_slacks = false), sys; optimizer = HiGHS.Optimizer, horizon = Hour(2))
    @test PSI.build!(bare; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
    bare_container = PSI.get_optimization_container(bare)
    bare_container.built_for_recurrent_solves = true
    err = _caught() do
        PSI.add_constraints!(
            bare_container, NEMConstraintLimit, gc,
            PSI.ServiceModel(GenericConstraint, LinearFactorLimit; use_slacks = false),
        )
    end
    @test err isa ArgumentError
    @test occursin("use_slacks = true", err.msg)
end

@testset "generic-constraint slack costs equal invoked x weight x base x interval coefficient x MPC at build and after an update" begin
    n_raw = let p = _native_forecast_params(augmented_pscb_system())
        p.count + Int(p.horizon / p.interval) - 1
    end
    invoked_vec = vcat([0.0], fill(1.0, n_raw - 1))
    sys = _prepared_system(Dict("N_IC1_LIMIT" => 100.0), Dict("N_IC1_LIMIT" => invoked_vec))
    _prune_unbuildable_constraints!(sys)
    model = _decision_model(_nem_service_template(; use_slacks = true), sys; mpc = 20_300.0, optimizer = HiGHS.Optimizer, horizon = Hour(2))
    @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
    container = PSI.get_optimization_container(model)
    gc = _gc(sys, "N_IC1_LIMIT")
    name = PSY.get_name(gc)
    @test AustralianElectricityMarkets.constraint_cvp_factor(gc) == 1.0
    @test PSI.get_base_power(container) == 100.0
    @test PSI.get_resolution(container) == Hour(1)
    key = PSI.ParameterKey(AEMS.GenericConstraintSlackCostParameter, GenericConstraint, name)
    invoked = () -> PSI.get_parameter_column_refs(PSI.get_parameter(container, key), name)
    @test invoked()[1:2] == [0.0, 1.0]

    # Each slack's cost target: invoked x weight 1.0 x 100 MW base x 20,300 $/MWh x one hour.
    function check_slack_costs()
        variant = PSI.get_variant_terms(PSI.get_objective_expression(container))
        checked = 0
        for slack_type in (AEMS.GenericConstraintSlackUp, AEMS.GenericConstraintSlackDown)
            PSI.has_container_key(container, slack_type, GenericConstraint, name) || continue
            slack = PSI.get_variable(container, slack_type(), GenericConstraint, name)
            for t in 1:2
                checked += 1
                @test PSI.JuMP.coefficient(variant, slack[name, t]) ≈ invoked()[t] * 1.0 * 20_300.0 * 100.0
            end
        end
        @test checked > 0
    end
    check_slack_costs()

    # A simulation step from the second interval re-reads the invoked series for its window and re-applies the costs.
    PSI.set_execution_count!(model, 1)
    PSI.cost_function_unsynch(container)
    PSI.reset_variant_terms(PSI.get_objective_expression(container))
    PSI.update_container_parameter_values!(container, model, key, PSI.DatasetContainer{PSI.InMemoryDataset}())
    PSI.set_execution_count!(model, 0)
    @test invoked()[1:2] == [1.0, 1.0]
    check_slack_costs()
end

@testset "Buildable generic constraints: the default throws one aggregated ArgumentError, and allow_partial_coverage returns the subset" begin
    sys = _prepared_system()
    _add_fcas_services!(sys)
    template = _area_balance_template()
    err = _caught(() -> _buildable_gcs(sys, template))
    @test err isa ArgumentError
    msg = sprint(showerror, err)
    @test occursin("F_R1_RAISE6SEC", msg)
    @test occursin("F_R2_LOWERREG", msg)
    @test occursin("N_HYDRO_LIMIT", msg)
    @test occursin("FCASMarket", msg)
    @test occursin("allow_partial_coverage", msg)
    @test !occursin("N_IC1_LIMIT", msg)
    @test !occursin("N_PARTIAL", msg)

    expected = Set(PSY.get_name(_gc(sys, id)) for id in ("N_IC1_LIMIT", "N_PARTIAL"))
    result = @test_logs (:warn,) _buildable_gcs(sys, template; allow_partial_coverage = true)
    @test Set(PSY.get_name.(result)) == expected
    @test issorted(PSY.get_name.(result))

    skipped = []
    @test_logs (:warn,) _buildable_gcs(sys, template; allow_partial_coverage = true, skipped = skipped)
    all_names = Set(PSY.get_name.(PSY.get_components(GenericConstraint, sys)))
    @test Set(r.constraint for r in skipped) == setdiff(all_names, expected)
    @test all(r -> r.n_missing >= 1, skipped)
end

@testset "the buildable subset builds and solves under per-instance registration, where the aggregated registration throws; a left-out constraint is recorded" begin
    sys = _prepared_system()
    _add_fcas_services!(sys)
    template = _area_balance_template()
    buildable = _buildable_gcs(sys, template; allow_partial_coverage = true)

    aggregated_template = _area_balance_template()
    PSI.set_service_model!(
        aggregated_template,
        PSI.ServiceModel(GenericConstraint, AEMS.LinearFactorLimit; duals = [AEMS.NEMConstraintLimit]),
    )
    aggregated_model = _decision_model(
        aggregated_template, sys; optimizer = HiGHS.Optimizer, horizon = Hour(2),
    )
    @test _build_error(aggregated_model) isa ArgumentError

    filtered_template = _area_balance_template()
    for gc in buildable
        name = PSY.get_name(gc)
        PSI.set_service_model!(
            filtered_template, name,
            PSI.ServiceModel(
                GenericConstraint, AEMS.LinearFactorLimit, name;
                duals = [AEMS.NEMConstraintLimit],
            ),
        )
    end
    model = _decision_model(filtered_template, sys; optimizer = HiGHS.Optimizer, horizon = Hour(2))
    @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
    PSI.solve!(model)
    @test PSI.get_run_status(model) == PSI.RunStatus.SUCCESSFULLY_FINALIZED

    container = PSI.get_optimization_container(model)
    nem_keys = [
        k for k in PSI.get_constraint_keys(container)
            if ISOPT.get_entry_type(k) === AEMS.NEMConstraintLimit
    ]
    @test Set(k.meta for k in nem_keys) == Set(PSY.get_name.(buildable))

    # A constraint whose contributing devices are all unavailable is left out, recorded, and not a failure.
    left_out = _gc(sys, "N_PARTIAL")
    PSY.set_available!.(PSY.get_contributing_devices(sys, left_out), false)
    skipped = @NamedTuple{constraint::String, reason::Symbol, n_missing::Int}[]
    left_out_template = _area_balance_template()
    left_out_buildable = _buildable_gcs(
        sys, left_out_template; allow_partial_coverage = true, skipped = skipped,
    )
    @test filter(r -> r.reason == :no_available_device, skipped) ==
        [(constraint = PSY.get_name(left_out), reason = :no_available_device, n_missing = 0)]
    @test PSY.get_name(left_out) ∉ PSY.get_name.(left_out_buildable)

    for gc in left_out_buildable
        name = PSY.get_name(gc)
        PSI.set_service_model!(
            left_out_template, name,
            PSI.ServiceModel(GenericConstraint, AEMS.LinearFactorLimit, name; duals = [AEMS.NEMConstraintLimit]),
        )
    end
    left_out_model = _decision_model(left_out_template, sys; optimizer = HiGHS.Optimizer, horizon = Hour(2))
    @test PSI.build!(left_out_model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
end

@testset "a hard GE and LE GenericConstraint pair on one unit is infeasible" begin
    # A 150 MW floor and a 10 MW ceiling on the same unit cannot both hold, whatever the dispatch bounds.
    sys = nem_toy_system(
        [TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = 60.0, ramp_up = 100.0)], 80.0;
        mutate! = function (sys, stamps)
            add_toy_generic_constraint!(sys, stamps, TOY_CHEAP, 150.0; sense = ConstraintSense.GE, name = "N_FLOOR")
            add_toy_generic_constraint!(sys, stamps, TOY_CHEAP, 10.0; sense = ConstraintSense.LE, name = "N_CEIL")
        end,
    )
    template = PSI.ProblemTemplate(PSI.NetworkModel(PSI.AreaBalancePowerModel; use_slacks = true))
    set_nem_dispatch_models!(template, sys)
    PSI.set_device_model!(template, PSY.PowerLoad, PSI.StaticPowerLoad)
    PSI.set_service_model!(template, PSI.ServiceModel(GenericConstraint, LinearFactorLimit; duals = [NEMConstraintLimit]))
    model = PSI.DecisionModel(
        template, sys; optimizer = HiGHS.Optimizer, horizon = TOY_RESOLUTION, resolution = TOY_RESOLUTION,
        interval = TOY_RESOLUTION, initial_time = TOY_START, name = "nem_toy_infeasible",
    )
    @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
    @test PSI.solve!(model) != PSI.RunStatus.SUCCESSFULLY_FINALIZED
end

@testset "Market Price Cap lookup covers only the published financial years" begin
    @test AustralianElectricityMarkets._financial_year_mpc(DateTime(2025, 6, 30)) == 17_500.0
    @test AustralianElectricityMarkets._financial_year_mpc(DateTime(2025, 7, 1)) == 17_500.0  # interval 23:55-00:00 on 30 June
    @test AustralianElectricityMarkets._financial_year_mpc(DateTime(2025, 7, 1, 0, 5)) == 20_300.0
    @test AustralianElectricityMarkets._financial_year_mpc(DateTime(2026, 6, 30, 23, 55)) == 20_300.0
    @test AustralianElectricityMarkets._financial_year_mpc(DateTime(2026, 7, 1)) == 20_300.0
    @test AustralianElectricityMarkets._financial_year_mpc(DateTime(2026, 7, 1, 0, 5)) == 23_200.0
    @test AustralianElectricityMarkets._financial_year_mpc(DateTime(2027, 7, 1)) == 23_200.0
    @test_throws r"No published Market Price Cap" AustralianElectricityMarkets._financial_year_mpc(DateTime(2024, 7, 1))
    @test_throws r"No published Market Price Cap" AustralianElectricityMarkets._financial_year_mpc(DateTime(2027, 7, 1, 0, 5))
end

@testset "check_single_financial_year: a range within one financial year passes, one across 1 July is refused" begin
    AEMS.check_single_financial_year(DateTime(2025, 6, 30, 23, 55):Minute(5):DateTime(2025, 7, 1))
    @test_throws ArgumentError AEMS.check_single_financial_year(DateTime(2025, 7, 1):Minute(5):DateTime(2025, 7, 1, 0, 5))
end

@testset "area-balance slack Market Price Cap: unpublished year throws, settings entry overrides" begin
    # _prepared_system() is dated 2020, outside AustralianElectricityMarkets.MARKET_PRICE_CAP_BY_FINANCIAL_YEAR.
    pruned_system() = (sys = _prepared_system(); _prune_unbuildable_constraints!(sys); sys)
    model = PSI.DecisionModel(_nem_service_template(), pruned_system(); optimizer = HiGHS.Optimizer, horizon = Hour(2))
    err = _build_error(model)
    @test err isa ArgumentError
    @test occursin("No published Market Price Cap", sprint(showerror, err))

    model = _decision_model(
        _nem_service_template(), pruned_system(); mpc = 10_000.0, optimizer = HiGHS.Optimizer, horizon = Hour(2),
    )
    @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
    container = PSI.get_optimization_container(model)
    objective_terms = PSI.JuMP.objective_function(PSI.get_jump_model(container)).terms
    expected = PSI.get_base_power(container) *
        interval_cost_coefficient(AustralianElectricityMarkets.AREA_BALANCE_CVP_FACTOR * 10_000.0, PSI.get_resolution(container))
    for var_type in (PSI.SystemBalanceSlackUp, PSI.SystemBalanceSlackDown)
        slack = PSI.get_variable(container, var_type(), PSY.Area)
        @test all(v -> objective_terms[v] ≈ expected, slack)
    end
end

@testset "Market Price Cap penalties are invariant constants of the initial interval's cap, unchanged by a parameter update" begin
    # 2026-01-06 falls in 2025-26, whose Market Price Cap is 20,300 $/MWh.
    start = DateTime(2026, 1, 6)
    sys = nem_toy_system([TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = 0.0, ramp_up = 100.0)], 50.0; start = start)
    template = PSI.ProblemTemplate(PSI.NetworkModel(PSI.AreaBalancePowerModel; use_slacks = true))
    set_nem_dispatch_models!(template, sys)
    PSI.set_device_model!(template, PSY.PowerLoad, PSI.StaticPowerLoad)
    model = PSI.DecisionModel(
        template, sys; optimizer = HiGHS.Optimizer, horizon = 2 * TOY_RESOLUTION,
        resolution = TOY_RESOLUTION, interval = TOY_RESOLUTION, initial_time = start,
    )
    @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
    container = PSI.get_optimization_container(model)
    # 150 CVP x 20,300 $/MWh x 100 MW base x 5 minutes.
    expected = 150.0 * 20_300.0 * 100.0 / 12
    slacks = [PSI.get_variable(container, v(), PSY.Area) for v in (PSI.SystemBalanceSlackUp, PSI.SystemBalanceSlackDown)]
    objective = PSI.JuMP.objective_function(PSI.get_jump_model(container))
    for slack in slacks, name in axes(slack)[1], t in axes(slack)[2]
        @test PSI.JuMP.coefficient(objective, slack[name, t]) ≈ expected
    end

    # A parameter update rebuilds the variant terms and leaves the priced constants in the invariant objective.
    PSI.cost_function_unsynch(container)
    PSI.reset_variant_terms(PSI.get_objective_expression(container))
    input = PSI.DatasetContainer{PSI.InMemoryDataset}()
    for key in collect(Base.keys(PSI.get_parameters(model)))
        PSI.update_container_parameter_values!(container, model, key, input)
    end
    objective_function = PSI.get_objective_expression(container)
    for slack in slacks, name in axes(slack)[1], t in axes(slack)[2]
        @test PSI.JuMP.coefficient(PSI.get_invariant_terms(objective_function), slack[name, t]) ≈ expected
        @test PSI.JuMP.coefficient(PSI.get_variant_terms(objective_function), slack[name, t]) == 0.0
    end
end

@testset "terms on an unavailable interconnector or unit contribute zero and build" begin
    sys = _prepared_system()
    _prune_unbuildable_constraints!(sys)
    PSY.set_available!(PSY.get_component(PSY.AreaInterchange, sys, "IC1"), false)
    PSY.set_available!(PSY.get_component(PSY.ThermalStandard, sys, "Sundance"), false)
    model = _decision_model(_nem_service_template(), sys; optimizer = HiGHS.Optimizer, horizon = Hour(2))
    @test isnothing(_build_error(model))
end

"""
    _add_zero_flow_pair!(sys, params, interconnector)

Attaches the two `<=` [`GenericConstraint`](@ref)s of an Interconnector Zero pair on `interconnector`
(`-flow <= 0` and `flow <= 0`, right-hand side 0), the built-in shape `add_nem_constraints!` builds
with no weight of its own. Added before [`_retime_gc_series!`](@ref).
"""
function _add_zero_flow_pair!(sys, params, interconnector::AbstractString)
    times, n_raw = _raw_series_times(params)
    for (name, factor) in (("ZERO_NEG", -1.0), ("ZERO_POS", 1.0))
        gc = GenericConstraint(;
            name = name, sense = ConstraintSense.LE, rhs = 0.0,
            terms = ConstraintTerm[InterconnectorTerm(interconnector, factor)],
            ext = Dict{String, Any}("limit_type" => "Interconnector Zero", "source" => "built-in"),
        )
        add_service!(sys, gc, [get_component(AreaInterchange, sys, interconnector)])
        add_time_series!(sys, gc, SingleTimeSeries(; name = "rhs", data = TimeArray(times, zeros(n_raw))))
        add_time_series!(sys, gc, SingleTimeSeries(; name = "invoked", data = TimeArray(times, ones(n_raw))))
    end
    return
end

@testset "an invoked Interconnector Zero pair holds the net flow at zero, elastic at 1160 x MPC" begin
    # Unconstrained, IC1 carries a non-zero flow.
    baseline_sys = _prepared_system()
    baseline_model = _decision_model(
        _area_balance_template(), baseline_sys; optimizer = HiGHS.Optimizer, horizon = Hour(2),
    )
    @test PSI.build!(baseline_model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
    PSI.solve!(baseline_model)
    baseline_flow = PSI.read_variable(
        PSI.OptimizationProblemResults(baseline_model), "FlowActivePowerVariable__AreaInterchange",
    )
    @test any(v -> abs(v) > 1.0e-3, subset(baseline_flow, :name => ByRow(==("IC1"))).value)

    sys = augmented_pscb_system()
    _fix_thermal_floor!(sys)
    add_nem_constraints!(sys, NEM_CONSTRAINTS_DB, NEM_CONSTRAINTS_DATE_RANGE)
    _remove_unused_pscb_constraints!(sys)
    params = _native_forecast_params(sys)
    weight = AustralianElectricityMarkets.INTERCONNECTOR_ZERO_CVP_FACTOR
    _add_zero_flow_pair!(sys, params, "IC1")
    _retime_gc_series!(sys, params, Dict{String, Float64}())
    _prune_unbuildable_constraints!(sys)

    test_mpc = 20_300.0
    model = _decision_model(
        _nem_service_template(; use_slacks = true, market_price_cap = test_mpc), sys;
        optimizer = HiGHS.Optimizer, horizon = Hour(2),
    )
    @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
    PSI.solve!(model)
    @test PSI.get_run_status(model) == PSI.RunStatus.SUCCESSFULLY_FINALIZED

    results = PSI.OptimizationProblemResults(model)
    flow = PSI.read_variable(results, "FlowActivePowerVariable__AreaInterchange")
    @test all(v -> abs(v) < 1.0e-6, subset(flow, :name => ByRow(==("IC1"))).value)

    # Each row's slack is priced at weight x MPC per MW, in the objective's per-unit scale.
    container = PSI.get_optimization_container(model)
    objective_terms = PSI.JuMP.objective_function(PSI.get_jump_model(container)).terms
    expected = PSI.get_base_power(container) *
        interval_cost_coefficient(weight * test_mpc, PSI.get_resolution(container))
    for name in ("ZERO_NEG", "ZERO_POS")
        slack = PSI.get_variable(container, AEMS.GenericConstraintSlackUp(), GenericConstraint, name)
        @test all(t -> objective_terms[slack[name, t]] ≈ expected, PSI.get_time_steps(container))
        @test !PSI.has_container_key(container, AEMS.GenericConstraintSlackDown, GenericConstraint, name)
    end
end

@testset "AustralianElectricityMarkets.constraint_cvp_factor prices built-in constraints by limit type, others by their GENCONDATA weight" begin
    built_in(limit_type) = GenericConstraint(;
        name = "B", sense = ConstraintSense.LE, rhs = 0.0, terms = ConstraintTerm[],
        ext = Dict{String, Any}("limit_type" => limit_type, "source" => "built-in"),
    )
    @test AustralianElectricityMarkets.constraint_cvp_factor(built_in("Interconnector Zero")) == AustralianElectricityMarkets.INTERCONNECTOR_ZERO_CVP_FACTOR == 1160.0
    @test_throws ArgumentError AustralianElectricityMarkets.constraint_cvp_factor(built_in("Unknown"))
    published = GenericConstraint(;
        name = "P", sense = ConstraintSense.LE, rhs = 0.0, constraint_weight = 35.0, terms = ConstraintTerm[],
        ext = Dict{String, Any}("limit_type" => "Interconnector Zero", "source" => "AEMO"),
    )
    @test AustralianElectricityMarkets.constraint_cvp_factor(published) == 35.0
end
