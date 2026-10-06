@testset "merit order: the cheaper unit is filled first" begin
    sys = nem_toy_system(
        [
            TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = 60.0, ramp_up = 100.0),
            TOY_EXPENSIVE => toy_unit(100.0, [(100.0, 80.0)]; initial = 60.0, ramp_up = 100.0),
        ],
        120.0,
    )
    out = solve_toy(sys)

    @test out.dispatch_mw[TOY_CHEAP] ≈ 100.0 atol = TOY_TOLERANCE
    @test out.dispatch_mw[TOY_EXPENSIVE] ≈ 20.0 atol = TOY_TOLERANCE
    @test out.price ≈ 80.0 atol = TOY_TOLERANCE
    @test out.objective ≈ (100.0 * 20.0 + 20.0 * 80.0) * DISPATCH_INTERVAL_HOURS atol = TOY_TOLERANCE
end

@testset "multi-band stack: bands load in price order, the marginal one partially" begin
    sys = nem_toy_system(
        [
            TOY_CHEAP => toy_unit(
                100.0, [(20.0, 20.0), (30.0, 50.0), (50.0, 300.0)];
                initial = 60.0, ramp_up = 100.0,
            ),
            TOY_EXPENSIVE => toy_unit(100.0, [(100.0, 1000.0)]; initial = 60.0, ramp_up = 100.0),
        ],
        40.0,
    )
    out = solve_toy(sys)

    @test out.dispatch_mw[TOY_CHEAP] ≈ 40.0 atol = TOY_TOLERANCE
    @test out.dispatch_mw[TOY_EXPENSIVE] ≈ 0.0 atol = TOY_TOLERANCE
    @test out.band_mw[(TOY_CHEAP, 1)] ≈ 20.0 atol = TOY_TOLERANCE
    @test out.band_mw[(TOY_CHEAP, 2)] ≈ 20.0 atol = TOY_TOLERANCE
    @test out.band_mw[(TOY_CHEAP, 3)] ≈ 0.0 atol = TOY_TOLERANCE
    @test out.price ≈ 50.0 atol = TOY_TOLERANCE
    @test out.objective ≈ (20.0 * 20.0 + 20.0 * 50.0) * DISPATCH_INTERVAL_HOURS atol = TOY_TOLERANCE
end

@testset "a binding ramp overrides merit order" begin
    function ramp_toy(cheap_ramp_up)
        return nem_toy_system(
            [
                TOY_CHEAP => toy_unit(
                    100.0, [(100.0, 20.0)]; initial = 50.0, ramp_up = cheap_ramp_up,
                ),
                TOY_EXPENSIVE => toy_unit(100.0, [(100.0, 80.0)]; initial = 50.0, ramp_up = 20.0),
            ],
            90.0,
        )
    end
    tight = solve_toy(ramp_toy(1.0))
    relaxed = solve_toy(ramp_toy(20.0))

    @testset "held at INITIALMW + rate × 5 min, the expensive unit covers the rest" begin
        @test tight.dispatch_mw[TOY_CHEAP] ≈ 50.0 + 1.0 * 5 atol = TOY_TOLERANCE
        @test tight.dispatch_mw[TOY_EXPENSIVE] ≈ 35.0 atol = TOY_TOLERANCE
        @test tight.price ≈ 80.0 atol = TOY_TOLERANCE
    end

    @testset "an ordinary ramp row leaves its slack at zero" begin
        @test tight.ramp_slack_mw.up ≈ 0.0 atol = TOY_TOLERANCE
        @test tight.ramp_slack_mw.down ≈ 0.0 atol = TOY_TOLERANCE
    end

    @testset "with the ramp relaxed, merit order is restored" begin
        @test relaxed.dispatch_mw[TOY_CHEAP] ≈ 90.0 atol = TOY_TOLERANCE
        @test relaxed.dispatch_mw[TOY_EXPENSIVE] ≈ 0.0 atol = TOY_TOLERANCE
        @test relaxed.price ≈ 20.0 atol = TOY_TOLERANCE
    end
end

