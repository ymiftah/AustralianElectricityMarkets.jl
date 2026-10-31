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
    @test out.objective ≈ (100.0 * 20.0 + 20.0 * 80.0) * interval_hours(DISPATCH_INTERVAL) atol = TOY_TOLERANCE
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
    @test out.objective ≈ (20.0 * 20.0 + 20.0 * 50.0) * interval_hours(DISPATCH_INTERVAL) atol = TOY_TOLERANCE
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
    @test out.objective ≈ (60.0 * 20.0 + 40.0 * 80.0) * interval_hours(DISPATCH_INTERVAL) atol = TOY_TOLERANCE
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
    baseline_objective = 40.0 * 20.0 * interval_hours(DISPATCH_INTERVAL)
    @test out.objective ≈ baseline_objective - (50.0 - 20.0) * 30.0 * interval_hours(DISPATCH_INTERVAL) atol = TOY_TOLERANCE
    @test out.objective ≈ (70.0 * 20.0 - 30.0 * 50.0) * interval_hours(DISPATCH_INTERVAL) atol = TOY_TOLERANCE
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
    @test out.objective ≈ (5.0 * 20.0 - 5.0 * 30.0) * interval_hours(DISPATCH_INTERVAL) atol = TOY_TOLERANCE
end

@testset "a net ramp-down floor can violate generation availability at its price" begin
    # Ramping holds net generation at 15 MW despite 10 MW availability, incurring 5 MW
    # of availability violation rather than relaxing the higher-priority ramp row.
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
    @test out.objective ≈ (15.0 * 5.0 + 5.0 * AustralianElectricityMarkets.ENERGY_MAX_AVAIL_CVP_FACTOR * AustralianElectricityMarkets._financial_year_mpc(TOY_START)) * interval_hours(DISPATCH_INTERVAL) atol = 1.0e-4
end

@testset "a net ramp-up ceiling can violate load availability at its price" begin
    # Ramping holds net consumption at 15 MW despite 10 MW availability, incurring 5 MW
    # of availability violation at the raw offer limit.
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
    @test out.objective ≈ (15.0 * 20.0 - 15.0 * 1000.0 + 5.0 * AustralianElectricityMarkets.ENERGY_MAX_AVAIL_CVP_FACTOR * AustralianElectricityMarkets._financial_year_mpc(TOY_START)) * interval_hours(DISPATCH_INTERVAL) atol = 1.0e-4
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
        @test out.objective ≈ (40.0 * 20.0 + 10.0 * 5.0) * interval_hours(DISPATCH_INTERVAL) atol = TOY_TOLERANCE
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
        @test out.objective ≈ (8.0 * 20.0 - 8.0 * 1000.0) * interval_hours(DISPATCH_INTERVAL) atol = TOY_TOLERANCE
    end
end

@testset "storage availability is elastic without a static or derived ceiling" begin
    for (gen, load) in ((20.0, 100.0), (100.0, 20.0))
        sys = nem_toy_system(
            [TOY_CHEAP => toy_unit(200.0, [(200.0, 20.0)]; initial = 60.0, ramp_up = 100.0)], 0.0;
            batteries = [
                TOY_BATTERY => toy_battery(
                    100.0, 1000.0, 100.0, 50.0;
                    initial = 0.0, ramp_up = 100.0, gen_avail = gen, load_avail = load
                ),
            ],
            mutate! = function (sys, _)
                battery = PSY.get_component(PSY.EnergyReservoirStorage, sys, TOY_BATTERY)
                PSY.set_input_active_power_limits!(battery, (min = 0.0, max = 5.0))
                PSY.set_output_active_power_limits!(battery, (min = 0.0, max = 5.0))
                return
            end,
        )
        out = solve_toy(sys)
        @test out.battery_in_mw[TOY_BATTERY] ≈ load atol = TOY_TOLERANCE
        @test out.battery_out_mw[TOY_BATTERY] ≈ 0.0 atol = TOY_TOLERANCE
        for variable_type in (PSI.ActivePowerOutVariable, PSI.ActivePowerInVariable)
            variables = PSI.get_variable(out.container, variable_type(), PSY.EnergyReservoirStorage)
            @test !PSI.JuMP.has_upper_bound(variables[TOY_BATTERY, 1])
        end
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
        @test out.objective ≈ (70.0 * 20.0 + 50.0 * 80.0) * interval_hours(DISPATCH_INTERVAL) atol = TOY_TOLERANCE

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
    mpc = AustralianElectricityMarkets._financial_year_mpc(TOY_START)

    @test out.dispatch_mw[TOY_CHEAP] ≈ 0.0 atol = TOY_TOLERANCE
    @test out.ramp_slack_mw.up ≈ 1.0 atol = TOY_TOLERANCE
    @test out.ramp_slack_mw.down ≈ 0.0 atol = TOY_TOLERANCE
    @test out.objective ≈ AustralianElectricityMarkets.UNIT_RAMP_CVP_FACTOR * mpc * interval_hours(DISPATCH_INTERVAL) rtol = 1.0e-8
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
    @test out.objective ≈ (70.0 * 20.0 - 30.0 * 50.0) * interval_hours(DISPATCH_INTERVAL) atol = TOY_TOLERANCE
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

