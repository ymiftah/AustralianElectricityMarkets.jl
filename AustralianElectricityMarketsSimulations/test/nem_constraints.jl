# `GenericConstraint` as a `PSI.Service` (`LinearFactorLimit`), energy terms only. Built
# against the PSCB fixture (`test/integration/pscb_fixture.jl`/`pscb_nemweb_data.jl`),
# self-contained like `tiers.jl` — not dependent on run order elsewhere in `runtests.jl`.

using HiGHS
using TimeSeries: TimeArray
import PowerSimulations as PSI
import StorageSystemsSimulations
const AEMS = AustralianElectricityMarketsSimulations
const ISOPT = PSI.IS.Optimization

include(joinpath(@__DIR__, "..", "..", "test", "integration", "pscb_fixture.jl"))
include(joinpath(@__DIR__, "..", "..", "test", "integration", "pscb_nemweb_data.jl"))
include(joinpath(@__DIR__, "template_helpers.jl"))

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

# Sundance's 100 MW floor exceeds fixture demand under no-commitment dispatch; same fix
# `tiers.jl` applies before building any `augmented_pscb_system()` template.
function _fix_thermal_floor!(sys)
    for gen in get_components(ThermalStandard, sys)
        limits = get_active_power_limits(gen)
        set_active_power_limits!(gen, (min = 0.0, max = limits.max))
    end
    return
end

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

`augmented_pscb_system()`'s own baked-in `Deterministic` forecast shape - PSY requires every
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
    _add_storage_constraint!(sys, params, rhs_mw)

Attaches an extra `<=` `GenericConstraint` named `N_BAT_LIMIT`, one ENERGY `UnitTerm` on
`BAT1` (the fixture's only storage unit), with raw `"rhs"`/`"invoked"` series ready for
[`_retime_gc_series!`](@ref)'s `transform_single_time_series!`. `rhs_mw` is a natural-MW value;
stored per-unit (matching every other `GenericConstraint` in this system - see
`src/constraints/build.jl`).

Built here rather than in the shared NEMWEB fixture because PSI's own
`_populate_contributing_devices!` errors outright when *every* contributing device of a service
is of a type the template doesn't model, so a storage-only constraint must never reach the
storage-free `_t1_template`.
"""
function _add_storage_constraint!(sys, params, rhs_mw::Float64)
    base_power = get_base_power(sys)
    rhs_pu = rhs_mw / base_power
    times, n_raw = _raw_series_times(params)
    gc = GenericConstraint(;
        name = "N_BAT_LIMIT",
        sense = ConstraintSense.LE,
        rhs = rhs_pu,
        terms = ConstraintTerm[UnitTerm("BAT1", BidType.ENERGY, 1.0)],
    )
    add_service!(sys, gc, [get_component(EnergyReservoirStorage, sys, "BAT1")])
    add_time_series!(
        sys, gc, SingleTimeSeries(; name = "rhs", data = TimeArray(times, fill(rhs_pu, n_raw))),
    )
    add_time_series!(
        sys, gc,
        SingleTimeSeries(; name = "invoked", data = TimeArray(times, fill(1.0, n_raw))),
    )
    return
end

"""
    _retime_gc_series!(sys, params, overrides_mw, invoked_overrides = Dict{String, Vector{Float64}}())

Replaces every added [`GenericConstraint`](@ref)'s `"rhs"`/`"invoked"` `Deterministic` series
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
            first(values(get_data(get_time_series(Deterministic, gc, "rhs"))))[1]
        end
        invoked_values = get(invoked_overrides, name, fill(1.0, n_raw))
        remove_time_series!(sys, Deterministic, gc, "rhs")
        remove_time_series!(sys, Deterministic, gc, "invoked")
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
        invoked_overrides::Dict{String, Vector{Float64}} = Dict{String, Vector{Float64}}();
        storage_constraint_rhs::Union{Nothing, Float64} = nothing,
    )
    sys = augmented_pscb_system()
    _fix_thermal_floor!(sys)
    add_nem_constraints!(sys, NEM_CONSTRAINTS_DB, NEM_CONSTRAINTS_DATE_RANGE)
    _remove_unused_pscb_constraints!(sys)
    params = _native_forecast_params(sys)
    # Added before the retime, whose trailing `transform_single_time_series!` converts its raw
    # series along with every other constraint's.
    isnothing(storage_constraint_rhs) ||
        _add_storage_constraint!(sys, params, storage_constraint_rhs)
    _retime_gc_series!(sys, params, overrides_mw, invoked_overrides)
    return sys
end

