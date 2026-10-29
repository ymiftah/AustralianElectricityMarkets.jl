# A 60 MW conformance target competes with separate 40 MW bid and 45 MW forecast limits.
function energy_limit_system(; max_avail = 100.0, uigf = 45.0, target = 60.0, weight = 1160.0, fixed_load = nothing, fixed_invoked = 1.0, initial = 60.0, down = 100.0, price = 20.0, rating = 100.0, start = TOY_START)
    return nem_toy_system(
        [
            TOY_CHEAP => toy_unit(100.0, [(100.0, price)]; initial, ramp_up = 100.0, ramp_down = down, availability = 45.0),
            TOY_EXPENSIVE => toy_unit(100.0, [(100.0, 80.0)]; initial = 20.0, ramp_up = 100.0),
        ],
        80.0; horizon = TOY_RESOLUTION, start,
        mutate! = function (sys, stamps)
            cheap = PSY.get_component(PSY.ThermalStandard, sys, TOY_CHEAP)
            PSY.set_active_power_limits!(cheap, (min = 0.0, max = rating))
            PSY.remove_time_series!(sys, PSY.SingleTimeSeries, cheap, "energy_max_avail")
            base = PSY.get_base_power(sys)
            PSY.add_time_series!(sys, cheap, PSY.SingleTimeSeries(; name = "energy_max_avail", data = PSY.TimeSeries.TimeArray(stamps, _toy_values(max_avail, 2) ./ base)))
            PSY.get_ext(cheap)["nem_semi_scheduled"] = !isnothing(uigf)
            if !isnothing(uigf)
                PSY.add_time_series!(sys, cheap, PSY.SingleTimeSeries(; name = "uigf", data = PSY.TimeSeries.TimeArray(stamps, _toy_values(uigf, 2) ./ base)))
            end
            if !isnothing(fixed_load)
                PSY.add_time_series!(sys, cheap, PSY.SingleTimeSeries(; name = "fixed_load", data = PSY.TimeSeries.TimeArray(stamps, _toy_values(fixed_load, 2) ./ base)))
                PSY.add_time_series!(sys, cheap, PSY.SingleTimeSeries(; name = "fixed_load_invoked", data = PSY.TimeSeries.TimeArray(stamps, fill(fixed_invoked, 2))))
            end
            if !isnothing(target)
                add_toy_generic_constraint!(sys, stamps, TOY_CHEAP, target; sense = ConstraintSense.EQ)
                only(PSY.get_components(GenericConstraint, sys)).constraint_weight = weight
            end
            return
        end,
    )
end

function energy_limit_solve(sys)
    model = AEMS._replication_decision_model(replication_template(sys), sys, TOY_START; optimizer = optimizer_with_attributes(HiGHS.Optimizer, "output_flag" => false))
    @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
    @test PSI.solve!(model) == PSI.RunStatus.SUCCESSFULLY_FINALIZED
    results = PSI.OptimizationProblemResults(model)
    dispatch = PSI.read_variable(results, "ActivePowerVariable__ThermalStandard")
    return (; results, objective = PSI.JuMP.objective_value(PSI.get_jump_model(PSI.get_optimization_container(model))), power = only(r.value for r in eachrow(dispatch) if r.name == TOY_CHEAP), violations = ReplayResults._constraint_violations(results, sys))
end

function energy_slack(out, type)
    return only(r.value for r in eachrow(PSI.read_variable(out.results, string(nameof(type)) * "__ThermalStandard")) if r.name == TOY_CHEAP)
end

@testset "a static rating does not defeat the separate energy limits" begin
    out = energy_limit_solve(energy_limit_system(; max_avail = 70.0, uigf = 65.0, rating = 30.0))
    @test out.power ≈ 60.0 atol = 1.0e-6
    @test energy_slack(out, EnergyMaxAvailSlack) ≈ 0.0 atol = 1.0e-6
    @test energy_slack(out, EnergyUIGFSlack) ≈ 0.0 atol = 1.0e-6
end

@testset "non-conformance can violate both distinct energy limits" begin
    out = energy_limit_solve(energy_limit_system(; max_avail = 40.0))
    @test out.power ≈ 60.0 atol = 1.0e-6
    @test energy_slack(out, EnergyMaxAvailSlack) ≈ 20.0 atol = 1.0e-6
    @test energy_slack(out, EnergyUIGFSlack) ≈ 15.0 atol = 1.0e-6
    @test only(filter(:family => ==("energy_max_avail"), out.violations).MW) ≈ 20.0 atol = 1.0e-6
    @test only(filter(:family => ==("energy_uigf"), out.violations).MW) ≈ 15.0 atol = 1.0e-6
    @test !any(==("generic_constraint"), out.violations.family)
    @test out.objective ≈ 19213775.0 atol = 1.0e-4
end

@testset "fixed loading beats MaxAvail but does not beat UIGF" begin
    out = energy_limit_solve(energy_limit_system(; max_avail = 40.0, target = nothing, fixed_load = 60.0))
    @test out.power ≈ 45.0 atol = 1.0e-6
    @test energy_slack(out, EnergyMaxAvailSlack) ≈ 5.0 atol = 1.0e-6
    @test energy_slack(out, EnergyUIGFSlack) ≈ 0.0 atol = 1.0e-6
    fixed = only(filter(:family => ==("fixed_load"), out.violations))
    @test fixed.MW ≈ 15.0 atol = 1.0e-6
    @test fixed.direction == "down"
end

