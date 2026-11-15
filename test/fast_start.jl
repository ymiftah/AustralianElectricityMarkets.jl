const _FS = AustralianElectricityMarkets
_fs_profile(t1, t2, t3, t4) = _FS.FastStartProfile((Float64(t1), Float64(t2), Float64(t3), Float64(t4)))
_fs_end(mode, time, since = nothing) = _FS.FastStartEndState(mode, Float64(time), since)

@testset "is_fast_start: a profile with a positive time" begin
    @test !_FS.is_fast_start(nothing)
    @test !_FS.is_fast_start(_fs_profile(0, 0, 0, 0))
    @test _FS.is_fast_start(_fs_profile(0, 0, 0, 1))
    @test _FS.is_fast_start(_fs_profile(2, 3, 4, 5))
end

@testset "fast_start_time_in_mode caps the published mode time at the mode's length" begin
    p = _fs_profile(2, 3, 4, 5)
    @test _FS.fast_start_time_in_mode(0, 7.0, p) == 0.0
    @test _FS.fast_start_time_in_mode(1, 7.0, p) == 2.0
    @test _FS.fast_start_time_in_mode(2, 1.5, p) == 1.5
    @test _FS.fast_start_time_in_mode(3, 4.0, p) == 4.0
    @test _FS.fast_start_time_in_mode(4, 99.0, p) == 5.0
    @test isnan(_FS.fast_start_time_in_mode(3, NaN, p))
    @test _FS.fast_start_time_in_mode(0, NaN, p) == 0.0
    @test _FS.fast_start_time_in_mode(2, 7.0, nothing) == 0.0
    @test _FS.fast_start_time_in_mode(2, 7.0, _fs_profile(0, 0, 0, 0)) == 0.0
    @test_throws ArgumentError _FS.fast_start_mode_length(p, 5)
end

# The cases follow nempy's `UnitData._update_modes` step by step: commit above 0.0 MW, then modes 1, 2 and 3
# advance once each while `T_k - time_in_mode < time_left`, mode 0 ends at 0 minutes and mode 4 is capped at T4.
@testset "fast_start_end_state follows nempy's _update_modes" begin
    p = _fs_profile(2, 3, 4, 5)
    @testset "commitment from mode 0" begin
        @test _FS.fast_start_end_state(0, 0.0, p, 0.0) == _fs_end(0, 0.0)
        @test _FS.fast_start_end_state(0, 0.0, p, -5.0) == _fs_end(0, 0.0)
        @test _FS.fast_start_end_state(0, 0.0, p, NaN) == _fs_end(0, 0.0)
        # Any positive target commits: nempy has no threshold.
        @test _FS.fast_start_end_state(0, 0.0, p, 1.0e-9) == _fs_end(2, 3.0)
        @test _FS.fast_start_end_state(0, 0.0, p, 10.0) == _fs_end(2, 3.0)
        # The run-1 target does not matter once committed.
        @test _FS.fast_start_end_state(2, 1.0, p, 0.0; interval_minutes = 2.0) == _fs_end(2, 3.0)
    end
    @testset "an exact segment end stays in the mode" begin
        @test _FS.fast_start_end_state(1, 0.0, p, 1.0; interval_minutes = 2.0) == _fs_end(1, 2.0)
        @test _FS.fast_start_end_state(2, 1.0, p, 1.0; interval_minutes = 2.0) == _fs_end(2, 3.0)
        @test _FS.fast_start_end_state(3, 3.0, p, 1.0; interval_minutes = 1.0) == _fs_end(3, 4.0)
    end
    @testset "a segment end passed moves to the next mode" begin
        @test _FS.fast_start_end_state(1, 2.0, p, 0.0; interval_minutes = 1.0) == _fs_end(2, 1.0)
        @test _FS.fast_start_end_state(2, 3.0, p, 0.0; interval_minutes = 1.0) == _fs_end(3, 1.0, 1.0)
        @test _FS.fast_start_end_state(3, 4.0, p, 0.0; interval_minutes = 1.0) == _fs_end(4, 1.0)
    end
    @testset "mode 4 is capped at T4 and never returns to mode 0" begin
        @test _FS.fast_start_end_state(4, 4.0, p, 0.0) == _fs_end(4, 5.0)
        @test _FS.fast_start_end_state(4, 5.0, p, 0.0) == _fs_end(4, 5.0)
        @test _FS.fast_start_end_state(4, 0.0, p, 0.0) == _fs_end(4, 5.0)
    end
    @testset "zero-length segments are crossed at once" begin
        z = _fs_profile(0, 2, 0, 3)
        @test _FS.fast_start_end_state(1, 0.0, z, 1.0; interval_minutes = 2.0) == _fs_end(2, 2.0)
        @test _FS.fast_start_end_state(1, 0.0, z, 1.0) == _fs_end(4, 3.0, 3.0)
        @test _FS.fast_start_end_state(2, 1.0, z, 1.0; interval_minutes = 1.0) == _fs_end(2, 2.0)
        @test _FS.fast_start_end_state(0, 0.0, _fs_profile(0, 0, 0, 5), 1.0) == _fs_end(4, 5.0, 5.0)
        # T2 = 0: the unit never ends in mode 2.
        @test _FS.fast_start_end_state(1, 0.0, _fs_profile(1, 0, 1, 1), 1.0; interval_minutes = 2.0) == _fs_end(3, 1.0, 1.0)
    end
    @testset "a unit crossing modes 2 and 3 keeps its time since the end of mode 2" begin
        @test _FS.fast_start_end_state(1, 0.0, _fs_profile(1, 1, 1, 10), 0.0) == _fs_end(4, 2.0, 3.0)
    end
    @test_throws ArgumentError _FS.fast_start_end_state(5, 0.0, p, 1.0)
    @test_throws ArgumentError _FS.fast_start_end_state(-1, 0.0, p, 1.0)
