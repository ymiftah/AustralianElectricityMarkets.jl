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
    # The battery's offer band ties with Alta's at 20, so the held-back band carries the
    # tie-break slack penalty (1e-6) into the price.
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
    @test out.objective ≈ UNIT_RAMP_CVP_FACTOR * mpc * DISPATCH_INTERVAL_HOURS rtol = 1.0e-8
end

@testset "a scheduled load adds to the balance and clears when its bid is above the price" begin
    # Alta's $20/MWh offer covers the 40 MW demand plus the pump's full 30 MW: its $50/MWh decremental
    # bid values that consumption above Alta's cost, so the objective falls by (50 - 20) * 30 against
    # the 40 * 20 baseline.
    sys = nem_toy_system(
        [
            TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = 40.0, ramp_up = 100.0),
            TOY_EXPENSIVE => toy_unit(100.0, [(100.0, 80.0)]; initial = 0.0, ramp_up = 100.0),
        ],
        40.0;
        loads = ["PUMP" => toy_load(30.0, 50.0; initial = 30.0, ramp_up = 100.0)],
    )
    @test PSY.get_max_active_power(PSY.get_component(PSY.InterruptiblePowerLoad, sys, "PUMP")) > 0
    out = solve_toy(sys)

    @test out.load_mw["PUMP"] ≈ 30.0 atol = TOY_TOLERANCE
    @test out.dispatch_mw[TOY_CHEAP] ≈ 70.0 atol = TOY_TOLERANCE
    @test out.dispatch_mw[TOY_EXPENSIVE] ≈ 0.0 atol = TOY_TOLERANCE
    @test out.price ≈ 20.0 atol = TOY_TOLERANCE
    @test out.objective ≈ (70.0 * 20.0 - 30.0 * 50.0) * DISPATCH_INTERVAL_HOURS atol = TOY_TOLERANCE
end

@testset "a scheduled load does not clear when its bid is below the price" begin
    sys = nem_toy_system(
        [TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = 40.0, ramp_up = 100.0)],
        40.0;
        loads = ["PUMP" => toy_load(30.0, 10.0; initial = 0.0, ramp_up = 100.0)],
    )
    out = solve_toy(sys)

    @test out.load_mw["PUMP"] ≈ 0.0 atol = TOY_TOLERANCE
    @test out.dispatch_mw[TOY_CHEAP] ≈ 40.0 atol = TOY_TOLERANCE
end

@testset "a scheduled load is limited by its availability and ramp rate" begin
    function pump_toy(; availability, ramp_up)
        return nem_toy_system(
            [TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = 40.0, ramp_up = 100.0)],
            40.0;
            loads = ["PUMP" => toy_load(30.0, 50.0; initial = 5.0, ramp_up, availability)],
        )
    end
    # 5 MW + 2 MW/min over 5 minutes caps the pump at 15 MW, below its 30 MW availability.
    ramp_limited = solve_toy(pump_toy(; availability = 30.0, ramp_up = 2.0))
    @test ramp_limited.load_mw["PUMP"] ≈ 15.0 atol = TOY_TOLERANCE
    @test ramp_limited.dispatch_mw[TOY_CHEAP] ≈ 55.0 atol = TOY_TOLERANCE

    availability_limited = solve_toy(pump_toy(; availability = 10.0, ramp_up = 100.0))
    @test availability_limited.load_mw["PUMP"] ≈ 10.0 atol = TOY_TOLERANCE
end

@testset "a battery's ramp floor above its rating raises the rating, and its ramp row is priced" begin
    # INITIALMW = -50 (charging) with a zero up rate pins net <= -50, above the battery's 40 MW
    # input rating. NEMDE breaks MaxAvail and the rating before the ramp row, so the input
    # variable's upper bound is raised to 50 and the ramp slack stays zero. On the base branch
    # this build fails at the storage envelope check.
    sys = nem_toy_system(
        [TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = 60.0, ramp_up = 100.0)],
        0.0;
        batteries = [
            TOY_BATTERY => toy_battery(
                10.0, 1000.0, 50.0, 0.0; initial = -50.0, ramp_up = 0.0, gen_avail = 0.0, load_avail = 40.0,
            ),
        ],
        mutate! = function (s, _)
            battery = PSY.get_component(PSY.EnergyReservoirStorage, s, TOY_BATTERY)
            PSY.set_input_active_power_limits!(battery, (min = 0.0, max = 40.0))
            return
        end,
    )
    out = solve_toy(sys)
    mpc = AustralianElectricityMarketsSimulations._financial_year_mpc(TOY_START)

    @test out.battery_in_mw[TOY_BATTERY] ≈ 50.0 atol = TOY_TOLERANCE
    @test out.storage_ramp_slack_mw.up ≈ 0.0 atol = TOY_TOLERANCE
    @test out.objective ≈ 50.0 * 20.0 * DISPATCH_INTERVAL_HOURS rtol = 1.0e-8

    @testset "the storage ramp slack is priced at 1155 x MPC" begin
        slack = PSI.get_variable(out.container, UnitRampUpSlack(), PSY.EnergyReservoirStorage)[TOY_BATTERY, 1]
        coefficient = PSI.JuMP.objective_function(PSI.get_jump_model(out.container)).terms[slack]
        @test coefficient ≈
            PSY.get_base_power(sys) * interval_cost_coefficient(UNIT_RAMP_CVP_FACTOR * mpc, TOY_RESOLUTION)
    end
