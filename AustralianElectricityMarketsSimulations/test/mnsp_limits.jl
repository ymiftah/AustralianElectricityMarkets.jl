function _mnsp_limit_case(; forward = (10.0, [(5.0, 10.0)]), reverse = (100.0, [(100.0, 10.0)]), operating...)
    sys = _loss_test_system(; loss_constant = 1.0, breakpoints = [-1000.0, 1000.0], priced_supply_only = true)
    PSY.set_available!(PSY.get_component(PSY.ThermalStandard, sys, "Solitude"), true)
    _attach_mnsp_offers!(sys; forward, reverse)
    _mnsp_operating_series!(sys; operating...)
    return sys
end

function _solve_mnsp_limit_case(sys; target = nothing)
    model = _decision_model(_loss_template(), sys; optimizer = HiGHS.Optimizer, horizon = Hour(2))
    @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
    container = PSI.get_optimization_container(model)
    if !isnothing(target)
        flow = PSI.get_variable(container, PSI.FlowActivePowerVariable(), PSY.AreaInterchange)
        for t in PSI.get_time_steps(container)
            PSI.JuMP.@constraint(PSI.get_jump_model(container), flow["IC1", t] == target / PSY.get_base_power(sys))
        end
    end
    status = PSI.solve!(model)
    @test status == PSI.RunStatus.SUCCESSFULLY_FINALIZED
    status == PSI.RunStatus.SUCCESSFULLY_FINALIZED || return nothing
    results = PSI.OptimizationProblemResults(model)
    violations = filter(row -> startswith(row.family, "mnsp_"), AEMS._constraint_violations(results, sys))
    return (; model, results, violations)
end

function _mnsp_limit_value(out, V; direction = nothing)
    frame = PSI.read_variable(out.results, PSI.VariableKey(V, PSY.AreaInterchange, something(direction, "")))
    return first(frame.value)
end

@testset "MNSP commercial limits can be violated independently of direction bounds" begin
    for (avail, width) in ((10.0, 5.0), (0.0, 0.0))
        out = _solve_mnsp_limit_case(_mnsp_limit_case(; forward = (avail, [(width, 10.0)])); target = 20.0)
        if !isnothing(out)
            @test _mnsp_limit_value(out, AEMS.MNSPMaxAvailSlack; direction = "forward") ≈ 20.0 - avail atol = 1.0e-6
            @test _mnsp_limit_value(out, AEMS.MNSPOfferSlack; direction = "forward") ≈ 20.0 - width atol = 1.0e-6
            @test Set(out.violations.family) == Set(["mnsp_max_avail", "mnsp_offer"])
            @test all(==("forward"), out.violations.direction)
        end
    end
end

@testset "MNSP reverse commercial-limit violations retain their link direction" begin
    sys = _mnsp_limit_case(; forward = (100.0, [(100.0, 10.0)]), reverse = (0.0, [(0.0, 10.0)]))
    out = _solve_mnsp_limit_case(sys; target = -20.0)
    if !isnothing(out)
        @test _mnsp_limit_value(out, AEMS.MNSPMaxAvailSlack; direction = "reverse") ≈ 20.0 atol = 1.0e-6
        @test all(==("reverse"), out.violations.direction)
    end
end

@testset "MNSP ramp rows measure signed net flow from metered flow" begin
    for target in (20.0, -20.0)
        sys = _mnsp_limit_case(; forward = (100.0, [(100.0, 10.0)]), initial = 0.0, up = 1.0, down = 2.0)
        out = _solve_mnsp_limit_case(sys; target)
        if !isnothing(out)
            # This fixture's resolution is one hour: 1 and 2 MW/min permit 60 and 120 MW.
            @test isempty(out.violations)
        end
    end
    out = _solve_mnsp_limit_case(_mnsp_limit_case(; forward = (100.0, [(100.0, 10.0)]), initial = -50.0, up = 1.0); target = 20.0)
    if !isnothing(out)
        @test _mnsp_limit_value(out, AEMS.MNSPRampUpSlack) ≈ 10.0 atol = 1.0e-6
        @test only(unique(out.violations.family)) == "mnsp_ramp"
    end
end

@testset "MNSP fixed loading is an elastic directional instruction" begin
    out = _solve_mnsp_limit_case(_mnsp_limit_case(; forward = (100.0, [(100.0, 10.0)]), fixed_forward = 30.0); target = 20.0)
    if !isnothing(out)
        @test _mnsp_limit_value(out, AEMS.MNSPFixedLoadDeficitSlack; direction = "forward") ≈ 10.0 atol = 1.0e-6
        @test only(unique(out.violations.family)) == "mnsp_fixed_load"
    end
end

@testset "MNSP down-ramp and reverse fixed-loading violations" begin
    out = _solve_mnsp_limit_case(_mnsp_limit_case(; initial = 50.0, down = 1.0); target = -20.0)
    if !isnothing(out)
        @test _mnsp_limit_value(out, AEMS.MNSPRampDownSlack) ≈ 10.0 atol = 1.0e-6
        @test only(unique(out.violations.direction)) == "down"
    end
    out = _solve_mnsp_limit_case(_mnsp_limit_case(; fixed_reverse = 10.0); target = -20.0)
    if !isnothing(out)
        @test _mnsp_limit_value(out, AEMS.MNSPFixedLoadSurplusSlack; direction = "reverse") ≈ 10.0 atol = 1.0e-6
        @test only(unique(out.violations.direction)) == "reverse_up"
    end
end

@testset "Zero fixed loading differs from an absent instruction" begin
    for (fixed, expected) in ((nothing, 0.0), (0.0, 20.0))
        out = _solve_mnsp_limit_case(_mnsp_limit_case(; forward = (100.0, [(100.0, 10.0)]), fixed_forward = fixed); target = 20.0)
        if !isnothing(out)
            @test _mnsp_limit_value(out, AEMS.MNSPFixedLoadSurplusSlack; direction = "forward") ≈ expected atol = 1.0e-6
        end
    end
end

@testset "Fixed loading overrides commercial availability by CVP priority" begin
    out = _solve_mnsp_limit_case(_mnsp_limit_case(; forward = (0.0, [(100.0, 10.0)]), fixed_forward = 30.0))
    if !isnothing(out)
        @test _mnsp_limit_value(out, AEMS.MNSPMaxAvailSlack; direction = "forward") ≈ 30.0 atol = 1.0e-6
        @test _mnsp_limit_value(out, AEMS.MNSPFixedLoadDeficitSlack; direction = "forward") ≈ 0.0 atol = 1.0e-6
    end
end