"""
    _prune_unbuildable_constraints!(sys)

Removes the [`GenericConstraint`](@ref)s that `_t1_template()`'s device models can never build
under [`LinearFactorLimit`](@ref): `F_R1_RAISE6SEC`/`F_R2_LOWERREG` carry non-ENERGY terms, and
`N_HYDRO_LIMIT` touches a `HydroTurbine`, which `_t1_template()` doesn't model. Used by tests
that exercise the constraint actually binding, not the loud failure for an unbuildable one.
"""
function _prune_unbuildable_constraints!(sys)
    for id in ("F_R1_RAISE6SEC", "F_R2_LOWERREG", "N_HYDRO_LIMIT")
        remove_component!(sys, _gc(sys, id))
    end
    return
end

function _nem_service_template()
    template = _t1_template()
    PSI.set_service_model!(
        template,
        PSI.ServiceModel(GenericConstraint, AEMS.LinearFactorLimit; duals = [AEMS.NEMConstraintLimit]),
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

@testset "LinearFactorLimit sits under AbstractNEMConstraintFormulation, under PSI's own formulation type" begin
    @test AEMS.LinearFactorLimit <: AEMS.AbstractNEMConstraintFormulation <: PSI.AbstractServiceFormulation
end

@testset "add_nem_constraints! attaches them as Services with resolved contributing devices" begin
    sys = _prepared_system()
    gc = _gc(sys, "N_IC1_LIMIT")
    devices = get_contributing_devices(sys, gc)
    @test Set(typeof.(devices)) == Set([ThermalStandard, AreaInterchange])
end

@testset "an unsupported bid_type throws, naming the constraint and the term" begin
    sys = _prepared_system()
    for id in ("F_R2_LOWERREG", "N_HYDRO_LIMIT", "N_IC1_LIMIT", "N_PARTIAL")
        remove_component!(sys, _gc(sys, id))
    end
    model = PSI.DecisionModel(_nem_service_template(), sys; optimizer = HiGHS.Optimizer, horizon = Hour(2))
    err = _build_error(model)
    @test err isa ArgumentError
    msg = sprint(showerror, err)
    @test occursin("F_R1_RAISE6SEC", msg)
    @test occursin("bid_type", msg)
end

@testset "a device type this template doesn't model throws, naming the constraint and the device" begin
    sys = _prepared_system()
    for id in ("F_R1_RAISE6SEC", "F_R2_LOWERREG", "N_IC1_LIMIT", "N_PARTIAL")
        remove_component!(sys, _gc(sys, id))
    end
    model = PSI.DecisionModel(_nem_service_template(), sys; optimizer = HiGHS.Optimizer, horizon = Hour(2))
    err = _build_error(model)
    @test err isa ArgumentError
    msg = sprint(showerror, err)
    @test occursin("N_HYDRO_LIMIT", msg)
    @test occursin("template must model", msg)
end

@testset "Step 1: a tightened GenericConstraint binds and changes T1 dispatch" begin
    # Phase 1: solve without any service model to learn N_IC1_LIMIT's unconstrained flow
    # (ParkCity + Sundance - IC1 flow) at the first time step.
    baseline_sys = _prepared_system()
    baseline_template = _t1_template()
    baseline_model = PSI.DecisionModel(baseline_template, baseline_sys; optimizer = HiGHS.Optimizer, horizon = Hour(2))
    @test PSI.build!(baseline_model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
    PSI.solve!(baseline_model)
    @test PSI.get_run_status(baseline_model) == PSI.RunStatus.SUCCESSFULLY_FINALIZED

    baseline_res = PSI.OptimizationProblemResults(baseline_model)
    baseline_thermal = PSI.read_variable(baseline_res, "ActivePowerVariable__ThermalStandard")
    baseline_flow = PSI.read_variable(baseline_res, "FlowActivePowerVariable__AreaInterchange")
    t1 = minimum(baseline_flow.DateTime)
    park_city = only(subset(baseline_thermal, :DateTime => ByRow(==(t1)), :name => ByRow(==("Park City")))).value
    sundance = only(subset(baseline_thermal, :DateTime => ByRow(==(t1)), :name => ByRow(==("Sundance")))).value
    ic1_flow = only(subset(baseline_flow, :DateTime => ByRow(==(t1)), :name => ByRow(==("IC1")))).value
    unconstrained_lhs = park_city + sundance - ic1_flow
    @test unconstrained_lhs > 0.0  # otherwise there's nothing to tighten below

    # Phase 2: rebuild with N_IC1_LIMIT's rhs tightened to half the unconstrained flow, and the
    # LinearFactorLimit service model applied to a system pruned to what _t1_template can build.
    tightened_rhs = unconstrained_lhs / 2
    sys = _prepared_system(Dict("N_IC1_LIMIT" => tightened_rhs))
    _prune_unbuildable_constraints!(sys)
    template = _nem_service_template()
    model = PSI.DecisionModel(template, sys; optimizer = HiGHS.Optimizer, horizon = Hour(2))
    @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
    PSI.solve!(model)
    @test PSI.get_run_status(model) == PSI.RunStatus.SUCCESSFULLY_FINALIZED

    container = PSI.get_optimization_container(model)
    ckeys = PSI.get_constraint_keys(container)

    # (a) the constraint key exists for both surviving constraints.
    nem_keys = [k for k in ckeys if ISOPT.get_entry_type(k) === AEMS.NEMConstraintLimit]
    @test Set(k.meta for k in nem_keys) ==
        Set(PSY.get_name(gc) for gc in get_components(GenericConstraint, sys))

    # (b) dispatch actually changed versus the unconstrained baseline, and the constraint binds
    # tightly (LHS ~ RHS, not just "some slack away from it").
    res = PSI.OptimizationProblemResults(model)
    flow = PSI.read_variable(res, "FlowActivePowerVariable__AreaInterchange")
    thermal = PSI.read_variable(res, "ActivePowerVariable__ThermalStandard")
    constrained_ic1_flow = only(subset(flow, :DateTime => ByRow(==(t1)), :name => ByRow(==("IC1")))).value
    constrained_park_city = only(subset(thermal, :DateTime => ByRow(==(t1)), :name => ByRow(==("Park City")))).value
    constrained_sundance = only(subset(thermal, :DateTime => ByRow(==(t1)), :name => ByRow(==("Sundance")))).value
    constrained_lhs = constrained_park_city + constrained_sundance - constrained_ic1_flow

    @test !isapprox(constrained_ic1_flow, ic1_flow; atol = 1.0e-3)  # dispatch changed
    @test isapprox(constrained_lhs, tightened_rhs; atol = 1.0e-3)  # and it's because the constraint binds

    # (c) the dual is finite and non-zero while binding.
    ic1_name = PSY.get_name(_gc(sys, "N_IC1_LIMIT"))
    dual_key = only(k for k in nem_keys if k.meta == ic1_name)
    dual_df = PSI.read_dual(res, dual_key)
    dual_at_t1 = only(subset(dual_df, :DateTime => ByRow(==(t1)))).value
    @test isfinite(dual_at_t1)
    @test !isapprox(dual_at_t1, 0.0; atol = 1.0e-6)
end

"""
    _lhs(thermal, flow, t)

`N_IC1_LIMIT`'s LHS (`ParkCity + Sundance - IC1_flow`) at time `t`, from `read_variable`
DataFrames - shared by Step 1 and Step 4's tests.
"""
function _lhs(thermal, flow, t)
    park_city = only(subset(thermal, :DateTime => ByRow(==(t)), :name => ByRow(==("Park City")))).value
    sundance = only(subset(thermal, :DateTime => ByRow(==(t)), :name => ByRow(==("Sundance")))).value
    ic1_flow = only(subset(flow, :DateTime => ByRow(==(t)), :name => ByRow(==("IC1")))).value
    return park_city + sundance - ic1_flow
end

@testset "Step 4: an un-invoked interval reads a dual of 0.0 and never phantom-enforces" begin
    # The fixture's own retimed grid has exactly 2 (hourly) time steps - see
    # `_native_forecast_params`. Mixing `invoked = 0.0` at the first step and `1.0` at the
    # second exercises the exact branch `add_constraints!` treats specially: without it, PSI's
    # dual read-back would either throw (vacuous, dense container left `#undef`) or read a
    # stale key (sparse, if the cell were mistakenly populated).
    baseline_sys = _prepared_system()
    baseline_template = _t1_template()
    baseline_model = PSI.DecisionModel(baseline_template, baseline_sys; optimizer = HiGHS.Optimizer, horizon = Hour(2))
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

    tightened_rhs = unconstrained_lhs_t2 / 2
    sys = _prepared_system(
        Dict("N_IC1_LIMIT" => tightened_rhs), Dict("N_IC1_LIMIT" => invoked_vec),
    )
    _prune_unbuildable_constraints!(sys)
    template = _nem_service_template()
    model = PSI.DecisionModel(template, sys; optimizer = HiGHS.Optimizer, horizon = Hour(2))
    @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
    PSI.solve!(model)
    @test PSI.get_run_status(model) == PSI.RunStatus.SUCCESSFULLY_FINALIZED

    container = PSI.get_optimization_container(model)
    ic1_name = PSY.get_name(_gc(sys, "N_IC1_LIMIT"))
    nem_keys = [
        k for k in PSI.get_constraint_keys(container)
            if ISOPT.get_entry_type(k) === AEMS.NEMConstraintLimit
    ]
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

    # Invoked at t2: binds exactly like Step 1's single-interval case.
    @test isapprox(lhs_t2, tightened_rhs; atol = 1.0e-3)
    @test isfinite(dual_t2)
    @test !isapprox(dual_t2, 0.0; atol = 1.0e-6)
end

"""
    _storage_template()

[`_nem_service_template`](@ref) plus a storage device model, so `N_BAT_LIMIT`'s `BAT1` term is
modeled rather than throwing. `ThermalStandardDispatch` (not `_t1_template`'s
`ThermalBasicUnitCommitment`) so the build also exercises PSI's initial-conditions sub-model,
which calls `get_initial_conditions_service_model` for every registered `ServiceModel`.
"""
function _storage_template()
    template = _nem_service_template()
    PSI.set_device_model!(template, PSY.ThermalStandard, PSI.ThermalStandardDispatch)
    PSI.set_device_model!(
        template,
        PSI.DeviceModel(
            PSY.EnergyReservoirStorage, StorageSystemsSimulations.StorageDispatchWithReserves;
            attributes = Dict(
                "reservation" => true, "energy_target" => false,
                "cycling_limits" => false, "regularization" => false,
            ),
        ),
    )
    return template
end

"`BAT1`'s net injection (out - in) at time `t`, from `read_variable` DataFrames."
function _bat_net(out_df, in_df, t)
    out = only(subset(out_df, :DateTime => ByRow(==(t)), :name => ByRow(==("BAT1")))).value
    inp = only(subset(in_df, :DateTime => ByRow(==(t)), :name => ByRow(==("BAT1")))).value
    return out - inp
end

@testset "Step 7: a storage unit's ENERGY term is modeled, not skipped" begin
    # Storage has no ActivePowerVariable - StorageDispatchWithReserves splits it into
    # ActivePowerOutVariable/ActivePowerInVariable. Keying the term off ActivePowerVariable
    # alone classifies every battery as an unmodeled device type.
    #
    # Phase 1: a deliberately slack RHS, to learn BAT1's unconstrained net injection.
    baseline_sys = _prepared_system(; storage_constraint_rhs = 1.0e4)
    _prune_unbuildable_constraints!(baseline_sys)
    baseline_model = PSI.DecisionModel(
        _storage_template(), baseline_sys; optimizer = HiGHS.Optimizer, horizon = Hour(2),
    )
    @test PSI.build!(baseline_model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
    PSI.solve!(baseline_model)
    @test PSI.get_run_status(baseline_model) == PSI.RunStatus.SUCCESSFULLY_FINALIZED

    baseline_res = PSI.OptimizationProblemResults(baseline_model)
    baseline_out = PSI.read_variable(baseline_res, "ActivePowerOutVariable__EnergyReservoirStorage")
    baseline_in = PSI.read_variable(baseline_res, "ActivePowerInVariable__EnergyReservoirStorage")
    t1, t2 = sort(unique(baseline_out.DateTime))
    unconstrained_net = _bat_net(baseline_out, baseline_in, t1)
    @test unconstrained_net > 0.0  # otherwise there's nothing to tighten below

    # Phase 2: tightened to half of it.
    tightened_rhs = unconstrained_net / 2
    sys = _prepared_system(; storage_constraint_rhs = tightened_rhs)
    _prune_unbuildable_constraints!(sys)
    model = PSI.DecisionModel(
        _storage_template(), sys; optimizer = HiGHS.Optimizer, horizon = Hour(2),
    )
    @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
    PSI.solve!(model)
    @test PSI.get_run_status(model) == PSI.RunStatus.SUCCESSFULLY_FINALIZED

    container = PSI.get_optimization_container(model)
    nem_keys = [
        k for k in PSI.get_constraint_keys(container)
            if ISOPT.get_entry_type(k) === AEMS.NEMConstraintLimit
    ]
    # (a) the storage constraint is built.
    @test "N_BAT_LIMIT" in Set(k.meta for k in nem_keys)

    # (b) it binds tightly on the battery's net injection, which changed from the baseline.
    res = PSI.OptimizationProblemResults(model)
    out_df = PSI.read_variable(res, "ActivePowerOutVariable__EnergyReservoirStorage")
    in_df = PSI.read_variable(res, "ActivePowerInVariable__EnergyReservoirStorage")
    constrained_net = _bat_net(out_df, in_df, t1)
    @test isapprox(constrained_net, tightened_rhs; atol = 1.0e-3)
    @test constrained_net < unconstrained_net - 1.0e-3

    # (c) the constraint's dual is registered and readable.
    dual_key = only(k for k in nem_keys if k.meta == "N_BAT_LIMIT")
    dual_at_t1 = only(subset(PSI.read_dual(res, dual_key), :DateTime => ByRow(==(t1)))).value
    @test isfinite(dual_at_t1)

    # The RHS series is flat, so the cap applies at every step, not just the first.
    @test _bat_net(out_df, in_df, t2) <= tightened_rhs + 1.0e-3
end