@testset "a battery discharges when the area price is above its generation offer" begin
    # The battery's 60 MW, $20/MWh offer clears first; Park City's $80/MWh offer covers the
    # remaining 40 MW of the 100 MW load and sets the price. The battery's load band ($1/MWh)
    # is never worth clearing against either offer, so it does not charge.
    sys = nem_toy_system(
        [TOY_EXPENSIVE => toy_unit(100.0, [(100.0, 80.0)]; initial = 60.0, ramp_up = 100.0)],
        100.0;
        batteries = [
            TOY_BATTERY => toy_battery(
                60.0, 20.0, 10.0, 1.0; initial = 0.0, ramp_up = 100.0,
            ),
        ],
    )
    out = solve_toy(sys)

    @test out.battery_out_mw[TOY_BATTERY] ≈ 60.0 atol = TOY_TOLERANCE
    @test out.battery_in_mw[TOY_BATTERY] ≈ 0.0 atol = TOY_TOLERANCE
    @test out.dispatch_mw[TOY_EXPENSIVE] ≈ 40.0 atol = TOY_TOLERANCE
    @test out.price ≈ 80.0 atol = TOY_TOLERANCE
    @test out.objective ≈ (60.0 * 20.0 + 40.0 * 80.0) * DISPATCH_INTERVAL_HOURS atol = TOY_TOLERANCE
end

@testset "a battery charges when its load bid is above the marginal generator's price" begin
    # Alta's $20/MWh offer covers the 40 MW load plus the battery's full 30 MW charge, since
    # the battery's $50/MWh load bid values that charge above Alta's cost. Charging lowers the
    # objective by (50 - 20) * 30 = 900 $ relative to the no-battery baseline of 40 * 20 = 800 $.
    sys = nem_toy_system(
        [TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = 60.0, ramp_up = 100.0)],
        40.0;
        batteries = [
            TOY_BATTERY => toy_battery(
                10.0, 1000.0, 30.0, 50.0; initial = 0.0, ramp_up = 100.0,
            ),
        ],
    )
    out = solve_toy(sys)

    @test out.battery_in_mw[TOY_BATTERY] ≈ 30.0 atol = TOY_TOLERANCE
    @test out.battery_out_mw[TOY_BATTERY] ≈ 0.0 atol = TOY_TOLERANCE
    @test out.dispatch_mw[TOY_CHEAP] ≈ 70.0 atol = TOY_TOLERANCE
    @test out.price ≈ 20.0 atol = TOY_TOLERANCE
    baseline_objective = 40.0 * 20.0 * DISPATCH_INTERVAL_HOURS
    @test out.objective ≈ baseline_objective - (50.0 - 20.0) * 30.0 * DISPATCH_INTERVAL_HOURS atol = TOY_TOLERANCE
    @test out.objective ≈ (70.0 * 20.0 - 30.0 * 50.0) * DISPATCH_INTERVAL_HOURS atol = TOY_TOLERANCE
end

@testset "a net ramp limit binding across zero" begin
    # INITIALMW = -10 (charging 10 MW net); ramp_up = 1 MW/min-convention over the 5-minute
    # interval allows a +5 MW move, so net cannot exceed -10 + 5 = -5 (still a net 5 MW
    # charge). The battery's own gen availability is zero, so Out = 0 and In is pinned to
    # exactly 5 by the ramp floor (In >= Out + 5) and the load availability ceiling (In <= 5)
    # at once. Alta supplies the 5 MW the battery's net charging still needs off a 0 MW load.
    sys = nem_toy_system(
        [TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = 60.0, ramp_up = 100.0)],
        0.0;
        batteries = [
            TOY_BATTERY => toy_battery(
                10.0, 20.0, 10.0, 30.0;
                initial = -10.0, ramp_up = 1.0, ramp_down = 100.0, gen_avail = 0.0, load_avail = 5.0,
            ),
        ],
    )
    out = solve_toy(sys)

    @test out.battery_out_mw[TOY_BATTERY] ≈ 0.0 atol = TOY_TOLERANCE
    @test out.battery_in_mw[TOY_BATTERY] ≈ 5.0 atol = TOY_TOLERANCE
    @test out.dispatch_mw[TOY_CHEAP] ≈ 5.0 atol = TOY_TOLERANCE
    @test out.price ≈ 20.0 atol = TOY_TOLERANCE
    @test out.objective ≈ (5.0 * 20.0 - 5.0 * 30.0) * DISPATCH_INTERVAL_HOURS atol = TOY_TOLERANCE
end