@testset "an uninvoked fixed loading never binds" begin
    out = energy_limit_solve(energy_limit_system(; max_avail = 40.0, target = nothing, fixed_load = 60.0, fixed_invoked = 0.0))
    @test out.power ≈ 40.0 atol = 1.0e-6
    @test !any(==("fixed_load"), out.violations.family)
end

@testset "ramping beats the combined availability and UIGF penalties" begin
    out = energy_limit_solve(energy_limit_system(; max_avail = 40.0, target = nothing, initial = 65.0, down = 1.0))
    @test out.power ≈ 60.0 atol = 1.0e-6
    @test energy_slack(out, EnergyMaxAvailSlack) ≈ 20.0 atol = 1.0e-6
    @test energy_slack(out, EnergyUIGFSlack) ≈ 15.0 atol = 1.0e-6
    @test !any(==("unit_ramp"), out.violations.family)
end

@testset "ordinary and zero forecasts stay binding with negative bids" begin
    for forecast in (30.0, 0.0)
        out = energy_limit_solve(energy_limit_system(; max_avail = 40.0, uigf = forecast, target = nothing, price = -1000.0))
        @test out.power ≈ forecast atol = 1.0e-6
        @test energy_slack(out, EnergyMaxAvailSlack) ≈ 0.0 atol = 1.0e-6
        @test energy_slack(out, EnergyUIGFSlack) ≈ 0.0 atol = 1.0e-6
    end
    scheduled = energy_limit_solve(energy_limit_system(; max_avail = 40.0, uigf = nothing, target = nothing))
    @test scheduled.power ≈ 40.0 atol = 1.0e-6
end

@testset "recurrent energy limits update step by step" begin
    sys = energy_limit_system(; max_avail = [100.0, 35.0], uigf = [45.0, 25.0], target = [60.0, 20.0])
    out = run_replication(sys, TOY_START:TOY_RESOLUTION:(TOY_START + TOY_RESOLUTION); optimizer = optimizer_with_attributes(HiGHS.Optimizer, "output_flag" => false))
    dispatch = ReplayResults._solved_tables(out.results, sys, ()).dispatch
    sort!(dispatch, :SETTLEMENTDATE)
    power = filter(:DUID => ==(TOY_CHEAP), dispatch).TOTALCLEARED
    @test power ≈ [60.0, 20.0] atol = 1.0e-6
    violations = ReplayResults._constraint_violations(out.results, sys)
    forecast = filter(:family => ==("energy_uigf"), violations)
    @test nrow(forecast) == 1
    @test only(forecast.MW) ≈ 15.0 atol = 1.0e-6
    @test only(forecast.DateTime) == TOY_START
end

@testset "missing and non-finite forecasts are rejected before solving" begin
    sys = energy_limit_system()
    cheap = PSY.get_component(PSY.ThermalStandard, sys, TOY_CHEAP)
    PSY.remove_time_series!(sys, PSY.DeterministicSingleTimeSeries, cheap, "uigf")
    PSY.remove_time_series!(sys, PSY.SingleTimeSeries, cheap, "uigf")
    @test_throws ArgumentError replication_template(sys)
    invalid = energy_limit_system(; uigf = [45.0, NaN])
    template = replication_template(invalid)
    @test isnothing(check_dispatch_envelope(invalid, template, TOY_START, 1))
    @test_throws ArgumentError check_dispatch_envelope(invalid, template, TOY_START, 2)
end

@testset "a simulation across 1 July is refused, and each side of the boundary prices at its own Market Price Cap" begin
    start = DateTime(2025, 7, 1)
    steps = start:TOY_RESOLUTION:(start + TOY_RESOLUTION)
    optimizer = optimizer_with_attributes(HiGHS.Optimizer, "output_flag" => false)
    sys = energy_limit_system(; max_avail = 40.0, start)
    @test_throws ArgumentError run_replication(sys, steps; optimizer)
    # The max-availability slack of TOY_CHEAP: 370 CVP x Market Price Cap x 100 MW base x 5 minutes.
    for (t, expected) in ((steps[1], 370.0 * 17_500.0 * 100.0 / 12), (steps[2], 370.0 * 20_300.0 * 100.0 / 12))
        model = AEMS._replication_decision_model(replication_template(sys; initial_time = t), sys, t; optimizer)
        @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
        container = PSI.get_optimization_container(model)
        objective = PSI.JuMP.objective_function(PSI.get_jump_model(container))
        slack = PSI.get_variable(container, AEMS.EnergyMaxAvailSlack(), PSY.ThermalStandard)
        @test PSI.JuMP.coefficient(objective, slack[TOY_CHEAP, 1]) ≈ expected
    end
end

@testset "a range entirely after 1 July replays as standalone single-interval builds" begin
    start = DateTime(2025, 7, 1, 0, 5)
    steps = start:TOY_RESOLUTION:(start + TOY_RESOLUTION)
    optimizer = optimizer_with_attributes(HiGHS.Optimizer, "output_flag" => false)
    sys = energy_limit_system(; max_avail = 40.0, start)
    out = run_replication(sys, steps; optimizer)
    objectives = PSI.read_optimizer_stats(out.results).objective_value
    for (i, t) in enumerate(steps)
        model = AEMS._replication_decision_model(replication_template(sys; initial_time = t), sys, t; optimizer)
        @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
        @test PSI.solve!(model) == PSI.RunStatus.SUCCESSFULLY_FINALIZED
        @test objectives[i] ≈ only(PSI.read_optimizer_stats(PSI.OptimizationProblemResults(model)).objective_value) rtol = 1.0e-9
    end
end
