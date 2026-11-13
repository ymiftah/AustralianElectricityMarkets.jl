# The forecast windows of a NEMDE System, its replay intervals, and the date-range rules of `nem_system`.
# Runs on the mock replay hive; the rule `_check_replay_range` is also called on bare ranges.

const _RG_HIVE = mktempdir()
create_mock_data(_RG_HIVE; complete_inputs = true)
write_mock_interconnector_results(_RG_HIVE)

@testset "replay_intervals and the forecast windows of a NEMDE System" begin
    db = aem_connect(HiveConfiguration(hive_location = _RG_HIVE))
    t = DateTime(2025, 1, 1, 0, 5)
    sys = nem_system(db, NEMDEConfiguration(); date_range = t:Minute(5):(t + Minute(20)))
    @test PowerSystems.get_time_series_counts(sys).forecast_count > 0
    @test replay_intervals(sys) == collect(t:Minute(5):(t + Minute(10)))
    @test_throws ArgumentError nem_system(db, NEMDEConfiguration(); date_range = t:Minute(5):(t + Minute(5)))
    @test_throws ArgumentError replay_intervals(PowerSystems.System(100.0))

    directory = mktempdir()
    try
        on_disk = nem_system(
            db, NEMDEConfiguration(); date_range = t:Minute(5):(t + Minute(20)),
            time_series_in_memory = false, time_series_directory = directory,
        )
        @test PowerSystems.get_time_series_counts(on_disk).forecast_count > 0
        @test replay_intervals(on_disk) == collect(t:Minute(5):(t + Minute(10)))
    finally
        rm(directory; recursive = true, force = true)
    end
end

@testset "the replay date-range rules" begin
    check = AustralianElectricityMarkets.RegionModel._check_replay_range
    day(a, b) = a:Minute(5):(b + Minute(10))

    @test check(day(DateTime(2026, 6, 4, 4, 5), DateTime(2026, 6, 5, 4, 0))) === nothing      # trailing stamps cross 04:00
    @test_throws ArgumentError check(day(DateTime(2026, 6, 4, 4, 0), DateTime(2026, 6, 4, 4, 5)))   # crosses trading day
    @test check(day(DateTime(2026, 6, 30, 4, 5), DateTime(2026, 7, 1, 0, 0))) === nothing
    @test_throws ArgumentError check(day(DateTime(2026, 6, 30, 23, 55), DateTime(2026, 7, 1, 0, 5))) # crosses financial year

    @test check(DateTime(2026, 6, 4, 4, 5):Minute(5):DateTime(2026, 6, 4, 4, 15)) === nothing      # three stamps, one interval
    @test_throws ArgumentError check(DateTime(2026, 6, 4, 4, 5):Minute(5):DateTime(2026, 6, 4, 4, 10)) # two stamps
    @test_throws ArgumentError check(DateTime(2026, 6, 4, 4, 5):Minute(10):DateTime(2026, 6, 4, 4, 25)) # not five minutes
end