@testset "a net ramp-down floor above generation availability raises the generation ceiling" begin
    # INITIALMW = 20 (discharging); ramp_down = 1 MW/min over the 5-minute interval gives a net
    # ramp-down floor of 20 - 5 = 15, above the battery's own 10 MW generation availability. The
    # generation ceiling is raised to the floor, so the battery covers the full 15 MW load at its
    # $5/MWh offer instead of being capped at 10 MW.
    sys = nem_toy_system(
        [TOY_CHEAP => toy_unit(100.0, [(100.0, 100.0)]; initial = 0.0, ramp_up = 100.0)],
        15.0;
        batteries = [
            TOY_BATTERY => toy_battery(
                100.0, 5.0, 100.0, 1.0;
                initial = 20.0, ramp_up = 100.0, ramp_down = 1.0, gen_avail = 10.0,
            ),
        ],
    )
    out = solve_toy(sys)

    @test out.battery_out_mw[TOY_BATTERY] ≈ 15.0 atol = TOY_TOLERANCE
    @test out.battery_in_mw[TOY_BATTERY] ≈ 0.0 atol = TOY_TOLERANCE
    @test out.dispatch_mw[TOY_CHEAP] ≈ 0.0 atol = TOY_TOLERANCE
    @test out.objective ≈ 15.0 * 5.0 * DISPATCH_INTERVAL_HOURS atol = TOY_TOLERANCE
end

@testset "a net ramp-up ceiling below negative load availability raises the load ceiling" begin
    # INITIALMW = -20 (charging); ramp_up = 1 MW/min over the 5-minute interval gives a net
    # ramp-up ceiling of -20 + 5 = -15, below the negative of the battery's own 10 MW load
    # availability (-10). The load ceiling is raised to 15, so the battery charges the full 15 MW
    # its $1000/MWh load bid values, off Alta's $20/MWh supply, instead of being capped at 10 MW.
    sys = nem_toy_system(
        [TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = 60.0, ramp_up = 100.0)],
        0.0;
        batteries = [
            TOY_BATTERY => toy_battery(
                100.0, 1.0, 100.0, 1000.0;
                initial = -20.0, ramp_up = 1.0, ramp_down = 100.0, gen_avail = 0.0, load_avail = 10.0,
            ),
        ],
    )
    out = solve_toy(sys)

    @test out.battery_in_mw[TOY_BATTERY] ≈ 15.0 atol = TOY_TOLERANCE
    @test out.battery_out_mw[TOY_BATTERY] ≈ 0.0 atol = TOY_TOLERANCE
    @test out.dispatch_mw[TOY_CHEAP] ≈ 15.0 atol = TOY_TOLERANCE
    @test out.objective ≈ (15.0 * 20.0 - 15.0 * 1000.0) * DISPATCH_INTERVAL_HOURS atol = TOY_TOLERANCE
end

@testset "a per-direction availability binding" begin
    @testset "discharge is capped by the generation-side MAXAVAIL, not the cheaper price" begin
        # The battery's $5/MWh offer is cheaper than Alta's $20/MWh, so it would fill first
        # without a cap; its 10 MW generation availability caps it well below the 50 MW load,
        # and its load availability is zero, so it never charges.
        sys = nem_toy_system(
            [TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = 60.0, ramp_up = 100.0)],
            50.0;
            batteries = [
                TOY_BATTERY => toy_battery(
                    10.0, 5.0, 10.0, 1.0; initial = 0.0, ramp_up = 100.0, load_avail = 0.0,
                ),
            ],
        )
        out = solve_toy(sys)

        @test out.battery_out_mw[TOY_BATTERY] ≈ 10.0 atol = TOY_TOLERANCE
        @test out.battery_in_mw[TOY_BATTERY] ≈ 0.0 atol = TOY_TOLERANCE
        @test out.dispatch_mw[TOY_CHEAP] ≈ 40.0 atol = TOY_TOLERANCE
        @test out.price ≈ 20.0 atol = TOY_TOLERANCE
        @test out.objective ≈ (40.0 * 20.0 + 10.0 * 5.0) * DISPATCH_INTERVAL_HOURS atol = TOY_TOLERANCE
    end

    @testset "charge is capped by the load-side MAXAVAIL, not the attractive price" begin
        # The battery's $1000/MWh load bid is far above Alta's $20/MWh cost, so it would
        # charge without limit; its 8 MW load availability caps it, and its generation
        # availability is zero, so it never discharges.
        sys = nem_toy_system(
            [TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = 60.0, ramp_up = 100.0)],
            0.0;
            batteries = [
                TOY_BATTERY => toy_battery(
                    10.0, 1.0, 20.0, 1000.0; initial = 0.0, ramp_up = 100.0, gen_avail = 0.0, load_avail = 8.0,
                ),
            ],
        )
        out = solve_toy(sys)

        @test out.battery_in_mw[TOY_BATTERY] ≈ 8.0 atol = TOY_TOLERANCE
        @test out.battery_out_mw[TOY_BATTERY] ≈ 0.0 atol = TOY_TOLERANCE
        @test out.dispatch_mw[TOY_CHEAP] ≈ 8.0 atol = TOY_TOLERANCE
        @test out.price ≈ 20.0 atol = TOY_TOLERANCE
        @test out.objective ≈ (8.0 * 20.0 - 8.0 * 1000.0) * DISPATCH_INTERVAL_HOURS atol = TOY_TOLERANCE
    end
