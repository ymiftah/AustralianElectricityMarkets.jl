@testset "resolve_rebids" begin
    bids = DataFrame(
        DUID = ["A", "A", "B"],
        BIDTYPE = ["ENERGY", "ENERGY", "ENERGY"],
        DIRECTION = ["GEN", "GEN", "GEN"],
        VERSIONNO = [1, 2, 3],
        BANDAVAIL1 = [10.0, 20.0, 5.0],
    )
    resolved = resolve_rebids(bids)
    @test nrow(resolved) == 2
    @test only(resolved[resolved.DUID .== "A", :BANDAVAIL1]) == 20.0
end

@testset "energy_bounds" begin
    # Ramp is the binding limit: 50 MW start, 120 MW/hr -> ±10 MW over 5 minutes.
    b = energy_bounds(;
        initial_mw = 50.0, ramp_up_rate = 120.0, ramp_down_rate = 120.0,
        max_avail = 200.0, min_load = 0.0, uigf = nothing, is_semi_scheduled = false,
    )
    @test b.upper ≈ 60.0
    @test b.lower ≈ 40.0

    # MAXAVAIL clips below the ramp ceiling.
    b2 = energy_bounds(;
        initial_mw = 50.0, ramp_up_rate = 120.0, ramp_down_rate = 120.0,
        max_avail = 55.0, min_load = 0.0, uigf = nothing, is_semi_scheduled = false,
    )
    @test b2.upper ≈ 55.0

    # UIGF is always the ceiling for semi-scheduled units, regardless of SEMIDISPATCHCAP.
    b3 = energy_bounds(;
        initial_mw = 50.0, ramp_up_rate = 1200.0, ramp_down_rate = 1200.0,
        max_avail = 200.0, min_load = 0.0, uigf = 30.0, is_semi_scheduled = true,
    )
    @test b3.upper ≈ 30.0

    # Minimum load floors an online unit.
    b4 = energy_bounds(;
        initial_mw = 50.0, ramp_up_rate = 1200.0, ramp_down_rate = 1200.0,
        max_avail = 200.0, min_load = 45.0, uigf = nothing, is_semi_scheduled = false,
    )
    @test b4.lower ≈ 45.0

    # Bounds never invert.
    b5 = energy_bounds(;
        initial_mw = 0.0, ramp_up_rate = 0.0, ramp_down_rate = 0.0,
        max_avail = 100.0, min_load = 40.0, uigf = nothing, is_semi_scheduled = false,
    )
    @test b5.lower <= b5.upper
end

@testset "scale_trapezium" begin
    raw = FCASTrapezium(;
        enablement_min = 20.0, low_breakpoint = 40.0, high_breakpoint = 80.0,
        enablement_max = 100.0, max_avail = 20.0,
    )

    # No scaling applies: effective == offered.
    eff = scale_trapezium(raw; uigf = nothing, agc_ramp_mw = nothing, is_regulation = false)
    @test eff.enablement_max == 100.0
    @test eff.high_breakpoint == 80.0
    @test eff.max_avail == 20.0
    @test lower_slope_coeff(eff) ≈ (40.0 - 20.0) / 20.0
    @test upper_slope_coeff(eff) ≈ (100.0 - 80.0) / 20.0

    # UIGF below enablement_max pulls the ceiling in and pivots high_breakpoint with it,
    # preserving the upper slope.
    eff_uigf = scale_trapezium(raw; uigf = 90.0, agc_ramp_mw = nothing, is_regulation = false)
    @test eff_uigf.enablement_max ≈ 90.0
    @test eff_uigf.high_breakpoint ≈ 70.0
    @test upper_slope_coeff(eff_uigf) ≈ upper_slope_coeff(eff)

    # UIGF above enablement_max is not binding.
    @test scale_trapezium(raw; uigf = 150.0, agc_ramp_mw = nothing, is_regulation = false).enablement_max == 100.0

    # Regulation is capped by the telemetered AGC ramp; breakpoints pivot inward.
    eff_agc = scale_trapezium(raw; uigf = nothing, agc_ramp_mw = 10.0, is_regulation = true)
    @test eff_agc.max_avail ≈ 10.0
    @test eff_agc.low_breakpoint ≈ 30.0
    @test eff_agc.high_breakpoint ≈ 90.0

    # AGC ramp does not scale contingency services.
    @test scale_trapezium(raw; uigf = nothing, agc_ramp_mw = 10.0, is_regulation = false).max_avail == 20.0

    # Zero max_avail yields zero slopes rather than a division by zero.
    flat = FCASTrapezium(;
        enablement_min = 20.0, low_breakpoint = 40.0, high_breakpoint = 80.0,
        enablement_max = 100.0, max_avail = 0.0,
    )
    eff_flat = scale_trapezium(flat; uigf = nothing, agc_ramp_mw = nothing, is_regulation = false)
    @test lower_slope_coeff(eff_flat) == 0.0
    @test upper_slope_coeff(eff_flat) == 0.0
end