end

@testset "constraint_violations directions follow the relaxed row's sense" begin
    direction = AustralianElectricityMarketsSimulations._violation_direction
    sys = nem_toy_system(
        [TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = 40.0, ramp_up = 100.0)],
        40.0;
        loads = ["PUMP" => toy_load(30.0, 50.0; initial = 5.0, ramp_up = 100.0)],
    )
    for (name, bid_type) in (("S_RAISEREG", BidType.RAISEREG), ("S_LOWERREG", BidType.LOWERREG))
        service = FCASService(; name, region = "1", bid_type = bid_type)
        PSY.add_service!(sys, service, [PSY.get_component(PSY.StaticInjection, sys, n) for n in (TOY_CHEAP, "PUMP")])
    end
    # Capacity rows: the sense follows the `_lower` suffix whatever the device.
    @test direction(sys, FCASJointCapacitySlack, "S_RAISEREG_upper", TOY_CHEAP, "up") == "up"
    @test direction(sys, FCASJointCapacitySlack, "S_RAISEREG_lower", TOY_CHEAP, "up") == "down"
    @test direction(sys, FCASJointCapacitySlack, "S_RAISEREG_gen_lower", "PUMP", "up") == "down"
    @test direction(sys, FCASJointCapacitySlack, "S_RAISEREG_load_upper", "PUMP", "up") == "up"
    # Joint ramping: a generator's RAISEREG row is the `<=` form, a load's LOWERREG row is.
    @test direction(sys, FCASJointRampingSlack, "S_RAISEREG", TOY_CHEAP, "up") == "up"
    @test direction(sys, FCASJointRampingSlack, "S_LOWERREG", TOY_CHEAP, "up") == "down"
    @test direction(sys, FCASJointRampingSlack, "S_LOWERREG", "PUMP", "up") == "up"
    @test direction(sys, FCASJointRampingSlack, "S_RAISEREG", "PUMP", "up") == "down"
    @test direction(sys, UnitRampDownSlack, "", TOY_CHEAP, "down") == "down"
end

@testset "penalty ordering is strictly increasing across the CVP schedule" begin
    # AEMO CVP schedule v8.0: area balance 150, FCAS 155, interconnector flow 1150, unit ramp 1155.
    factors = [
        AREA_BALANCE_CVP_FACTOR, FCAS_MAXAVAIL_CVP_FACTOR, INTERCONNECTOR_FLOW_CVP_FACTOR, UNIT_RAMP_CVP_FACTOR,
    ]
    @test factors == [150.0, 155.0, 1150.0, 1155.0]
    @test issorted(factors; lt = <)
    @test FCAS_BDU_RAMPING_CVP_FACTOR == FCAS_RAMPING_CVP_FACTOR == FCAS_MAXAVAIL_CVP_FACTOR
end

