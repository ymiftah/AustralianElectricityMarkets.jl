function offered_band_system(; bands = [(40.0, 20.0)], target = 60.0, weight = 1160.0, max_avail = 100.0)
    return nem_toy_system(
        [
            TOY_CHEAP => toy_unit(100.0, bands; initial = 60.0, ramp_up = 100.0, availability = max_avail),
            TOY_EXPENSIVE => toy_unit(200.0, [(200.0, 80.0)]; initial = 20.0, ramp_up = 100.0),
        ],
        80.0; horizon = TOY_RESOLUTION,
        mutate! = function (sys, stamps)
            add_toy_generic_constraint!(sys, stamps, TOY_CHEAP, target; sense = ConstraintSense.EQ)
            only(PSY.get_components(GenericConstraint, sys)).constraint_weight = weight
            return
        end,
    )
end

@testset "custom nonzero first breakpoints retain their dispatch offset" begin
    for target in (45.0, 0.0)
        sys = nem_toy_system(
            [
                TOY_CHEAP => toy_unit(100.0, [(40.0, 20.0)]; initial = 10.0, ramp_up = 100.0),
                TOY_EXPENSIVE => toy_unit(100.0, [(100.0, 80.0)]; initial = 20.0, ramp_up = 100.0),
            ],
            80.0;
            mutate! = function (sys, stamps)
                cheap = PSY.get_component(PSY.ThermalStandard, sys, TOY_CHEAP)
                PSY.remove_time_series!(sys, PSY.SingleTimeSeries, cheap, "variable_cost")
                PSY.remove_time_series!(sys, PSY.SingleTimeSeries, cheap, "incremental_initial_input")
                curve = PSY.PiecewiseStepData([10.0, 50.0], [20.0])
                AustralianElectricityMarkets._set_incremental_bid_cost!(sys, cheap, (piecewise_step_data = fill(curve, length(stamps)),), TOY_START, TOY_RESOLUTION)
                add_toy_generic_constraint!(sys, stamps, TOY_CHEAP, target; sense = ConstraintSense.EQ)
                only(PSY.get_components(GenericConstraint, sys)).constraint_weight = 1160.0
                return
            end,
        )
        out = solve_toy(sys; generic_slacks = true)
        @test out.dispatch_mw[TOY_CHEAP] ≈ target atol = 1.0e-6
        @test out.band_mw[(TOY_CHEAP, 1)] ≈ max(target - 10.0, 0.0) atol = 1.0e-6
        rows = filter(:family => ==("energy_offer"), AEMS._constraint_violations(out.results, sys))
        if target == 0.0
            @test only(rows.MW) ≈ 10.0 atol = 1.0e-6
            @test only(rows.direction) == "down"
        else
            @test isempty(rows)
        end
    end
end

@testset "non-conformance may exceed the total offered energy bands" begin
    sys = offered_band_system()
    out = solve_toy(sys; generic_slacks = true)
    @test out.dispatch_mw[TOY_CHEAP] ≈ 60.0 atol = 1.0e-6
    @test out.band_mw[(TOY_CHEAP, 1)] ≈ 40.0 atol = 1.0e-6
    rows = filter(:family => ==("energy_offer"), AEMS._constraint_violations(out.results, sys))
    @test only(rows.MW) ≈ 20.0 atol = 1.0e-6
    @test only(rows.direction) == "up"
    expected = (40.0 * 20.0 + 20.0 * 80.0 + 20.0 * 1135.0 * 17500.0) * interval_hours(DISPATCH_INTERVAL)
    @test out.objective ≈ expected atol = 1.0e-4
end

@testset "total-band priority and cumulative availability penalties" begin
    for (weight, availability, expected) in ((1130.0, 100.0, 40.0), (1160.0, 30.0, 40.0), (1600.0, 30.0, 60.0))
        sys = offered_band_system(; weight, max_avail = availability)
        out = solve_toy(sys; generic_slacks = true)
        @test out.dispatch_mw[TOY_CHEAP] ≈ expected atol = 1.0e-6
    end
end

@testset "zero total offered quantity remains an elastic boundary" begin
    sys = offered_band_system(; bands = [(0.0, 20.0)])
    out = solve_toy(sys; generic_slacks = true)
    @test out.dispatch_mw[TOY_CHEAP] ≈ 60.0 atol = 1.0e-6
    @test only(filter(:family => ==("energy_offer"), AEMS._constraint_violations(out.results, sys)).MW) ≈ 60.0 atol = 1.0e-6
end

@testset "recurrent offered-band widths update step by step" begin
    sys = offered_band_system(; bands = [[(40.0, 20.0)], [(80.0, 20.0)]])
    out = run_replication(sys, TOY_START:TOY_RESOLUTION:(TOY_START + TOY_RESOLUTION); optimizer = optimizer_with_attributes(HiGHS.Optimizer, "output_flag" => false))
    rows = filter(:family => ==("energy_offer"), AEMS._constraint_violations(out.results, sys))
    @test nrow(rows) == 1
    @test only(rows.MW) ≈ 20.0 atol = 1.0e-6
    @test only(rows.DateTime) == TOY_START
end

@testset "scheduled-load and both storage energy directions have elastic offer totals" begin
    for (kind, target) in ((:load, 60.0), (:storage_gen, 60.0), (:storage_load, -60.0))
        name = kind == :load ? "LD1" : TOY_BATTERY
        sys = nem_toy_system(
            [TOY_CHEAP => toy_unit(200.0, [(200.0, 20.0)]; initial = 80.0, ramp_up = 100.0)],
            80.0; horizon = TOY_RESOLUTION,
            loads = kind == :load ? [name => toy_load(40.0, 1.0; initial = 0.0, ramp_up = 100.0, availability = 100.0)] : Pair{String, Any}[],
            batteries = kind == :load ? Pair{String, Any}[] : [name => toy_battery(40.0, 50.0, 40.0, 1.0; initial = 0.0, ramp_up = 100.0, gen_avail = 100.0, load_avail = 100.0)],
            mutate! = function (sys, stamps)
                device = PSY.get_component(kind == :load ? PSY.InterruptiblePowerLoad : PSY.EnergyReservoirStorage, sys, name)
                gc = GenericConstraint(; name = "NC_OFFER", sense = ConstraintSense.EQ, rhs = target / PSY.get_base_power(sys), terms = ConstraintTerm[UnitTerm(name, BidType.ENERGY, 1.0)])
                gc.constraint_weight = 1160.0
                PSY.add_service!(sys, gc, [device])
                for (key, value) in (("rhs", target / PSY.get_base_power(sys)), ("invoked", 1.0))
                    PSY.add_time_series!(sys, gc, PSY.SingleTimeSeries(; name = key, data = PSY.TimeSeries.TimeArray(stamps, fill(value, length(stamps)))))
                end
                return
            end,
        )
        out = solve_toy(sys; generic_slacks = true)
        actual = kind == :load ? out.load_mw[name] : out.dispatch_mw[name]
        @test actual ≈ target atol = 1.0e-6
        rows = filter(:family => ==("energy_offer"), AEMS._constraint_violations(out.results, sys))
        @test only(rows.MW) ≈ 20.0 atol = 1.0e-6
        @test only(rows.name) == name
    end
end
