# T0/T1 as real PowerSimulations.jl problems, built and solved directly via `build_template`
# against `PowerSystemCaseBuilder`'s fixture rather than through `solve_interval`.
#
# `solve_interval`/`_seed_interval_time_series!` seed demand via `set_demand!`, which matches
# time series columns to `PowerLoad` component names of the form "<REGIONID> Load" - the
# convention `nem_system` builds. `augmented_pscb_system()`'s loads keep PowerSystemCaseBuilder's
# own bus names ("bus2", "bus3", "bus4"), so that match always misses and `set_demand!` would
# silently zero every load's demand (confirmed empirically, not guessed) rather than error -
# exactly the "silent pass on missing data" this codebase avoids elsewhere. `solve_interval`
# therefore stays a `nem_system`-only entry point; this test instead drives `build_template`'s
# `ProblemTemplate` through PSI's `DecisionModel`/`build!`/`solve!` directly, against the PSCB
# system's own native (2020-01-01, hourly, 2-hour horizon) time series, which is
# supply-adequate by construction and needs no NEMWEB seeding at all.

using HiGHS
import PowerSimulations as PSI

include(joinpath(@__DIR__, "..", "..", "test", "pscb_fixture.jl"))

# Sundance's static MINCAPACITY floor (100 MW, in natural units) exceeds this fixture's entire
# demand (~71 MW static max, ~42 MW actual at the tested hour) - a genuine box-constraint
# contradiction that makes every `ThermalBasicDispatch`-templated interval infeasible regardless
# of tier (confirmed empirically: INFEASIBLE_POINT, independent of ramp/initial-condition or
# network topology - `ThermalBasicUnitCommitment`/T1 sidesteps it by choosing to leave Sundance
# off, but T0 has no commitment decision). Lowering every thermal unit's floor to 0 here
# (fixture-local, not touching `pscb_fixture.jl`) resolves it without changing what the rest of
# the suite exercises - mirrors the dropped `_fix_hydro_floor!` exactly, just for
# `ThermalStandard` instead of `HydroDispatch`.
function _fix_thermal_floor!(sys)
    for gen in get_components(ThermalStandard, sys)
        limits = get_active_power_limits(gen)
        set_active_power_limits!(gen, (min = 0.0, max = limits.max))
    end
    return
end

@testset "T0 copper plate solves via PowerSimulations.jl" begin
    sys = augmented_pscb_system()
    _fix_thermal_floor!(sys)

    template = build_template(T0CopperPlate())
    model = PSI.DecisionModel(template, sys; optimizer = HiGHS.Optimizer, horizon = Hour(2))
    @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
    PSI.solve!(model)
    @test PSI.get_run_status(model) == PSI.RunStatus.SUCCESSFULLY_FINALIZED

    res = PSI.OptimizationProblemResults(model)
    dispatch = PSI.read_variable(res, "ActivePowerVariable__ThermalStandard")
    @test !isempty(dispatch)

    prices = PSI.read_dual(res, "CopperPlateBalanceConstraint__System")
    @test !isempty(prices)
    @test all(isfinite, prices.value)
end

@testset "T1 interconnected solves with per-region prices and negligible slack" begin
    sys = augmented_pscb_system()
    _fix_thermal_floor!(sys)

    template = build_template(T1Interconnected())
    model = PSI.DecisionModel(template, sys; optimizer = HiGHS.Optimizer, horizon = Hour(2))
    @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
    PSI.solve!(model)
    @test PSI.get_run_status(model) == PSI.RunStatus.SUCCESSFULLY_FINALIZED

    res = PSI.OptimizationProblemResults(model)
    dispatch = PSI.read_variable(res, "ActivePowerVariable__ThermalStandard")
    @test !isempty(dispatch)

    prices = PSI.read_dual(res, "CopperPlateBalanceConstraint__Area")
    @test !isempty(prices)
    @test all(isfinite, prices.value)

    # The network model is templated with `use_slacks = true`, so a merely `:optimal`/
    # `SUCCESSFULLY_FINALIZED` status is satisfiable by buying the entire shortfall from slack.
    # Assert slack usage is ~0 - i.e. the balance is actually met by real dispatch, not the
    # slack escape hatch. `AreaBalancePowerModel` keys its slack variables by `PSY.Area`
    # (confirmed empirically), not `System`.
    slack_up = PSI.read_variable(res, "SystemBalanceSlackUp__Area")
    slack_down = PSI.read_variable(res, "SystemBalanceSlackDown__Area")
    @test all(v -> isapprox(v, 0.0; atol = 1.0e-6), slack_up.value)
    @test all(v -> isapprox(v, 0.0; atol = 1.0e-6), slack_down.value)
end