@testset "penalty ordering: a lower CVP row breaks before a higher one" begin
    mpc = AustralianElectricityMarketsSimulations._financial_year_mpc(TOY_START)

    @testset "the area balance (150) breaks before the unit ramp (1155)" begin
        # A 100 MW load against a unit that can climb 5 MW from 0: the 95 MW shortfall is cheaper
        # to leave unserved at 150 x MPC than to buy with a ramp violation at 1155 x MPC.
        sys = nem_toy_system(
            [TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = 0.0, ramp_up = 1.0)],
            100.0,
        )
        out = solve_toy(sys)
        violations = AustralianElectricityMarketsSimulations._constraint_violations(out.results, sys)

        @test out.dispatch_mw[TOY_CHEAP] ≈ 5.0 atol = TOY_TOLERANCE
        @test out.ramp_slack_mw.up ≈ 0.0 atol = TOY_TOLERANCE
        @test violations.family == ["area_balance"]
        # An equality row: the slack that adds supply (demand left unserved) is the "up" deficit.
        @test violations.direction == ["up"]
        @test only(violations.MW) ≈ 95.0 atol = TOY_TOLERANCE
        @test out.objective ≈
            (5.0 * 20.0 + 95.0 * AREA_BALANCE_CVP_FACTOR * mpc) * DISPATCH_INTERVAL_HOURS rtol = 1.0e-8
    end

    @testset "the unit ramp (1155) is reported when it is the only relaxation" begin
        # The ramp row is infeasible against the zero bound (INITIALMW -1, zero rate) with no load:
        # the ramp slack is the only relaxation, and it is reported.
        sys = nem_toy_system(
            [TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = -1.0, ramp_up = 0.0)],
            0.0,
        )
        out = solve_toy(sys)
        violations = AustralianElectricityMarketsSimulations._constraint_violations(out.results, sys)

        @test violations.family == ["unit_ramp"]
        @test only(violations.MW) ≈ 1.0 atol = TOY_TOLERANCE
    end

    @testset "an ordinary interval reports no violation" begin
        sys = nem_toy_system(
            [TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = 60.0, ramp_up = 100.0)],
            40.0,
        )
        out = solve_toy(sys)
        @test isempty(AustralianElectricityMarketsSimulations._constraint_violations(out.results, sys))
    end
end

