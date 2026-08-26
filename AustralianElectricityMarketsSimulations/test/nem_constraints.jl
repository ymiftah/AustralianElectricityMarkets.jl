# `GenericConstraint` as a `PSI.Service` (`TermConstraint`), energy terms only. Built
# against the PSCB fixture (`test/pscb_fixture.jl`/`test/pscb_nemweb_data.jl`), self-contained
# like `tiers.jl` - not dependent on run order elsewhere in `runtests.jl`.

using HiGHS
using TimeSeries: TimeArray
import PowerSimulations as PSI
const AEMS = AustralianElectricityMarketsSimulations
const ISOPT = PSI.IS.Optimization

include(joinpath(@__DIR__, "..", "..", "test", "pscb_fixture.jl"))
include(joinpath(@__DIR__, "..", "..", "test", "pscb_nemweb_data.jl"))
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

"""
    _retime_gc_series!(sys, params, overrides, invoked_overrides = Dict{String, Vector{Float64}}())

Replaces every added [`GenericConstraint`](@ref)'s `"rhs"`/`"invoked"` `Deterministic` series
with one anchored to the fixture's own native forecast window (`params`, from
[`_native_forecast_params`](@ref)) instead of NEMWEB's 2025 dates - the only way both can be
fed into the same `DecisionModel`. `overrides` maps a `GENCONID` to a replacement constant
`"rhs"` value (e.g. deliberately tightened below its unconstrained flow); every other constraint
keeps its `add_nem_constraints!`-assigned value. `invoked_overrides` maps a `GENCONID` to a full
raw `"invoked"` vector (length `params.count + params.horizon / params.interval - 1`), letting a
test exercise a genuinely mixed `0.0`/`1.0` series; every other constraint stays `fill(1.0, ...)`.
Adds as raw `SingleTimeSeries` (no forecast-shape constraint applies to those) and converts the
whole system in one `transform_single_time_series!` call, so every series ends up sharing the
identical shape.
"""
function _retime_gc_series!(
        sys, params, overrides::Dict{String, Float64},
        invoked_overrides::Dict{String, Vector{Float64}} = Dict{String, Vector{Float64}}(),
    )
    n_steps = Int(params.horizon / params.interval)
    n_raw = params.count + n_steps - 1
    times = collect(
        params.initial_timestamp:params.interval:(params.initial_timestamp + params.interval * (n_raw - 1)),
    )
    for name in NEM_CONSTRAINTS_GENCON_IDS
        gc = get_component(GenericConstraint, sys, name)
        rhs_value = get(overrides, name) do
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
    _prepared_system(overrides = Dict{String, Float64}(), invoked_overrides = Dict{String, Vector{Float64}}())

