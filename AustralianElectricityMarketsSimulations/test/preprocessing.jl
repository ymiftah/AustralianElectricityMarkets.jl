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