@testset "price-tied bands clear pro rata to band MW" begin
    third = "Solitude"
    function tied_toy(prices; ramp_up = (100.0, 100.0, 100.0), load = 168.0)
        return nem_toy_system(
            [
                TOY_CHEAP => toy_unit(168.0, [(168.0, prices[1])]; initial = 0.0, ramp_up = ramp_up[1]),
                TOY_EXPENSIVE => toy_unit(46.0, [(46.0, prices[2])]; initial = 0.0, ramp_up = ramp_up[2]),
                third => toy_unit(122.0, [(122.0, prices[3])]; initial = 0.0, ramp_up = ramp_up[3]),
            ],
            load,
        )
    end

    @testset "three tied units share the load in proportion to band MW" begin
        out = solve_toy(tied_toy((-984.5, -984.5, -984.5)))
        @test out.dispatch_mw[TOY_CHEAP] ≈ 84.0 atol = 1.0e-5
        @test out.dispatch_mw[TOY_EXPENSIVE] ≈ 23.0 atol = 1.0e-5
        @test out.dispatch_mw[third] ≈ 61.0 atol = 1.0e-5
        @test out.price ≈ -984.5 atol = TOY_TOLERANCE
        @test out.objective ≈ -984.5 * 168.0 * DISPATCH_INTERVAL_HOURS atol = 1.0e-6
    end

    @testset "prices within the tolerance are tied, prices beyond it are not" begin
        near = solve_toy(tied_toy((10.0, 10.0 + 0.01 * TIE_BREAK_CVP_FACTOR, 10.0); load = 168.0))
        @test near.dispatch_mw[TOY_CHEAP] ≈ 84.0 atol = 1.0e-5
        @test near.dispatch_mw[third] ≈ 61.0 atol = 1.0e-5
        apart = solve_toy(tied_toy((10.0, 20.0, 10.0); load = 168.0))
        @test apart.dispatch_mw[TOY_EXPENSIVE] ≈ 0.0 atol = TOY_TOLERANCE
        @test apart.dispatch_mw[TOY_CHEAP] ≈ 168.0 * 168.0 / 290.0 atol = 1.0e-5
        @test apart.dispatch_mw[third] ≈ 168.0 * 122.0 / 290.0 atol = 1.0e-5
    end

    @testset "non-tied units keep merit order, price and objective" begin
        out = solve_toy(tied_toy((10.0, 30.0, 20.0); load = 200.0))
        @test out.dispatch_mw[TOY_CHEAP] ≈ 168.0 atol = TOY_TOLERANCE
        @test out.dispatch_mw[third] ≈ 32.0 atol = TOY_TOLERANCE
        @test out.dispatch_mw[TOY_EXPENSIVE] ≈ 0.0 atol = TOY_TOLERANCE
        @test out.price ≈ 20.0 atol = TOY_TOLERANCE
        @test out.objective ≈ (168.0 * 10.0 + 32.0 * 20.0) * DISPATCH_INTERVAL_HOURS atol = TOY_TOLERANCE
    end

    @testset "a ramp-bound tied unit relaxes the tie without moving the price or objective" begin
        # Cheap unit can reach only 5 * 8 = 40 MW; its fill fraction cannot match the others.
        out = solve_toy(tied_toy((10.0, 10.0, 10.0); ramp_up = (8.0, 100.0, 100.0)))
        @test out.dispatch_mw[TOY_CHEAP] ≤ 40.0 + TOY_TOLERANCE
        @test sum(values(out.dispatch_mw)) ≈ 168.0 atol = TOY_TOLERANCE
        @test out.price ≈ 10.0 atol = TOY_TOLERANCE
        @test out.objective ≈ 10.0 * 168.0 * DISPATCH_INTERVAL_HOURS atol = 1.0e-4
        # The two unconstrained units stay pro rata to each other.
        @test out.dispatch_mw[TOY_EXPENSIVE] / 46.0 ≈ out.dispatch_mw[third] / 122.0 atol = 1.0e-4
    end

    @testset "a held-back unit in the middle of the sort order does not skew the others" begin
        # Park City sorts between Alta and Solitude; its 2 MW/min ramp caps it at 10 MW.
        out = solve_toy(tied_toy((10.0, 10.0, 10.0); ramp_up = (100.0, 2.0, 100.0)))
        @test out.dispatch_mw[TOY_EXPENSIVE] ≤ 10.0 + TOY_TOLERANCE
        @test sum(values(out.dispatch_mw)) ≈ 168.0 atol = TOY_TOLERANCE
        @test out.dispatch_mw[TOY_CHEAP] / 168.0 ≈ out.dispatch_mw[third] / 122.0 atol = 1.0e-4
    end

    @testset "a battery offer band ties with a thermal band across device types" begin
        sys = nem_toy_system(
            [TOY_CHEAP => toy_unit(100.0, [(100.0, 10.0)]; initial = 0.0, ramp_up = 100.0)],
            100.0;
            batteries = [TOY_BATTERY => toy_battery(100.0, 10.0, 50.0, 1.0; initial = 0.0, ramp_up = 100.0)],
        )
        out = solve_toy(sys)
        @test out.dispatch_mw[TOY_CHEAP] ≈ 50.0 atol = 1.0e-5
        @test out.battery_out_mw[TOY_BATTERY] ≈ 50.0 atol = 1.0e-5
    end

    @testset "tied load bids of two batteries clear pro rata" begin
        sys = nem_toy_system(
            [TOY_CHEAP => toy_unit(50.0, [(50.0, 5.0)]; initial = 0.0, ramp_up = 100.0)],
            0.0;
            batteries = [
                "batt1" => toy_battery(10.0, 1000.0, 60.0, 50.0; initial = 0.0, ramp_up = 100.0),
                "batt2" => toy_battery(10.0, 1000.0, 40.0, 50.0; initial = 0.0, ramp_up = 100.0),
            ],
        )
        out = solve_toy(sys)
        @test out.battery_in_mw["batt1"] ≈ 30.0 atol = 1.0e-5
        @test out.battery_in_mw["batt2"] ≈ 20.0 atol = 1.0e-5
    end
end

@testset "tie detection pairs" begin
    band(price, width, name, band = 1) = (; price, width, name, band)
    tol = TIE_BREAK_CVP_FACTOR
    pairs = AustralianElectricityMarketsSimulations._tied_pairs
    @test pairs([band(5.0, 1.0, "a"), band(5.0, 2.0, "b"), band(5.0, 3.0, "c")]) == [(1, 2), (1, 3), (2, 3)]
    # Same-unit bands and zero-width bands are never paired.
    @test pairs([band(5.0, 1.0, "a", 1), band(5.0, 1.0, "a", 2), band(5.0, 1.0, "b")]) == [(1, 3), (2, 3)]
    @test pairs([band(5.0, 0.0, "a"), band(5.0, 1.0, "b")]) == []
    # Different prices beyond the tolerance stay separate; within it they tie, transitively.
    @test pairs([band(5.0, 1.0, "a"), band(5.0 + 2tol, 1.0, "b")]) == []
    @test pairs([band(5.0, 1.0, "a"), band(5.0 + 0.8tol, 1.0, "b"), band(5.0 + 1.6tol, 1.0, "c")]) ==
        [(1, 2), (1, 3), (2, 3)]
end