end

@testset "a generic constraint binds against NEMReplayDispatch" begin
    function constrained_toy(rhs_mw)
        return nem_toy_system(
            [
                TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = 60.0, ramp_up = 100.0),
                TOY_EXPENSIVE => toy_unit(100.0, [(100.0, 80.0)]; initial = 60.0, ramp_up = 100.0),
            ],
            120.0;
            mutate! = (sys, stamps) -> add_toy_generic_constraint!(sys, stamps, TOY_CHEAP, rhs_mw),
        )
    end

    @testset "a 70 MW cap on the cheap unit binds, forcing the expensive unit up" begin
        out = solve_toy(constrained_toy(70.0))

        @test out.dispatch_mw[TOY_CHEAP] ≈ 70.0 atol = TOY_TOLERANCE
        @test out.dispatch_mw[TOY_EXPENSIVE] ≈ 50.0 atol = TOY_TOLERANCE
        @test out.price ≈ 80.0 atol = TOY_TOLERANCE
        @test out.objective ≈ (70.0 * 20.0 + 50.0 * 80.0) * DISPATCH_INTERVAL_HOURS atol = TOY_TOLERANCE

        # A binding `<=` carries a negative dual under minimisation.
        @test out.constraint_price["N_TOY_LIMIT"] ≈ -60.0 atol = TOY_TOLERANCE
    end

    @testset "a 120 MW cap is slack, and merit order is unaffected" begin
        out = solve_toy(constrained_toy(120.0))

        @test out.dispatch_mw[TOY_CHEAP] ≈ 100.0 atol = TOY_TOLERANCE
        @test out.dispatch_mw[TOY_EXPENSIVE] ≈ 20.0 atol = TOY_TOLERANCE
        @test out.price ≈ 80.0 atol = TOY_TOLERANCE
        @test out.constraint_price["N_TOY_LIMIT"] ≈ 0.0 atol = TOY_TOLERANCE
    end
end

@testset "a ramp-up ceiling below zero is violated at 1155 x the Market Price Cap" begin
    # INITIALMW = -1 MW with a zero ramp rate gives x <= -1 against x >= 0, as for an offline
    # hydro unit with a slightly negative reading. The ramp row is elastic, the bound is not:
    # the unit stays at 0 MW and the 1 MW up slack is priced at 1155 x MPC for one interval.
    sys = nem_toy_system(
        [TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = -1.0, ramp_up = 0.0)],
        0.0,
    )
    out = solve_toy(sys)
    mpc = AustralianElectricityMarketsSimulations._financial_year_mpc(TOY_START)

    @test out.dispatch_mw[TOY_CHEAP] ≈ 0.0 atol = TOY_TOLERANCE
    @test out.ramp_slack_mw.up ≈ 1.0 atol = TOY_TOLERANCE
    @test out.ramp_slack_mw.down ≈ 0.0 atol = TOY_TOLERANCE
    @test out.objective ≈ UNIT_RAMP_CVP_FACTOR * mpc * DISPATCH_INTERVAL_HOURS atol = 1.0e-4
    @test UNIT_RAMP_CVP_FACTOR == 1155.0
end