@testset "a scheduled load's fixed loading holds its consumption against its bid" begin
    # The pump's $10/MWh bid would not clear at Alta's $20/MWh, but a 20 MW fixed loading holds it there.
    sys = nem_toy_system(
        [TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = 40.0, ramp_up = 100.0)],
        40.0;
        loads = ["PUMP" => toy_load(30.0, 10.0; initial = 0.0, ramp_up = 100.0)],
        mutate! = function (sys, stamps)
            pump = PSY.get_component(PSY.InterruptiblePowerLoad, sys, "PUMP")
            base = PSY.get_base_power(sys)
            PSY.add_time_series!(sys, pump, PSY.SingleTimeSeries(; name = "fixed_load", data = PSY.TimeSeries.TimeArray(stamps, fill(20.0 / base, 2))))
            PSY.add_time_series!(sys, pump, PSY.SingleTimeSeries(; name = "fixed_load_invoked", data = PSY.TimeSeries.TimeArray(stamps, ones(2))))
            return
        end,
    )
    out = solve_toy(sys)

    @test out.load_mw["PUMP"] ≈ 20.0 atol = TOY_TOLERANCE
    @test out.dispatch_mw[TOY_CHEAP] ≈ 60.0 atol = TOY_TOLERANCE
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

@testset "a battery's ramp floor can exceed its rating with priced availability" begin
    # INITIALMW = -50 (charging) with a zero up rate pins net <= -50, above the battery's 40 MW
    # input rating. NEMDE breaks MaxAvail and the rating before the ramp row, so the input
    # Availability absorbs the 10 MW conflict; static ratings do not impose another hard bound.
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
    mpc = AustralianElectricityMarkets._financial_year_mpc(TOY_START)
    input_variable = PSI.get_variable(out.container, PSI.ActivePowerInVariable(), PSY.EnergyReservoirStorage)

    @test out.battery_in_mw[TOY_BATTERY] ≈ 50.0 atol = TOY_TOLERANCE
    @test !PSI.JuMP.has_upper_bound(input_variable[TOY_BATTERY, 1])
    @test out.storage_ramp_slack_mw.up ≈ 0.0 atol = TOY_TOLERANCE
    @test out.objective ≈ (50.0 * 20.0 + 10.0 * AustralianElectricityMarkets.ENERGY_MAX_AVAIL_CVP_FACTOR * mpc) * interval_hours(DISPATCH_INTERVAL) rtol = 1.0e-8

    @testset "the storage ramp slack is priced at 1155 x MPC" begin
        slack = PSI.get_variable(out.container, UnitRampUpSlack(), PSY.EnergyReservoirStorage)[TOY_BATTERY, 1]
        coefficient = PSI.JuMP.objective_function(PSI.get_jump_model(out.container)).terms[slack]
        @test coefficient ≈
            PSY.get_base_power(sys) * interval_cost_coefficient(AustralianElectricityMarkets.UNIT_RAMP_CVP_FACTOR * mpc, TOY_RESOLUTION)
    end
end

@testset "constraint_violations directions follow the relaxed row's sense" begin
    direction = ReplayResults._violation_direction
    sys = nem_toy_system(
        [TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = 40.0, ramp_up = 100.0)],
        40.0;
        loads = ["PUMP" => toy_load(30.0, 50.0; initial = 5.0, ramp_up = 100.0)],
    )
    for (name, bid_type) in (("S_RAISEREG", BidType.RAISEREG), ("S_LOWERREG", BidType.LOWERREG))
        service = FCASService(; name, region = "1", bid_type = bid_type)
        PSY.add_service!(sys, service, [PSY.get_component(PSY.StaticInjection, sys, n) for n in (TOY_CHEAP, "PUMP")])
    end
    flush_toy_fcas_curves!(sys)
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