end

# nempy's `SpotMarket.set_fast_start_constraints` doctest: A to E end in modes 0 to 4 and its rows are
# A <= 0, B <= 0, C = 17.5, D >= 50, E >= 30.
@testset "fast_start_envelope reproduces nempy's set_fast_start_constraints doctest" begin
    units = (
        (mode = 0, time = 4.0, t2 = 7.0, t4 = 10.0, m = 30.0, bounds = (0.0, 0.0)),
        (mode = 1, time = 5.0, t2 = 4.0, t4 = 10.0, m = 40.0, bounds = (0.0, 0.0)),
        (mode = 2, time = 5.0, t2 = 10.0, t4 = 20.0, m = 35.0, bounds = (17.5, 17.5)),
        (mode = 3, time = 12.0, t2 = 8.0, t4 = 8.0, m = 50.0, bounds = (50.0, Inf)),
        (mode = 4, time = 10.0, t2 = 6.0, t4 = 20.0, m = 60.0, bounds = (30.0, Inf)),
    )
    for u in units
        envelope = _FS.fast_start_envelope(_fs_end(u.mode, u.time), _fs_profile(1, u.t2, 1, u.t4), u.m)
        @test (envelope.lower, envelope.upper) == u.bounds
        @test envelope.ramp == (u.mode <= 2 ? :none : :standard)
    end
end

@testset "fast_start_envelope guards zero T2 and T4" begin
    @test _FS.fast_start_envelope(_fs_end(2, 0.0), _fs_profile(1, 0, 1, 1), 20.0).lower == 20.0
    envelope = _FS.fast_start_envelope(_fs_end(4, 0.0), _fs_profile(1, 1, 1, 0), 20.0)
    @test (envelope.lower, envelope.upper) == (0.0, Inf)
    @test _FS.fast_start_envelope(_fs_end(4, 5.0), _fs_profile(2, 3, 4, 5), 20.0).lower == 0.0
end

