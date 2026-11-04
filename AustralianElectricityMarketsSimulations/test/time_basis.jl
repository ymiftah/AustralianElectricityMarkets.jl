@testset "interval_hours" begin
    @test interval_hours(DISPATCH_INTERVAL) ≈ 5 / 60
end

@testset "interval_cost_coefficient" begin
    # 300 $/MWh over 5/60 h -> 25 $/MW; over 30 min -> 150 $/MW.
    @test interval_cost_coefficient(300.0) ≈ 25.0
    @test interval_cost_coefficient(300.0, Minute(30)) ≈ 150.0
end

@testset "trading_day_steps" begin
    steps = trading_day_steps(Date(2026, 1, 1))
    @test length(steps) == 288
    @test first(steps) == DateTime(2026, 1, 1, 4, 5)
    @test last(steps) == DateTime(2026, 1, 2, 4, 0)
    @test trading_day_steps(Date(2026, 6, 30)) == DateTime(2026, 6, 30, 4, 5):Minute(5):DateTime(2026, 7, 1, 4)
end

@testset "replay_chunks" begin
    chunks = replay_chunks
    @test chunks(DateTime(2026, 1, 1, 3, 55):Minute(5):DateTime(2026, 1, 1, 4, 15); chunk = :trading_day) ==
        [DateTime(2026, 1, 1, 3, 55):Minute(5):DateTime(2026, 1, 1, 4, 0), DateTime(2026, 1, 1, 4, 5):Minute(5):DateTime(2026, 1, 1, 4, 15)]
    @test chunks(DateTime(2026, 1, 1, 4, 5):Minute(5):DateTime(2026, 1, 2, 4, 0); chunk = :trading_day) ==
        [DateTime(2026, 1, 1, 4, 5):Minute(5):DateTime(2026, 1, 2, 4, 0)]
    @test chunks(DateTime(2026, 6, 30, 23, 50):Minute(5):DateTime(2026, 7, 1, 0, 15); chunk = :trading_day) ==
        [DateTime(2026, 6, 30, 23, 50):Minute(5):DateTime(2026, 7, 1, 0, 0), DateTime(2026, 7, 1, 0, 5):Minute(5):DateTime(2026, 7, 1, 0, 15)]
    @test chunks(DateTime(2025, 1, 1, 0, 5):Minute(5):DateTime(2025, 1, 1, 0, 20); chunk = Minute(10)) ==
        [DateTime(2025, 1, 1, 0, 5):Minute(5):DateTime(2025, 1, 1, 0, 10), DateTime(2025, 1, 1, 0, 15):Minute(5):DateTime(2025, 1, 1, 0, 20)]
    steps = DateTime(2025, 1, 1, 0, 5):Minute(5):DateTime(2025, 1, 1, 0, 10)
    @test_throws ArgumentError chunks(steps; chunk = Minute(7))
    @test_throws ArgumentError chunks(steps; chunk = Minute(0))
    @test_throws ArgumentError chunks(steps; chunk = :calendar_day)
    @test_throws ArgumentError chunks(steps; chunk = Month(1))

    # Two trading days split at 04:05 on the second day; a 00:05 1 July start splits a range over the year end.
    @test length(chunks(DateTime(2026, 1, 1, 4, 5):Minute(5):DateTime(2026, 1, 3, 4, 0))) == 2
    @test chunks(DateTime(2026, 6, 30, 23, 55):Minute(5):DateTime(2026, 7, 1, 0, 15)) ==
        [DateTime(2026, 6, 30, 23, 55):Minute(5):DateTime(2026, 7, 1, 0, 0), DateTime(2026, 7, 1, 0, 5):Minute(5):DateTime(2026, 7, 1, 0, 15)]
    @test length(chunks(DateTime(2026, 1, 1, 1, 0):Minute(5):DateTime(2026, 1, 1, 2, 55); chunk = Hour(1))) == 2
    @test_throws ArgumentError chunks(steps; chunk = :foo)
end