@testset "penalty ordering: a lower CVP row breaks before a higher one" begin
    mpc = AustralianElectricityMarkets._financial_year_mpc(TOY_START)

    @testset "the area balance (150) breaks before the unit ramp (1155)" begin
        # A 100 MW load against a unit that can climb 5 MW from 0: the 95 MW shortfall is cheaper
        # to leave unserved at 150 x MPC than to buy with a ramp violation at 1155 x MPC.
        sys = nem_toy_system(
            [TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = 0.0, ramp_up = 1.0)],
            100.0,
        )
        out = solve_toy(sys)
        violations = ReplayResults._constraint_violations(out.results, sys)

        @test out.dispatch_mw[TOY_CHEAP] ≈ 5.0 atol = TOY_TOLERANCE
        @test out.ramp_slack_mw.up ≈ 0.0 atol = TOY_TOLERANCE
        @test violations.family == ["area_balance"]
        # An equality row: the slack that adds supply (demand left unserved) is the "up" deficit.
        @test violations.direction == ["up"]
        @test only(violations.MW) ≈ 95.0 atol = TOY_TOLERANCE
        @test out.objective ≈
            (5.0 * 20.0 + 95.0 * AustralianElectricityMarkets.AREA_BALANCE_CVP_FACTOR * mpc) * interval_hours(DISPATCH_INTERVAL) rtol = 1.0e-8
    end

    @testset "the unit ramp (1155) is reported when it is the only relaxation" begin
        # The ramp row is infeasible against the zero bound (INITIALMW -1, zero rate) with no load:
        # the ramp slack is the only relaxation, and it is reported.
        sys = nem_toy_system(
            [TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = -1.0, ramp_up = 0.0)],
            0.0,
        )
        out = solve_toy(sys)
        violations = ReplayResults._constraint_violations(out.results, sys)

        @test violations.family == ["unit_ramp"]
        @test only(violations.MW) ≈ 1.0 atol = TOY_TOLERANCE
    end

    @testset "an ordinary interval reports no violation" begin
        sys = nem_toy_system(
            [TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = 60.0, ramp_up = 100.0)],
            40.0,
        )
        out = solve_toy(sys)
        @test isempty(ReplayResults._constraint_violations(out.results, sys))
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
        @test out.objective ≈ -984.5 * 168.0 * interval_hours(DISPATCH_INTERVAL) atol = 1.0e-6
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
        @test out.objective ≈ (168.0 * 10.0 + 32.0 * 20.0) * interval_hours(DISPATCH_INTERVAL) atol = TOY_TOLERANCE
    end

    @testset "a ramp-bound tied unit relaxes the tie without moving the price or objective" begin
        # Cheap unit can reach only 5 * 8 = 40 MW; its fill fraction cannot match the others.
        out = solve_toy(tied_toy((10.0, 10.0, 10.0); ramp_up = (8.0, 100.0, 100.0)))
        @test out.dispatch_mw[TOY_CHEAP] ≤ 40.0 + TOY_TOLERANCE
        @test sum(values(out.dispatch_mw)) ≈ 168.0 atol = TOY_TOLERANCE
        @test out.price ≈ 10.0 atol = TOY_TOLERANCE
        @test out.objective ≈ 10.0 * 168.0 * interval_hours(DISPATCH_INTERVAL) atol = 1.0e-4
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

    @testset "a group-limited tied set stays pro rata beside held-back tied bands, at production solver settings" begin
        # Alta, Park City and Solitude share a 168 MW group limit; Sundance and Brighton bid the
        # same price in three bands each and sit far below them (ramp), so every tied pair with
        # them is violated.
        group = (TOY_CHEAP, TOY_EXPENSIVE, third)
        mutate! = (sys, stamps) -> add_toy_generic_constraint!(sys, stamps, group, 168.0)
        sys = nem_toy_system(
            [
                TOY_CHEAP => toy_unit(168.0, [(168.0, -984.5)]; initial = 0.0, ramp_up = 100.0),
                TOY_EXPENSIVE => toy_unit(46.0, [(46.0, -984.5)]; initial = 0.0, ramp_up = 100.0),
                third => toy_unit(122.0, [(122.0, -984.5)]; initial = 0.0, ramp_up = 100.0),
                "Sundance" => toy_unit(300.0, fill((100.0, -984.5), 3); initial = 0.0, ramp_up = 4.0),
                "Brighton" => toy_unit(300.0, fill((100.0, -984.5), 3); initial = 0.0, ramp_up = 6.0),
            ],
            218.0;
            mutate!,
        )
        production = optimizer_with_attributes(
            HiGHS.Optimizer, "output_flag" => false, "mip_rel_gap" => 0.0, "mip_abs_gap" => 1.0e-10,
        )
        out = solve_toy(sys; optimizer = production)
        @test out.dispatch_mw["Sundance"] ≈ 20.0 atol = 1.0e-4
        @test out.dispatch_mw["Brighton"] ≈ 30.0 atol = 1.0e-4
        @test out.dispatch_mw[TOY_CHEAP] ≈ 84.0 atol = 1.0e-3
        @test out.dispatch_mw[TOY_EXPENSIVE] ≈ 23.0 atol = 1.0e-3
        @test out.dispatch_mw[third] ≈ 61.0 atol = 1.0e-3
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