# nempy's `_adjust_ramp_rates_of_units_ending_in_mode_three_and_four`: the ramp-up limit is
# `min_loading + time_since_end_of_mode_two x rate`, here MORTLK11's profile (10/2/40/7 minutes, 20 MW, 780 MW/h).
@testset "a unit leaving mode 2 ramps up from its minimum loading" begin
    profile = _fs_profile(10, 2, 40, 7)
    @test _FS.fast_start_end_state(1, 5.0, profile, 0.0) == _fs_end(1, 10.0)
    state = _FS.fast_start_end_state(1, 10.0, profile, 0.0)
    @test state == _fs_end(3, 3.0, 3.0)
    envelope = _FS.fast_start_envelope(state, profile, 20.0)
    @test (envelope.lower, envelope.upper) == (20.0, Inf)
    @test envelope.ramp == :from_minimum_load
    @test (envelope.ramp_base, envelope.ramp_minutes) == (20.0, 3.0)
    @test _FS.fast_start_ramp_up_limit(envelope, 17.0, 780.0 / 60) ≈ 59.0

    crossed = _FS.fast_start_envelope(_FS.fast_start_end_state(1, 0.0, _fs_profile(1, 1, 1, 10), 0.0), _fs_profile(1, 1, 1, 10), 20.0)
    @test crossed.ramp == :from_minimum_load
    @test crossed.lower ≈ 16.0
    @test crossed.ramp_minutes == 3.0

    standard = _FS.fast_start_envelope(_FS.fast_start_end_state(3, 4.0, _fs_profile(2, 3, 4, 5), 0.0), _fs_profile(2, 3, 4, 5), 20.0)
    @test standard.ramp == :standard
    @test _FS.fast_start_ramp_up_limit(standard, 17.0, 2.0) == 27.0
    @test _FS.fast_start_ramp_up_limit(_FS.fast_start_envelope(_fs_end(2, 1.0), _fs_profile(2, 3, 4, 5), 20.0), 17.0, 2.0) == Inf
end

@testset "fast_start_ramp_exempt: fast-start units starting in modes 0 to 2" begin
    for mode in 0:4
        @test _FS.fast_start_ramp_exempt(_FS.NEMUnitState(0.0, mode), true) == (mode <= 2)
        @test !_FS.fast_start_ramp_exempt(_FS.NEMUnitState(0.0, mode), false)
    end
    @test _FS.FAST_START_CVP_FACTOR == 1130.0
end

@testset "nem_system writes the fast-start state of a unit with a fast-start profile" begin
    hive = mktempdir()
    create_mock_data(hive; complete_inputs = true)
    write_mock_interconnector_results(hive)
    db = aem_connect(HiveConfiguration(hive_location = hive))
    interval = DateTime(2025, 1, 1, 0, 5):Minute(5):DateTime(2025, 1, 1, 0, 20)
    sys = nem_system(db, NEMDEConfiguration(); date_range = interval)
    bw04 = get_component(Device, sys, "BW04")
    @test _FS.has_fast_start_profile(bw04)
    observed = _FS.get_observed_state(bw04)
    # DISPATCHMODETIME of the previous interval, as published.
    @test get_time_series_values(SingleTimeSeries, bw04, PowerSystems.get_name(observed.dispatch_mode_time); ignore_scaling_factors = true) == [0.0, 0.0, 7.0]
    states = _FS.observed_unit_states(bw04, collect(interval)[1:(end - 1)])
    # In mode 4 at 00:10, so it starts 00:15 in mode 4; its zero T4 caps the 7 minutes to 0.
    @test [s.dispatch_mode for s in states] == [0, 0, 4]
    @test [s.time_in_mode for s in states] == [0.0, 0.0, 0.0]
    inputs = _FS.fast_start_unit_inputs(bw04, first(interval), 3)
    @test all(i -> i.fast_start, inputs)
    @test [i.start_mode for i in inputs] == [0, 0, 4]
    @test [i.time_in_mode for i in inputs] == [0.0, 0.0, 0.0]
    @test all(i -> i.profile == _fs_profile(10, 0, 0, 0) && i.side == _FS.OfferSide.GEN, inputs)
    for name in ("BW01", "BW02")
        device = get_component(Device, sys, name)
        @test !_FS.has_fast_start_profile(device)
        @test !has_time_series(device, SingleTimeSeries, _FS.NEM_FAST_START_SERIES.start_mode)
        @test_throws ArgumentError _FS.fast_start_unit_inputs(device, first(interval), 1)
    end
end
