# T0/T1 as real PowerSimulations.jl problems, built and solved directly via `build_template`
# against `PowerSystemCaseBuilder`'s fixture rather than through `solve_interval`.
#
# `solve_interval` needs `nem_system`-style "<REGIONID> Load" names; PSCB's bus-named loads
# don't match, so this builds/solves directly instead. See docstring on
# `_seed_interval_time_series!`.

using HiGHS
import PowerSimulations as PSI

include(joinpath(@__DIR__, "..", "..", "test", "pscb_fixture.jl"))

# Sundance's 100 MW floor exceeds fixture demand under no-commitment dispatch (T0 has no
# unit-commitment decision to leave it off).
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