@testset "tie groups" begin
    band(price, name, band = 1) = (; price, name, band)
    tol = TIE_BREAK_CVP_FACTOR
    groups = AustralianElectricityMarkets.tie_groups
    @test groups([band(5.0, "a"), band(5.0, "b"), band(5.0, "c")]) == [[1, 2, 3]]
    # A run of one unit's bands is no group; zero-width bands are grouped like any other.
    @test groups([band(5.0, "a", 1), band(5.0, "a", 2), band(7.0, "b")]) == Vector{Int}[]
    @test groups([band(5.0, "a", 2), band(5.0, "a", 1), band(5.0, "b")]) == [[2, 1, 3]]
    # Prices beyond the tolerance stay separate, within it they tie; a transitive chain throws.
    @test groups([band(5.0, "a"), band(5.0 + 2tol, "b")]) == Vector{Int}[]
    @test groups([band(5.0, "a"), band(5.0 + 0.5tol, "b")]) == [[1, 2]]
    @test_throws r"transitive ties are not supported" groups([band(5.0, "a"), band(5.0 + 0.8tol, "b"), band(5.0 + 1.6tol, "c")])
end

@testset "tie-break scale series" begin
    third = "Solitude"
    sys = nem_toy_system(
        [
            TOY_CHEAP => toy_unit(168.0, [(168.0, 10.0)]; initial = 0.0, ramp_up = 100.0),
            TOY_EXPENSIVE => toy_unit(46.0, [(46.0, 10.0), (10.0, 30.0)]; initial = 0.0, ramp_up = 100.0),
            third => toy_unit(122.0, [(122.0, 10.0)]; initial = 0.0, ramp_up = 100.0),
        ],
        168.0,
    )
    scale(name, k) = PSY.get_time_series_values(
        PSY.SingleTimeSeries, PSY.get_component(PSY.ThermalStandard, sys, name), "tie_break_scale_$k",
    )
    @test scale(TOY_CHEAP, 1) ≈ [1.0, 1.0]
    @test scale(TOY_EXPENSIVE, 1) ≈ fill(46.0 / 168.0, 2)
    @test scale(third, 1) ≈ fill(122.0 / 168.0, 2)
    # Park City's $30 band ties with no other unit, so it carries no scale.
    @test !PSY.has_time_series(PSY.get_component(PSY.ThermalStandard, sys, TOY_EXPENSIVE), PSY.SingleTimeSeries, "tie_break_scale_2")

    # A tied contributor without its scale series fails the build.
    unscaled = nem_toy_system(
        [
            TOY_CHEAP => toy_unit(100.0, [(100.0, 10.0)]; initial = 0.0, ramp_up = 100.0),
            TOY_EXPENSIVE => toy_unit(100.0, [(100.0, 10.0)]; initial = 0.0, ramp_up = 100.0),
        ],
        100.0;
        tie_break_scales = false,
    )
    PSY.add_service!(
        unscaled, EnergyTieBreak(; name = TIE_BREAK_SERVICE_NAME),
        [PSY.get_component(PSY.ThermalStandard, unscaled, n) for n in (TOY_CHEAP, TOY_EXPENSIVE)],
    )
    template = PSI.ProblemTemplate(PSI.NetworkModel(PSI.AreaBalancePowerModel; use_slacks = true))
    set_nem_dispatch_models!(template, unscaled)
    PSI.set_device_model!(template, PSY.PowerLoad, PSI.StaticPowerLoad)
    model = toy_model(unscaled; template)
    status, log = _toy_build_log(model)
    @test status == PSI.ModelBuildStatus.FAILED
    @test occursin("tie-break: 2 unit(s) with price-tied bands carry no tie-break scale forecast: Alta, Park City.", log)
    @test occursin("Call set_tie_break_scales!(sys) before transform_single_time_series!.", log)
end

