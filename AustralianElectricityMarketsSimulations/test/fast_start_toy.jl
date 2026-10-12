function toy_fast_start_context(mode, lower; upper = nothing, ramp_initial = lower, ramp_minutes = nothing)
    profile = AEMS.FastStartProfile(20.0, 2.0, 2.0, 2.0, 2.0)
    input = AEMS.FastStartInput(profile, AEMS.FastStartState(mode, 0.0), ramp_initial, 100.0, 100.0, 100.0, 0.0)
    envelope = (; profile_lower_mw = lower, profile_upper_mw = upper, ramp_initial_mw = ramp_initial, ramp_minutes)
    return (; pass = :dispatch, inputs = Dict(TOY_CHEAP => input), envelopes = Dict(TOY_CHEAP => envelope))
end

function toy_planned_fast_start_context(input, envelope)
    return (; pass = :dispatch, inputs = Dict(TOY_CHEAP => input), envelopes = Dict(TOY_CHEAP => envelope))
end

function toy_slack_mw(out, name)
    values = read_variable(out.results, "$(name)__ThermalStandard")
    return isempty(values) ? 0.0 : sum(values.value)
end

@testset "fast-start energy profile and thermal elasticity" begin
    @testset "profile ramp envelopes preserve exact endpoints and startup anchors" begin
        mode2_input = AEMS.FastStartInput(
            AEMS.FastStartProfile(20.0, 0.0, 2.0, 10.0, 10.0),
            AEMS.FastStartState(2, 2.0), 20.0, 100.0, 100.0, 100.0, 0.0,
        )
        mode3_envelope = AEMS.plan_fast_start(mode2_input, 20.0)
        @test mode2_input.state.mode == 2
        @test mode3_envelope.state.mode == 3

        profile = AEMS.FastStartProfile(20.0, 1.0, 4.0, 2.0, 2.0)
        at_t2 = AEMS.FastStartInput(profile, AEMS.FastStartState(1, 0.0), 8.0, 60.0, 60.0, 100.0, 0.0)
        exact = AEMS.plan_fast_start(at_t2, 20.0)
        @test exact.state == AEMS.FastStartState(2, 4.0)
        @test exact.ramp_minutes === nothing

        next = AEMS.FastStartInput(profile, exact.state, 8.0, 60.0, 60.0, 100.0, 0.0)
        crossed = AEMS.plan_fast_start(next, 20.0)
        @test crossed.state == AEMS.FastStartState(4, 3.0)
        @test crossed.ramp_initial_mw == 20.0
        @test crossed.ramp_minutes == 5.0

        partial_profile = AEMS.FastStartProfile(20.0, 10.0, 2.0, 2.0, 2.0)
        partial_input = AEMS.FastStartInput(
            partial_profile, AEMS.FastStartState(1, 10.0), 17.0, 780.0, 780.0, 100.0, 0.0,
        )
        partial_envelope = AEMS.plan_fast_start(partial_input, 0.0)
        @test partial_envelope.state == AEMS.FastStartState(4, 1.0)
        @test partial_envelope.ramp_initial_mw == 20.0
        @test partial_envelope.ramp_minutes == 3.0

        partial = solve_toy(
            nem_toy_system(
                [
                    TOY_CHEAP => toy_unit(100.0, [(100.0, 10.0)]; initial = 17.0, ramp_up = 13.0),
                    TOY_EXPENSIVE => toy_unit(100.0, [(100.0, 50.0)]; initial = 0.0, ramp_up = 100.0),
                ], 80.0,
            );
            fast_start_context = toy_planned_fast_start_context(partial_input, partial_envelope),
            use_slacks = false,
        )
        @test partial.dispatch_mw[TOY_CHEAP] ≈ 59.0 atol = TOY_TOLERANCE
        @test partial.dispatch_mw[TOY_EXPENSIVE] ≈ 21.0 atol = TOY_TOLERANCE
        @test toy_slack_mw(partial, "UnitRampUpSlack") ≈ 0.0 atol = TOY_TOLERANCE
    end

    @testset "commitment pass omits starting-profile energy ramps" begin
        input = AEMS.FastStartInput(
            AEMS.FastStartProfile(20.0, 1.0, 2.0, 2.0, 2.0),
            AEMS.FastStartState(2, 0.0), 0.0, 0.0, 100.0, 100.0, 0.0,
        )
        context = (; pass = :commitment, inputs = Dict(TOY_CHEAP => input), envelopes = Dict())
        out = solve_toy(
            nem_toy_system([TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = 0.0, ramp_up = 0.0)], 20.0);
            fast_start_context = context,
            use_slacks = false,
        )
        @test out.dispatch_mw[TOY_CHEAP] ≈ 20.0 atol = TOY_TOLERANCE
        @test toy_slack_mw(out, "UnitRampUpSlack") ≈ 0.0 atol = TOY_TOLERANCE
    end

    @testset "profile rows discriminate fixed targets and minimum-output modes" begin
        fixed = solve_toy(
            nem_toy_system(
                [
                    TOY_CHEAP => toy_unit(100.0, [(100.0, 10.0)]; initial = 0.0, ramp_up = 100.0),
                    TOY_EXPENSIVE => toy_unit(100.0, [(100.0, 20.0)]; initial = 0.0, ramp_up = 100.0),
                ], 30.0,
            );
            fast_start_context = toy_fast_start_context(2, 20.0; upper = 20.0),
        )
        @test fixed.dispatch_mw[TOY_CHEAP] ≈ 20.0 atol = TOY_TOLERANCE
        @test fixed.dispatch_mw[TOY_EXPENSIVE] ≈ 10.0 atol = TOY_TOLERANCE
        @test toy_slack_mw(fixed, "FastStartProfileDeficitSlack") ≈ 0.0 atol = TOY_TOLERANCE
        @test toy_slack_mw(fixed, "FastStartProfileSurplusSlack") ≈ 0.0 atol = TOY_TOLERANCE
        @test fixed.objective ≈ (20.0 * 10.0 + 10.0 * 20.0) * DISPATCH_INTERVAL_HOURS atol = TOY_TOLERANCE

        minimum = solve_toy(
            nem_toy_system([TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = 40.0, ramp_up = 100.0)], 40.0);
            fast_start_context = toy_fast_start_context(3, 20.0),
        )
        @test minimum.dispatch_mw[TOY_CHEAP] ≈ 40.0 atol = TOY_TOLERANCE

        declining = solve_toy(
            nem_toy_system(
                [
                    TOY_CHEAP => toy_unit(100.0, [(100.0, 30.0)]; initial = 0.0, ramp_up = 100.0),
                    TOY_EXPENSIVE => toy_unit(100.0, [(100.0, 20.0)]; initial = 0.0, ramp_up = 100.0),
                ], 20.0,
            );
            fast_start_context = toy_fast_start_context(4, 10.0),
        )
        @test declining.dispatch_mw[TOY_CHEAP] ≈ 10.0 atol = TOY_TOLERANCE
        @test declining.dispatch_mw[TOY_EXPENSIVE] ≈ 10.0 atol = TOY_TOLERANCE
        @test toy_slack_mw(declining, "FastStartProfileDeficitSlack") ≈ 0.0 atol = TOY_TOLERANCE
        @test declining.objective ≈ (10.0 * 30.0 + 10.0 * 20.0) * DISPATCH_INTERVAL_HOURS atol = TOY_TOLERANCE

        ordinary = solve_toy(
            nem_toy_system([TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = 20.0, ramp_up = 100.0)], 20.0),
        )
        @test ordinary.dispatch_mw[TOY_CHEAP] ≈ 20.0 atol = TOY_TOLERANCE
    end

    @testset "raw MaxAvail is elastic and offer excess preserves submitted bands" begin
        availability = solve_toy(
            nem_toy_system([TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = 20.0, ramp_up = 100.0, availability = 10.0)], 20.0);
            use_slacks = false,
        )
        @test availability.dispatch_mw[TOY_CHEAP] ≈ 20.0 atol = TOY_TOLERANCE
        @test toy_slack_mw(availability, "AvailabilitySurplusSlack") ≈ 10.0 atol = TOY_TOLERANCE
        @test availability.band_mw[(TOY_CHEAP, 1)] ≈ 20.0 atol = TOY_TOLERANCE
        @test toy_slack_mw(availability, "OfferSurplusSlack") ≈ 0.0 atol = TOY_TOLERANCE
        active = PSI.get_variable(availability.container, PSI.ActivePowerVariable(), PSY.ThermalStandard)[TOY_CHEAP, 1]
        @test !PSI.JuMP.has_upper_bound(active)
        @test !any(
            AEMS.IS.Optimization.get_entry_type(key) === PSI.ActivePowerVariableTimeSeriesLimitsConstraint
                for key in keys(PSI.get_constraints(availability.container))
        )
        offer_row = PSI.get_constraint(
            availability.container,
            PSI.PiecewiseLinearBlockIncrementalOfferConstraint(),
            PSY.ThermalStandard,
        )[TOY_CHEAP, 1]
        @test PSI.JuMP.normalized_coefficient(
            offer_row, PSI.get_variable(
                availability.container, AEMS.OfferSurplusSlack(), PSY.ThermalStandard,
            )[TOY_CHEAP, 1]
        ) == -1.0

        profile_availability = solve_toy(
            nem_toy_system(
                [
                    TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = 20.0, ramp_up = 100.0, availability = 10.0),
                    TOY_EXPENSIVE => toy_unit(100.0, [(100.0, 30.0)]; initial = 0.0, ramp_up = 100.0),
                ], 20.0,
            );
            fast_start_context = toy_fast_start_context(2, 20.0; upper = 20.0),
            use_slacks = false,
        )
        @test profile_availability.dispatch_mw[TOY_CHEAP] ≈ 20.0 atol = TOY_TOLERANCE
        @test profile_availability.dispatch_mw[TOY_EXPENSIVE] ≈ 0.0 atol = TOY_TOLERANCE
        @test toy_slack_mw(profile_availability, "AvailabilitySurplusSlack") ≈ 10.0 atol = TOY_TOLERANCE
        @test toy_slack_mw(profile_availability, "FastStartProfileDeficitSlack") ≈ 0.0 atol = TOY_TOLERANCE
        @test toy_slack_mw(profile_availability, "FastStartProfileSurplusSlack") ≈ 0.0 atol = TOY_TOLERANCE
        mpc = last(first(AEMS.MARKET_PRICE_CAP_BY_FINANCIAL_YEAR))
        @test profile_availability.objective ≈ (20.0 * 20.0 + 10.0 * 370.0 * mpc) * DISPATCH_INTERVAL_HOURS rtol = 1.0e-8

        offer = solve_toy(
            nem_toy_system([TOY_CHEAP => toy_unit(100.0, [(10.0, 20.0)]; initial = 20.0, ramp_up = 100.0)], 20.0);
            use_slacks = false,
        )
        @test offer.dispatch_mw[TOY_CHEAP] ≈ 20.0 atol = TOY_TOLERANCE
        @test offer.band_mw[(TOY_CHEAP, 1)] ≈ 10.0 atol = TOY_TOLERANCE
        @test toy_slack_mw(offer, "OfferSurplusSlack") ≈ 10.0 atol = TOY_TOLERANCE

        offered_profile = solve_toy(
            nem_toy_system(
                [
                    TOY_CHEAP => toy_unit(100.0, [(10.0, 20.0)]; initial = 0.0, ramp_up = 100.0),
                    TOY_EXPENSIVE => toy_unit(100.0, [(100.0, 30.0)]; initial = 0.0, ramp_up = 100.0),
                ], 20.0,
            );
            fast_start_context = toy_fast_start_context(2, 20.0; upper = 20.0),
            use_slacks = false,
        )
        @test offered_profile.dispatch_mw[TOY_CHEAP] ≈ 10.0 atol = TOY_TOLERANCE
        @test offered_profile.dispatch_mw[TOY_EXPENSIVE] ≈ 10.0 atol = TOY_TOLERANCE
        @test toy_slack_mw(offered_profile, "OfferSurplusSlack") ≈ 0.0 atol = TOY_TOLERANCE
        @test toy_slack_mw(offered_profile, "FastStartProfileDeficitSlack") ≈ 10.0 atol = TOY_TOLERANCE
        @test toy_slack_mw(offered_profile, "FastStartProfileSurplusSlack") ≈ 0.0 atol = TOY_TOLERANCE
        mpc = last(first(AEMS.MARKET_PRICE_CAP_BY_FINANCIAL_YEAR))
        @test offered_profile.objective ≈ (10.0 * 20.0 + 10.0 * 30.0 + 10.0 * 1130.0 * mpc) * DISPATCH_INTERVAL_HOURS rtol = 1.0e-8
    end

    @testset "profile deficit is preferred to the higher-cost ramp violation" begin
        out = solve_toy(
            nem_toy_system(
                [
                    TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = 0.0, ramp_up = 0.0),
                    TOY_EXPENSIVE => toy_unit(100.0, [(100.0, 5_000.0)]; initial = 10.0, ramp_up = 100.0),
                ], 10.0,
            );
            fast_start_context = toy_fast_start_context(3, 20.0; ramp_initial = 0.0, ramp_minutes = 5.0),
            use_slacks = false,
        )
        @test out.dispatch_mw[TOY_CHEAP] ≈ 0.0 atol = TOY_TOLERANCE
        @test out.dispatch_mw[TOY_EXPENSIVE] ≈ 10.0 atol = TOY_TOLERANCE
        @test toy_slack_mw(out, "FastStartProfileDeficitSlack") ≈ 20.0 atol = TOY_TOLERANCE
        @test toy_slack_mw(out, "UnitRampUpSlack") ≈ 0.0 atol = TOY_TOLERANCE
        mpc = last(first(AEMS.MARKET_PRICE_CAP_BY_FINANCIAL_YEAR))
        @test out.objective ≈ (10.0 * 5_000.0 + 20.0 * 1130.0 * mpc) * DISPATCH_INTERVAL_HOURS rtol = 1.0e-8
    end

    @testset "one MW of availability violation costs factor times MPC per interval" begin
        fy_mpc = last(first(AEMS.MARKET_PRICE_CAP_BY_FINANCIAL_YEAR))
        for base in (100.0, 50.0)
            sys = nem_toy_system(
                [TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = 20.0, ramp_up = 100.0, availability = 19.0)],
                20.0;
                base_power = base,
            )
            out = solve_toy(sys; use_slacks = false)
            @test toy_slack_mw(out, "AvailabilitySurplusSlack") ≈ 1.0 atol = TOY_TOLERANCE
            @test out.objective ≈ (20.0 * 20.0 + 370.0 * fy_mpc) * DISPATCH_INTERVAL_HOURS rtol = 1.0e-8
        end
    end

    @testset "combined violations add their weighted penalties" begin
        sys = nem_toy_system(
            [TOY_CHEAP => toy_unit(100.0, [(10.0, 20.0)]; initial = 0.0, ramp_up = 0.0, availability = 15.0)],
            20.0,
        )
        context = toy_fast_start_context(3, 20.0; ramp_initial = 0.0, ramp_minutes = 5.0)
        out = solve_toy(sys; fast_start_context = context, use_slacks = false)
        mpc = last(first(AEMS.MARKET_PRICE_CAP_BY_FINANCIAL_YEAR))
        @test out.dispatch_mw[TOY_CHEAP] ≈ 20.0 atol = TOY_TOLERANCE
        @test toy_slack_mw(out, "UnitRampUpSlack") ≈ 20.0 atol = TOY_TOLERANCE
        @test toy_slack_mw(out, "AvailabilitySurplusSlack") ≈ 5.0 atol = TOY_TOLERANCE
        @test toy_slack_mw(out, "OfferSurplusSlack") ≈ 10.0 atol = TOY_TOLERANCE
        @test out.objective ≈ (10.0 * 20.0 + (20.0 * 1155.0 + 5.0 * 370.0 + 10.0 * 1135.0) * mpc) * DISPATCH_INTERVAL_HOURS rtol = 1.0e-8
    end

    @testset "the weighted profile penalty can beat combined unit violations" begin
        sys = nem_toy_system(
            [
                TOY_CHEAP => toy_unit(100.0, [(10.0, 20.0)]; initial = 0.0, ramp_up = 0.0, availability = 15.0),
                TOY_EXPENSIVE => toy_unit(100.0, [(100.0, 10_000_000.0)]; initial = 20.0, ramp_up = 100.0),
            ],
            20.0,
        )
        context = toy_fast_start_context(3, 20.0; ramp_initial = 0.0, ramp_minutes = 5.0)
        out = solve_toy(sys; fast_start_context = context, use_slacks = false)
        mpc = last(first(AEMS.MARKET_PRICE_CAP_BY_FINANCIAL_YEAR))
        @test out.dispatch_mw[TOY_CHEAP] ≈ 10.0 atol = TOY_TOLERANCE
        @test out.dispatch_mw[TOY_EXPENSIVE] ≈ 10.0 atol = TOY_TOLERANCE
        @test toy_slack_mw(out, "FastStartProfileDeficitSlack") ≈ 10.0 atol = TOY_TOLERANCE
        @test toy_slack_mw(out, "UnitRampUpSlack") ≈ 10.0 atol = TOY_TOLERANCE
        @test toy_slack_mw(out, "AvailabilitySurplusSlack") ≈ 0.0 atol = TOY_TOLERANCE
        @test toy_slack_mw(out, "OfferSurplusSlack") ≈ 0.0 atol = TOY_TOLERANCE
        @test out.objective ≈ (10.0 * (10_000_000.0 + 20.0) + 10.0 * (1130.0 + 1155.0) * mpc) * DISPATCH_INTERVAL_HOURS atol = 20.0 rtol = 1.0e-8
    end
end
