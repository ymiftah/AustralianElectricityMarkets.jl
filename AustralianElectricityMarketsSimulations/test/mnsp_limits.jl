function _mnsp_limit_case(; forward = (10.0, [(5.0, 10.0)]), reverse = (100.0, [(100.0, 10.0)]), operating...)
    sys = _loss_test_system(; loss_constant = 1.0, breakpoints = [-1000.0, 1000.0], priced_supply_only = true)
    PSY.set_available!(PSY.get_component(PSY.ThermalStandard, sys, "Solitude"), true)
    _attach_mnsp_offers!(sys; forward, reverse)
    _mnsp_operating_series!(sys; operating...)
    return sys
end

function _solve_mnsp_limit_case(sys; target = nothing)
    model = _decision_model(_loss_template(sys), sys; optimizer = HiGHS.Optimizer, horizon = Hour(2))
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
    violations = filter(row -> startswith(row.family, "mnsp_"), read_constraint_violations(results, sys))
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

@testset "each step's MNSP operating inputs are recomputed from the step's state (custom update path)" begin
    previous = AEMS._FORCE_CUSTOM_STATE_UPDATES[]
    AEMS._FORCE_CUSTOM_STATE_UPDATES[] = true
    try
        # The build sets a +30 MW metered flow with forward 600 and reverse 1200 MW/min. Before step 2 the
        # flow flips to -40 MW and the forward and reverse envelope rates swap. The build's parameter array
        # holds the build values at both steps, so reading the step-2 values back is the discriminator.
        sys = _mnsp_limit_case(;
            forward = (100.0, [(100.0, 10.0)]), reverse = (100.0, [(100.0, 10.0)]),
            initial = 30.0, up = 600.0, down = 1200.0,
        )
        model = _decision_model(_loss_template(sys), sys; optimizer = HiGHS.Optimizer, horizon = Hour(2))
        @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
        container = PSI.get_optimization_container(model)
        initial = PSI.get_parameter(container, PSI.ParameterKey(AEMS.MNSPInitialFlowParameter, PSY.AreaInterchange))
        forward = PSI.get_parameter(container, PSI.ParameterKey(AEMS.MNSPForwardRampRateParameter, PSY.AreaInterchange))
        reverse = PSI.get_parameter(container, PSI.ParameterKey(AEMS.MNSPReverseRampRateParameter, PSY.AreaInterchange))
        @test collect(PSI.get_parameter_column_values(initial, "IC1")) == [30.0, 30.0]
        @test collect(PSI.get_parameter_column_values(forward, "IC1")) == [600.0, 600.0]
        @test collect(PSI.get_parameter_column_values(reverse, "IC1")) == [1200.0, 1200.0]

        # The step-2 state, as new keyed series the build never read: step 1 keeps the build's values.
        system = PSI.get_system(model)
        ic = PSY.get_component(PSY.AreaInterchange, system, "IC1")
        stamps = PSY.get_time_series_timestamps(
            PSY.SingleTimeSeries, ic, AustralianElectricityMarkets.NEM_MNSP_SERIES.initial_flow,
        )
        later(name, build, step2) = begin
            values = [i == 2 ? step2 : build for i in eachindex(stamps)]
            PSY.add_time_series!(system, ic, PSY.SingleTimeSeries(; name, data = TimeArray(stamps, values)))
            return only(k for k in PSY.IS.get_time_series_keys(ic) if k.name == name)
        end
        flow_key = later("later_initial_flow", 30.0, -40.0)
        forward_key = later("later_forward_ramp_rate", 600.0, 1200.0)
        reverse_key = later("later_reverse_ramp_rate", 1200.0, 600.0)

        observed = only(PSY.get_supplemental_attributes(AustralianElectricityMarkets.NEMMNSPObservedState, ic))
        PSY.remove_supplemental_attribute!(system, ic, observed)
        PSY.add_supplemental_attribute!(
            system, ic, AustralianElectricityMarkets.NEMMNSPObservedState(; initial_flow = flow_key),
        )
        for (direction, key) in (
                (AustralianElectricityMarkets.MNSPDirection.FORWARD, forward_key),
                (AustralianElectricityMarkets.MNSPDirection.REVERSE, reverse_key),
            )
            bid = only(b for b in PSY.get_supplemental_attributes(AustralianElectricityMarkets.NEMMNSPBid, ic) if b.direction == direction)
            PSY.remove_supplemental_attribute!(system, ic, bid)
            PSY.add_supplemental_attribute!(
                system, ic,
                AustralianElectricityMarkets.NEMMNSPBid(;
                    direction, offer_curves = bid.offer_curves, max_avail = bid.max_avail,
                    ramp_up = key, fixed_load = bid.fixed_load,
                ),
            )
        end

        PSI.set_execution_count!(model, 1)
        _update_step_parameters!(model)
        PSI.solve_impl!(model)
        @test PSI.get_run_status(model) == PSI.RunStatus.SUCCESSFULLY_FINALIZED
        # The container is a rolling window: its first column is the step being solved, so the step-2
        # values are there and the build's values are displaced to the later columns.
        @test first(collect(PSI.get_parameter_column_values(initial, "IC1"))) == -40.0
        @test first(collect(PSI.get_parameter_column_values(forward, "IC1"))) == 1200.0
        @test first(collect(PSI.get_parameter_column_values(reverse, "IC1"))) == 600.0
    finally
        AEMS._FORCE_CUSTOM_STATE_UPDATES[] = previous
    end
end

@testset "a missing derived MNSP fixed loading is named before the parameters are added" begin
    sys = _mnsp_limit_case(; forward = (100.0, [(100.0, 10.0)]), fixed_forward = 30.0)
    ic = PSY.get_component(PSY.AreaInterchange, sys, "IC1")
    name = AEMS.NEM_MNSP_FIXED_LOAD_SERIES.forward_value
    # A transformed system holds the derived series both as a single series and as its deterministic copy.
    PSY.has_time_series(ic, PSY.DeterministicSingleTimeSeries, name) &&
        PSY.remove_time_series!(sys, PSY.DeterministicSingleTimeSeries, ic, name)
    PSY.remove_time_series!(sys, PSY.SingleTimeSeries, ic, name)
    status, log = _toy_build_log(_decision_model(_loss_template(sys), sys; optimizer = HiGHS.Optimizer, horizon = Hour(2)))
    @test status == PSI.ModelBuildStatus.FAILED
    @test occursin("has no derived MNSP fixed loading", log)
    @test occursin(name, log)
end
