function _tie_validation_system(curves_a, curves_b; decremental = false)
    units = decremental ? Pair{String, Any}[] : [
            TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = 0.0, ramp_up = 100.0),
            TOY_EXPENSIVE => toy_unit(100.0, [(100.0, 20.0)]; initial = 0.0, ramp_up = 100.0),
        ]
    loads = decremental ? [name => toy_load(100.0, 20.0; initial = 0.0, ramp_up = 100.0) for name in ("LOAD_A", "LOAD_B")] : Pair{String, Any}[]
    sys = nem_toy_system(units, 0.0; loads, tie_break_scales = false)
    PSY.clear_time_series!(sys)
    names = decremental ? ("LOAD_A", "LOAD_B") : (TOY_CHEAP, TOY_EXPENSIVE)
    T = decremental ? PSY.InterruptiblePowerLoad : PSY.ThermalStandard
    setter! = decremental ? AustralianElectricityMarkets._set_decremental_bid_cost! : AustralianElectricityMarkets._set_incremental_bid_cost!
    for (name, curves) in zip(names, (curves_a, curves_b))
        setter!(sys, PSY.get_component(T, sys, name), (; piecewise_step_data = curves), TOY_START, TOY_RESOLUTION)
    end
    return sys, TOY_START:TOY_RESOLUTION:(TOY_START + (length(curves_a) - 1) * TOY_RESOLUTION)
end

@testset "check_tie_break_pairs compares the tied pairs across the steps" begin
    steps = [TOY_START, TOY_START + TOY_RESOLUTION]
    # The two first bands tie at the first interval only.
    moving = nem_toy_system(
        [
            TOY_CHEAP => toy_unit(100.0, [[(60.0, 20.0)], [(60.0, 25.0)]]; initial = 0.0, ramp_up = 100.0),
            TOY_EXPENSIVE => toy_unit(100.0, [(40.0, 20.0)]; initial = 0.0, ramp_up = 100.0),
        ],
        50.0,
    )
    @test isnothing(check_tie_break_pairs(moving, steps[1:1]))
    @test_throws r"differ from those at" check_tie_break_pairs(moving, steps)
    @test_throws r"is not on the offer curve timestamps" check_tie_break_pairs(moving, [TOY_START + Hour(5)])
end

@testset "tie-pair validation preserves fallback and band eligibility" begin
    function curve(prices, widths = fill(50.0, length(prices)))
        return PSY.PiecewiseStepData([0.0; cumsum(widths)], prices)
    end
    for decremental in (false, true)
        cases = [
            ([curve([20.0]), curve([25.0])], [curve([20.0]), curve([25.0])], true),
            ([curve([20.0]), curve([20.0], [0.0])], [curve([20.0]), curve([20.0], [25.0])], true),
            ([curve([20.0, 100.0], [50.0, 0.0]), curve([20.0, 200.0], [50.0, 0.0])], [curve([20.0]), curve([20.0])], true),
            ([curve([20.0, 30.0]), curve([20.0])], [curve([30.0]), curve([30.0])], false),
            ([curve([20.0]), curve([20.0, 30.0])], [curve([30.0]), curve([30.0])], false),
            ([curve([20.0]), curve([20.0, 100.0], [50.0, 0.0])], [curve([20.0]), curve([20.0])], true),
        ]
        for (a, b, accepted) in cases
            sys, steps = _tie_validation_system(a, b; decremental)
            if accepted
                @test isnothing(check_tie_break_pairs(sys, steps))
            else
                @test_throws r"differ from those at" check_tie_break_pairs(sys, steps)
            end
        end
        sys, steps = _tie_validation_system([curve([20.0]), curve([30.0]), curve([30.0])], fill(curve([30.0]), 3); decremental)
        @test isnothing(check_tie_break_pairs(sys, steps[2:3]))
        @test_throws r"differ from those at" check_tie_break_pairs(sys, steps)
        @test_throws r"is not on the offer curve timestamps" check_tie_break_pairs(sys, [first(steps), last(steps) + Hour(5)])
    end
    sys, steps = _tie_validation_system(
        [curve([20.0, 20.0 + 2.0e-6]), curve([20.0, 20.0 + 0.75e-6])],
        fill(curve([20.0 + 1.5e-6]), 2),
    )
    @test_throws r"transitive ties are not supported" check_tie_break_pairs(sys, steps)
end

@testset "unchanged prices do not allocate pair sets for every interval" begin
    curve = PSY.PiecewiseStepData(collect(0.0:10.0:100.0), fill(20.0, 10))
    sys, steps = _tie_validation_system(fill(curve, 288), fill(curve, 288))
    check_tie_break_pairs(sys, steps[1:1])
    check_tie_break_pairs(sys, steps)
    short_bytes = @allocated check_tie_break_pairs(sys, steps[1:1])
    full_bytes = @allocated check_tie_break_pairs(sys, steps)
    @test full_bytes <= 3 * short_bytes + 256 * 1024
end