@testset "a unit carrying tie-break scales must be modelled" begin
    tie_model() = PSI.ServiceModel(EnergyTieBreak, TieBreakMarket, TIE_BREAK_SERVICE_NAME)
    sys = nem_toy_system(
        [
            TOY_CHEAP => toy_unit(100.0, [(100.0, 10.0)]; initial = 0.0, ramp_up = 100.0),
            TOY_EXPENSIVE => toy_unit(100.0, [(100.0, 10.0)]; initial = 0.0, ramp_up = 100.0),
        ],
        100.0,
    )
    # No ThermalStandard model: PowerSimulations finds no modelled contributor of the service.
    template = PSI.ProblemTemplate(PSI.NetworkModel(PSI.AreaBalancePowerModel; use_slacks = true))
    PSI.set_device_model!(template, PSY.PowerLoad, PSI.StaticPowerLoad)
    PSI.set_service_model!(template, TIE_BREAK_SERVICE_NAME, tie_model())
    @test_throws r"contributing devices for service energy_tie_break is empty" toy_model(sys; template)

    # The battery ties with the thermal unit but has no device model.
    mixed = nem_toy_system(
        [TOY_CHEAP => toy_unit(100.0, [(100.0, 10.0)]; initial = 0.0, ramp_up = 100.0)],
        100.0;
        batteries = [TOY_BATTERY => toy_battery(100.0, 10.0, 50.0, 1.0; initial = 0.0, ramp_up = 100.0)],
    )
    template = PSI.ProblemTemplate(PSI.NetworkModel(PSI.AreaBalancePowerModel; use_slacks = true))
    PSI.set_device_model!(template, PSY.ThermalStandard, NEMReplayDispatch)
    PSI.set_device_model!(template, PSY.PowerLoad, PSI.StaticPowerLoad)
    PSI.set_service_model!(template, TIE_BREAK_SERVICE_NAME, tie_model())
    model = toy_model(mixed; template)
    status, log = _toy_build_log(model)
    @test status == PSI.ModelBuildStatus.FAILED
    @test occursin("tie-break: 1 unit(s) carry tie-break scales but have no market-bid variables in the model: $TOY_BATTERY.", log)
end

@testset "a fixed-curve unit ties with time-varying units" begin
    third = "Solitude"
    # Replaces the expensive unit's time-varying offer with a fixed curve of the same band.
    function fix_offer!(sys, _)
        gen = PSY.get_component(PSY.ThermalStandard, sys, TOY_EXPENSIVE)
        PSY.remove_time_series!(sys, PSY.SingleTimeSeries, gen, "variable_cost")
        PSY.remove_time_series!(sys, PSY.SingleTimeSeries, gen, "incremental_initial_input")
        PSY.set_operation_cost!(
            gen,
            PSY.MarketBidCost(;
                no_load_cost = 0.0, start_up = (hot = 0.0, warm = 0.0, cold = 0.0), shut_down = 0.0,
                incremental_offer_curves = PSY.CostCurve(PSY.PiecewiseIncrementalCurve(0.0, [0.0, 46.0], [10.0])),
            ),
        )
        return
    end
    sys = nem_toy_system(
        [
            TOY_CHEAP => toy_unit(168.0, [(168.0, 10.0)]; initial = 0.0, ramp_up = 100.0),
            TOY_EXPENSIVE => toy_unit(46.0, [(46.0, 10.0)]; initial = 0.0, ramp_up = 100.0),
            third => toy_unit(122.0, [(122.0, 10.0)]; initial = 0.0, ramp_up = 100.0),
        ],
        168.0;
        mutate! = fix_offer!,
    )
    gen = PSY.get_component(PSY.ThermalStandard, sys, TOY_EXPENSIVE)
    @test PSY.get_time_series_values(PSY.SingleTimeSeries, gen, "tie_break_scale_1") ≈ fill(46.0 / 168.0, 2)

    out = solve_toy(sys)
    @test out.dispatch_mw[TOY_CHEAP] ≈ 84.0 atol = 1.0e-5
    @test out.dispatch_mw[TOY_EXPENSIVE] ≈ 23.0 atol = 1.0e-5
    @test out.dispatch_mw[third] ≈ 61.0 atol = 1.0e-5
    @test out.price ≈ 10.0 atol = TOY_TOLERANCE
end

@testset "empty bands priced alike do not form tie groups" begin
    # Both units hold a zero-width top band at the same price; only their first bands are tied.
    sys = nem_toy_system(
        [
            TOY_CHEAP => toy_unit(100.0, [(60.0, 20.0), (0.0, 15_000.0)]; initial = 30.0, ramp_up = 100.0),
            TOY_EXPENSIVE => toy_unit(100.0, [(40.0, 20.0), (0.0, 15_000.0)]; initial = 30.0, ramp_up = 100.0),
        ],
        50.0,
    )
    series(name, band) = PSY.has_time_series(PSY.get_component(PSY.ThermalStandard, sys, name), PSY.SingleTimeSeries, "tie_break_scale_$band")
    for name in (TOY_CHEAP, TOY_EXPENSIVE)
        @test series(name, 1)
        @test !series(name, 2)
    end
    out = solve_toy(sys)
    # The tied first bands share the 50 MW pro rata to their 60 and 40 MW widths.
    @test out.dispatch_mw[TOY_CHEAP] ≈ 30.0 atol = TOY_TOLERANCE
    @test out.dispatch_mw[TOY_EXPENSIVE] ≈ 20.0 atol = TOY_TOLERANCE
end