An `augmented_pscb_system()` with the thermal floor fixed, all five PSCB fixture constraints
added via [`add_nem_constraints!`](@ref), and their `"rhs"`/`"invoked"` series retimed to the
fixture's own native forecast window (optionally overriding specific constraints' RHS values
and/or supplying a full mixed `"invoked"` series - see [`_retime_gc_series!`](@ref)).
"""
function _prepared_system(
        overrides::Dict{String, Float64} = Dict{String, Float64}(),
        invoked_overrides::Dict{String, Vector{Float64}} = Dict{String, Vector{Float64}}(),
    )
    sys = augmented_pscb_system()
    _fix_thermal_floor!(sys)
    add_nem_constraints!(sys, NEM_CONSTRAINTS_DB, NEM_CONSTRAINTS_DATE_RANGE)
    params = _native_forecast_params(sys)
    _retime_gc_series!(sys, params, overrides, invoked_overrides)
    return sys
end

function _nem_service_template()
    template = _t1_template()
    PSI.set_service_model!(
        template,
        PSI.ServiceModel(GenericConstraint, AEMS.TermConstraint; duals = [AEMS.NEMConstraintLimit]),
    )
    return template
end

@testset "TermConstraint sits under AbstractNEMConstraintFormulation, under PSI's own formulation type" begin
    @test AEMS.TermConstraint <: AEMS.AbstractNEMConstraintFormulation <: PSI.AbstractServiceFormulation
end

@testset "add_nem_constraints! attaches all five as Services with resolved contributing devices" begin
    sys = _prepared_system()
    mapping = get_contributing_device_mapping(sys)
    n_ic1_key = only(k for k in keys(mapping) if k.name == "N_IC1_LIMIT")
    @test Set(typeof.(mapping[n_ic1_key].contributing_devices)) == Set([ThermalStandard, AreaInterchange])
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
    # TermConstraint service model applied.
    tightened_rhs = unconstrained_lhs / 2
    sys = _prepared_system(Dict("N_IC1_LIMIT" => tightened_rhs))
    template = _nem_service_template()
    model = PSI.DecisionModel(template, sys; optimizer = HiGHS.Optimizer, horizon = Hour(2))
    @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
    PSI.solve!(model)
    @test PSI.get_run_status(model) == PSI.RunStatus.SUCCESSFULLY_FINALIZED

    container = PSI.get_optimization_container(model)
    ckeys = PSI.get_constraint_keys(container)

    # (a) the constraint key exists.
    nem_keys = [k for k in ckeys if ISOPT.get_entry_type(k) === AEMS.NEMConstraintLimit]
    @test any(k -> k.meta == "N_IC1_LIMIT", nem_keys)
    # F_R1_RAISE6SEC/F_R2_LOWERREG (non-ENERGY terms) and N_HYDRO_LIMIT (HydroTurbine isn't
    # modeled by this test's own T1 template) are skipped whole - Step 6 - so only N_IC1_LIMIT and
    # N_PARTIAL ever reach `add_constraints!`.
    @test Set(k.meta for k in nem_keys) == Set(["N_IC1_LIMIT", "N_PARTIAL"])

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
    dual_key = only(k for k in nem_keys if k.meta == "N_IC1_LIMIT")
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

@testset "Step 4: an un-invoked interval is skipped, not crashed on or phantom-enforced" begin
    # The fixture's own retimed grid has exactly 2 (hourly) time steps - see
    # `_native_forecast_params`. Mixing `invoked = 0.0` at the first step and `1.0` at the
    # second exercises the exact branch `add_constraints!` skips: without the container fix,
    # `PSI.calculate_dual_variables!` throws `UndefRefError` reading the unfilled cell.
    baseline_sys = _prepared_system()
    baseline_template = AEMS.build_template(AEMS.T1Interconnected())
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
    template = _nem_service_template()
    model = PSI.DecisionModel(template, sys; optimizer = HiGHS.Optimizer, horizon = Hour(2))
    @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
    PSI.solve!(model)
    @test PSI.get_run_status(model) == PSI.RunStatus.SUCCESSFULLY_FINALIZED

    container = PSI.get_optimization_container(model)
    nem_keys = [
        k for k in PSI.get_constraint_keys(container)
            if ISOPT.get_entry_type(k) === AEMS.NEMConstraintLimit
    ]
    dual_key = only(k for k in nem_keys if k.meta == "N_IC1_LIMIT")
    dual_df = PSI.read_dual(PSI.OptimizationProblemResults(model), dual_key)
    dual_t1 = only(subset(dual_df, :DateTime => ByRow(==(t1)))).value
    dual_t2 = only(subset(dual_df, :DateTime => ByRow(==(t2)))).value

    res = PSI.OptimizationProblemResults(model)
    flow = PSI.read_variable(res, "FlowActivePowerVariable__AreaInterchange")
    thermal = PSI.read_variable(res, "ActivePowerVariable__ThermalStandard")
    lhs_t1 = _lhs(thermal, flow, t1)
    lhs_t2 = _lhs(thermal, flow, t2)

    # Not invoked at t1: the vacuous placeholder constraint reads back a dual of exactly 0.0,
    # and the LHS is free to exceed the RHS that would otherwise bound it (14.68 > 8.47 in a
    # run of this test) - proof the RHS was never actually enforced there, not a coincidence.
    @test isapprox(dual_t1, 0.0; atol = 1.0e-6)
    @test lhs_t1 > tightened_rhs + 1.0e-3

    # Invoked at t2: binds exactly like Step 1's single-interval case.
    @test isapprox(lhs_t2, tightened_rhs; atol = 1.0e-3)
    @test isfinite(dual_t2)
    @test !isapprox(dual_t2, 0.0; atol = 1.0e-6)
end
