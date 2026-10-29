function storage_availability_system(; target = 60.0, weight = 1160.0, initial = 0.0, gen = 40.0, load = 30.0, down = 100.0, up = 100.0)
    return nem_toy_system(
        [TOY_CHEAP => toy_unit(200.0, [(200.0, 20.0)]; initial = 80.0, ramp_up = 100.0)],
        80.0; horizon = TOY_RESOLUTION,
        batteries = [TOY_BATTERY => toy_battery(100.0, 50.0, 100.0, 1.0; initial, ramp_up = up, ramp_down = down, gen_avail = gen, load_avail = load)],
        mutate! = function (sys, stamps)
            isnothing(target) && return
            battery = PSY.get_component(PSY.EnergyReservoirStorage, sys, TOY_BATTERY)
            gc = GenericConstraint(; name = "NC_STORAGE", sense = ConstraintSense.EQ, rhs = first(target) / PSY.get_base_power(sys), terms = ConstraintTerm[UnitTerm(TOY_BATTERY, BidType.ENERGY, 1.0)])
            gc.constraint_weight = weight
            PSY.add_service!(sys, gc, [battery])
            for (name, values) in (("rhs", _toy_values(target, length(stamps)) ./ PSY.get_base_power(sys)), ("invoked", ones(length(stamps))))
                PSY.add_time_series!(sys, gc, PSY.SingleTimeSeries(; name, data = PSY.TimeSeries.TimeArray(stamps, values)))
            end
            return
        end,
    )
end

@testset "storage conformance can exceed either raw directional availability" begin
    for (target, expected, direction) in ((60.0, 20.0, "up"), (-50.0, 20.0, "down"))
        sys = storage_availability_system(; target)
        out = solve_toy(sys; generic_slacks = true)
        @test out.dispatch_mw[TOY_BATTERY] ≈ target atol = 1.0e-6
        violations = ReplayResults._constraint_violations(out.results, sys)
        rows = filter(r -> r.family == "energy_max_avail" && r.name == TOY_BATTERY, violations)
        @test nrow(rows) == 1
        @test only(rows.MW) ≈ expected atol = 1.0e-6
        @test only(rows.direction) == direction
        @test !any(==("generic_constraint"), violations.family)
    end
end

@testset "ramp conflicts retain and price the original storage availability" begin
    for (initial, gen, load, target) in ((60.0, 40.0, 30.0, 60.0), (-50.0, 40.0, 30.0, -50.0))
        sys = storage_availability_system(; target = nothing, initial, gen, load, up = 0.0, down = 0.0)
        out = solve_toy(sys; generic_slacks = true)
        @test out.dispatch_mw[TOY_BATTERY] ≈ target atol = 1.0e-6
        rows = filter(r -> r.family == "energy_max_avail" && r.name == TOY_BATTERY, ReplayResults._constraint_violations(out.results, sys))
        @test only(rows.MW) ≈ 20.0 atol = 1.0e-6
        energy_cost = ((80.0 - target) * 20.0 + (target > 0 ? target * 50.0 : target)) * interval_hours(DISPATCH_INTERVAL)
        penalty = 20.0 * 370.0 * 17500.0 / 12
        @test out.objective ≈ energy_cost + penalty atol = 1.0e-4
        @test out.storage_ramp_slack_mw.up ≈ 0.0 atol = 1.0e-6
        @test out.storage_ramp_slack_mw.down ≈ 0.0 atol = 1.0e-6
    end
end

@testset "storage availability outranks a lower-priority instruction" begin
    sys = storage_availability_system(; target = 60.0, weight = 360.0)
    out = solve_toy(sys; generic_slacks = true)
    @test out.dispatch_mw[TOY_BATTERY] ≈ 40.0 atol = 1.0e-6
    @test !any(==("energy_max_avail"), ReplayResults._constraint_violations(out.results, sys).family)
end

@testset "storage availability parameters update step by step" begin
    sys = storage_availability_system(; target = [60.0, -50.0], gen = [40.0, 80.0], load = [70.0, 30.0])
    out = run_replication(sys, TOY_START:TOY_RESOLUTION:(TOY_START + TOY_RESOLUTION); optimizer = optimizer_with_attributes(HiGHS.Optimizer, "output_flag" => false))
    rows = filter(r -> r.family == "energy_max_avail" && r.name == TOY_BATTERY, ReplayResults._constraint_violations(out.results, sys))
    sort!(rows, :DateTime)
    @test rows.MW ≈ [20.0, 20.0] atol = 1.0e-6
    @test rows.direction == ["up", "down"]
    @test rows.DateTime == [TOY_START, TOY_START + TOY_RESOLUTION]
end

@testset "unused crossed storage bands cannot create unpriced circulation" begin
    sys = nem_toy_system(
        [TOY_CHEAP => toy_unit(200.0, [(200.0, 20.0)]; initial = 80.0, ramp_up = 100.0)], 80.0;
        batteries = [TOY_BATTERY => toy_battery(100.0, -1000.0, 100.0, 0.0; initial = 0.0, ramp_up = 100.0, gen_avail = 0.0, load_avail = 100.0)],
    )
    out = solve_toy(sys)
    @test out.battery_out_mw[TOY_BATTERY] ≈ 0.0 atol = 1.0e-6
    @test out.battery_in_mw[TOY_BATTERY] ≈ 0.0 atol = 1.0e-6
    @test !any(==("energy_max_avail"), ReplayResults._constraint_violations(out.results, sys).family)
end

@testset "storage raw availability is complete and finite" begin
    for key in ("energy_max_avail", "energy_max_avail_decremental")
        sys = storage_availability_system()
        battery = PSY.get_component(PSY.EnergyReservoirStorage, sys, TOY_BATTERY)
        PSY.remove_time_series!(sys, PSY.DeterministicSingleTimeSeries, battery, key)
        PSY.remove_time_series!(sys, PSY.SingleTimeSeries, battery, key)
        @test_throws ArgumentError check_dispatch_envelope(sys, replication_template(sys), TOY_START, 1)
    end
    for bad in (NaN, Inf, -1.0)
        sys = storage_availability_system(; gen = bad)
        @test_throws ArgumentError check_dispatch_envelope(sys, replication_template(sys), TOY_START, 1)
    end
end