@testset "a band empty at the first interval but not later keeps its tie and a zero scale" begin
    sys = nem_toy_system(
        [
            TOY_CHEAP => toy_unit(100.0, [[(60.0, 20.0), (0.0, 50.0)], [(60.0, 20.0), (30.0, 50.0)]]; initial = 0.0, ramp_up = 100.0),
            TOY_EXPENSIVE => toy_unit(100.0, [(40.0, 20.0), (40.0, 50.0)]; initial = 0.0, ramp_up = 100.0),
        ],
        60.0,
    )
    scale(name, k) = PSY.get_time_series_values(
        PSY.SingleTimeSeries, PSY.get_component(PSY.ThermalStandard, sys, name), "tie_break_scale_$k",
    )
    @test scale(TOY_CHEAP, 2) ≈ [0.0, 30.0 / 40.0]
    @test scale(TOY_EXPENSIVE, 2) ≈ [1.0, 1.0]
end

@testset "set_tie_break_scales! removes scales left by an earlier call" begin
    # The fixture attaches a stale scale in `mutate!` and runs the setter afterwards.
    sys = nem_toy_system(
        [
            TOY_CHEAP => toy_unit(100.0, [(60.0, 20.0)]; initial = 0.0, ramp_up = 100.0),
            TOY_EXPENSIVE => toy_unit(100.0, [(40.0, 20.0)]; initial = 0.0, ramp_up = 100.0),
        ],
        50.0;
        mutate! = (sys, stamps) -> PSY.add_time_series!(
            sys, PSY.get_component(PSY.ThermalStandard, sys, TOY_CHEAP),
            AustralianElectricityMarkets.single_series("tie_break_scale_7", TOY_START, fill(0.5, length(stamps)), TOY_RESOLUTION),
        ),
    )
    alta = PSY.get_component(PSY.ThermalStandard, sys, TOY_CHEAP)
    @test !PSY.has_time_series(alta, PSY.SingleTimeSeries, "tie_break_scale_7")
    @test PSY.has_time_series(alta, PSY.SingleTimeSeries, "tie_break_scale_1")
end

include("tie_break_validation.jl")

@testset "tie-break scale rows skip devices excluded by the device model's filter_function" begin
    third = "Solitude"
    sys = nem_toy_system(
        [
            TOY_CHEAP => toy_unit(168.0, [(168.0, 10.0)]; initial = 0.0, ramp_up = 100.0),
            TOY_EXPENSIVE => toy_unit(46.0, [(46.0, 10.0), (10.0, 30.0)]; initial = 0.0, ramp_up = 100.0),
            third => toy_unit(122.0, [(122.0, 10.0)]; initial = 0.0, ramp_up = 100.0),
        ],
        168.0,
    )
    # Park City ties with the other two units on band 1 but is filtered out of the model, so its row is left out.
    template = PSI.ProblemTemplate(PSI.NetworkModel(PSI.AreaBalancePowerModel; use_slacks = true))
    set_nem_dispatch_models!(template, sys)
    PSI.set_device_model!(
        template,
        PSI.DeviceModel(
            PSY.ThermalStandard, NEMReplayDispatch;
            attributes = Dict{String, Any}("filter_function" => d -> PSY.get_name(d) != TOY_EXPENSIVE),
        ),
    )
    PSI.set_device_model!(template, PSY.PowerLoad, PSI.StaticPowerLoad)
    model = toy_model(sys; template)
    @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
    container = PSI.get_optimization_container(model)
    key = PSI.ParameterKey(TieBreakScaleParameter, PSY.ThermalStandard, AEMS._tie_break_meta(1, false))
    # Rows are keyed by the time-series UUID of each device's scale series.
    ts_uuid(n) = string(PSI.IS.get_time_series_uuid(PSY.SingleTimeSeries, PSY.get_component(PSY.ThermalStandard, sys, n), "tie_break_scale_1"))
    @test Set(axes(PSI.get_parameter_array(container, key), 1)) == Set(ts_uuid(n) for n in (TOY_CHEAP, third))
end

@testset "a template without the tie-break service model has no tie-break rows" begin
    sys = nem_toy_system(
        [
            TOY_CHEAP => toy_unit(100.0, [(60.0, 20.0)]; initial = 0.0, ramp_up = 100.0),
            TOY_EXPENSIVE => toy_unit(100.0, [(40.0, 20.0)]; initial = 0.0, ramp_up = 100.0),
        ],
        50.0,
    )
    template = PSI.ProblemTemplate(PSI.NetworkModel(PSI.AreaBalancePowerModel; use_slacks = true))
    set_nem_dispatch_models!(template, sys; tie_breaks = false)
    PSI.set_device_model!(template, PSY.PowerLoad, PSI.StaticPowerLoad)
    @test isempty(PSI.get_service_models(template))
    model = toy_model(sys; template)
    @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
    container = PSI.get_optimization_container(model)
    @test !PSI.has_container_key(container, TieBreakSlackUp, EnergyTieBreak, TIE_BREAK_SERVICE_NAME)
    @test !PSI.has_container_key(container, TieBreakConstraint, EnergyTieBreak, TIE_BREAK_SERVICE_NAME)
    jm = PSI.get_jump_model(container)
    @test !any(v -> occursin("TieBreakSlack", PSI.JuMP.name(v)), PSI.JuMP.all_variables(jm))
end

@testset "tie-break rows and slacks are registered under the EnergyTieBreak service" begin
    third = "Solitude"
    sys = nem_toy_system(
        [
            TOY_CHEAP => toy_unit(168.0, [(168.0, 10.0)]; initial = 0.0, ramp_up = 100.0),
            TOY_EXPENSIVE => toy_unit(46.0, [(46.0, 10.0)]; initial = 0.0, ramp_up = 100.0),
            third => toy_unit(122.0, [(122.0, 10.0)]; initial = 0.0, ramp_up = 100.0),
        ],
        168.0,
    )
    out = solve_toy(sys)
    up = PSI.get_variable(out.container, TieBreakSlackUp(), EnergyTieBreak, TIE_BREAK_SERVICE_NAME)
    down = PSI.get_variable(out.container, TieBreakSlackDown(), EnergyTieBreak, TIE_BREAK_SERVICE_NAME)
    rows = PSI.get_constraint(out.container, TieBreakConstraint(), EnergyTieBreak, TIE_BREAK_SERVICE_NAME)
    # Three tied units at one time step: three pairs, one row and two slacks each.
    @test length(rows.data) == 3
    @test sort!(collect(keys(rows.data))) == [("1_offer", k, 1) for k in 1:3]
    @test Set(keys(up.data)) == Set(keys(rows.data)) == Set(keys(down.data))
    @test all(k -> PSI.JuMP.value(up[k...]) + PSI.JuMP.value(down[k...]) < 1.0e-8, keys(rows.data))
end

@testset "set_tie_break_scales! attaches one EnergyTieBreak over the market-bid units" begin
    sys = nem_toy_system(
        [
            TOY_CHEAP => toy_unit(100.0, [(60.0, 20.0)]; initial = 0.0, ramp_up = 100.0),
            TOY_EXPENSIVE => toy_unit(100.0, [(40.0, 30.0)]; initial = 0.0, ramp_up = 100.0),
        ],
        50.0;
        batteries = [TOY_BATTERY => toy_battery(100.0, 10.0, 50.0, 1.0; initial = 0.0, ramp_up = 100.0)],
        tie_break_scales = false,
    )
    service = PSY.get_component(EnergyTieBreak, sys, TIE_BREAK_SERVICE_NAME)
    @test isnothing(service)
    set_tie_break_scales!(sys)
    set_tie_break_scales!(sys)
    services = collect(PSY.get_components(EnergyTieBreak, sys))
    @test length(services) == 1
    # No band ties here; every market-bid unit still contributes, so the build-time checks run.
    contributors = PSY.get_contributing_devices(sys, only(services))
    @test sort!(PSY.get_name.(contributors)) == sort!([TOY_CHEAP, TOY_EXPENSIVE, TOY_BATTERY])
    for device in contributors
        @test count(s -> s isa EnergyTieBreak, PSY.get_services(device)) == 1
    end
end

@testset "tied fixed-curve units with no time-varying curve in their direction fail the build" begin
    fixed(sys, stamps) = for name in (TOY_CHEAP, TOY_EXPENSIVE)
        gen = PSY.get_component(PSY.ThermalStandard, sys, name)
        PSY.set_operation_cost!(
            gen,
            PSY.MarketBidCost(;
                no_load_cost = 0.0, start_up = (hot = 0.0, warm = 0.0, cold = 0.0), shut_down = 0.0,
                incremental_offer_curves = PSY.CostCurve(PSY.PiecewiseIncrementalCurve(0.0, [0.0, 50.0], [20.0])),
            ),
        )
    end
    sys = nem_toy_system(
        [
            TOY_CHEAP => toy_unit(100.0, [(50.0, 20.0)]; initial = 0.0, ramp_up = 100.0),
            TOY_EXPENSIVE => toy_unit(100.0, [(50.0, 20.0)]; initial = 0.0, ramp_up = 100.0),
        ],
        50.0;
        mutate! = fixed,
    )
    template = PSI.ProblemTemplate(PSI.NetworkModel(PSI.AreaBalancePowerModel; use_slacks = true))
    set_nem_dispatch_models!(template, sys)
    PSI.set_device_model!(template, PSY.PowerLoad, PSI.StaticPowerLoad)
    model = toy_model(sys; template)
    status, log = _toy_build_log(model)
    @test status == PSI.ModelBuildStatus.FAILED
    @test occursin(
        "tie-break: 2 unit(s) with fixed offer curves have price-tied bands in a direction where no unit has a " *
            "time-varying offer curve, so set_tie_break_scales! cannot scale them: Alta, Park City.",
        log,
    )
    @test !occursin("Call set_tie_break_scales!(sys)", log)
end

@testset "duals requested on the tie-break service model fail the build" begin
    sys = nem_toy_system(
        [
            TOY_CHEAP => toy_unit(100.0, [(60.0, 20.0)]; initial = 0.0, ramp_up = 100.0),
            TOY_EXPENSIVE => toy_unit(100.0, [(40.0, 20.0)]; initial = 0.0, ramp_up = 100.0),
        ],
        50.0,
    )
    template = PSI.ProblemTemplate(PSI.NetworkModel(PSI.AreaBalancePowerModel; use_slacks = true))
    set_nem_dispatch_models!(template, sys; tie_breaks = false)
    PSI.set_device_model!(template, PSY.PowerLoad, PSI.StaticPowerLoad)
    PSI.set_service_model!(
        template, TIE_BREAK_SERVICE_NAME,
        PSI.ServiceModel(EnergyTieBreak, TieBreakMarket, TIE_BREAK_SERVICE_NAME; duals = [TieBreakConstraint]),
    )
    model = toy_model(sys; template)
    status, log = _toy_build_log(model)
    @test status == PSI.ModelBuildStatus.FAILED
    @test occursin("requests duals TieBreakConstraint, which it does not register", log)
end

@testset "Market Price Cap penalties are priced at build on a non-area-balance network model" begin
    sys = nem_toy_system([TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = 0.0, ramp_up = 100.0)], 50.0)
    template = PSI.ProblemTemplate(PSI.NetworkModel(PSI.AreaPTDFPowerModel; use_slacks = false))
    set_nem_dispatch_models!(template, sys)
    PSI.set_device_model!(template, PSY.PowerLoad, PSI.StaticPowerLoad)
    model = toy_model(sys; template)
    @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
    container = PSI.get_optimization_container(model)
    @test !PSI.has_container_key(container, PSI.SystemBalanceSlackUp, PSY.Area)
    # Each unit ramp slack's price: base power x interval coefficient of its CVP factor x the build-time cap.
    # The JuMP objective is read because building folds the invariant terms into the variant expression.
    expected = PSI.get_base_power(container) * AEMS.interval_cost_coefficient(
        AustralianElectricityMarkets.UNIT_RAMP_CVP_FACTOR * AEMS._container_market_price_cap(container, TOY_START),
        PSI.get_resolution(container),
    )
    objective = PSI.JuMP.objective_function(PSI.get_jump_model(container))
    slack = PSI.get_variable(container, AEMS.UnitRampUpSlack(), PSY.ThermalStandard)
    for t in axes(slack)[2]
        @test PSI.JuMP.coefficient(objective, slack[TOY_CHEAP, t]) ≈ expected
    end
end

@testset "typed storage fixed-loading rows preserve net injection and invocation" begin
    for (target, invoked) in ((20.0, 1.0), (-20.0, 1.0), (20.0, 0.0))
        sys = nem_toy_system(
            [TOY_CHEAP => toy_unit(200.0, [(200.0, 20.0)]; initial = 80.0, ramp_up = 100.0)],
            80.0;
            batteries = [TOY_BATTERY => toy_battery(40.0, 50.0, 40.0, 1.0; initial = 0.0, ramp_up = 100.0)],
            mutate! = function (sys, stamps)
                storage = PSY.get_component(PSY.EnergyReservoirStorage, sys, TOY_BATTERY)
                for (name, value) in (("fixed_load", target / PSY.get_base_power(sys)), ("fixed_load_invoked", invoked))
                    PSY.add_time_series!(sys, storage, PSY.SingleTimeSeries(; name, data = PSY.TimeSeries.TimeArray(stamps, fill(value, length(stamps)))))
                end
                return
            end,
        )
        out = solve_toy(sys)
        net = out.battery_out_mw[TOY_BATTERY] - out.battery_in_mw[TOY_BATTERY]
        @test net ≈ (iszero(invoked) ? 0.0 : target) atol = TOY_TOLERANCE
        container = out.container
        T = PSY.EnergyReservoirStorage
        U = PSI.get_variable(container, PSI.ActivePowerOutVariable(), T)[TOY_BATTERY, 1]
        D = PSI.get_variable(container, PSI.ActivePowerInVariable(), T)[TOY_BATTERY, 1]
        for meta in ("upper", "lower")
            row = PSI.get_constraint(container, AEMS.EnergyFixedLoadConstraint(), T, meta)[TOY_BATTERY, 1]
            @test abs(PSI.JuMP.normalized_coefficient(row, U)) == 1.0
            @test PSI.JuMP.normalized_coefficient(row, U) == -PSI.JuMP.normalized_coefficient(row, D)
        end
    end
end
