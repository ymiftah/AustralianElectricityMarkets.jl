@testset "trading_day_steps" begin
    steps = trading_day_steps(Date(2026, 1, 1))
    @test length(steps) == 288
    @test first(steps) == DateTime(2026, 1, 1, 4, 5)
    @test last(steps) == DateTime(2026, 1, 2, 4, 0)
end

@testset "replay_chunks" begin
    chunks = replay_chunks
    @test chunks(DateTime(2026, 1, 1, 3, 55):Minute(5):DateTime(2026, 1, 1, 4, 15); chunk = :trading_day) ==
        [DateTime(2026, 1, 1, 3, 55):Minute(5):DateTime(2026, 1, 1, 4, 0), DateTime(2026, 1, 1, 4, 5):Minute(5):DateTime(2026, 1, 1, 4, 15)]
    @test chunks(DateTime(2026, 1, 1, 4, 5):Minute(5):DateTime(2026, 1, 2, 4, 0); chunk = :trading_day) ==
        [DateTime(2026, 1, 1, 4, 5):Minute(5):DateTime(2026, 1, 2, 4, 0)]
    # A 00:05 1 July start splits a range over the financial year end.
    @test chunks(DateTime(2026, 6, 30, 23, 50):Minute(5):DateTime(2026, 7, 1, 0, 15); chunk = :trading_day) ==
        [DateTime(2026, 6, 30, 23, 50):Minute(5):DateTime(2026, 7, 1, 0, 0), DateTime(2026, 7, 1, 0, 5):Minute(5):DateTime(2026, 7, 1, 0, 15)]
    @test chunks(DateTime(2025, 1, 1, 0, 5):Minute(5):DateTime(2025, 1, 1, 0, 20); chunk = Minute(10)) ==
        [DateTime(2025, 1, 1, 0, 5):Minute(5):DateTime(2025, 1, 1, 0, 10), DateTime(2025, 1, 1, 0, 15):Minute(5):DateTime(2025, 1, 1, 0, 20)]
    steps = DateTime(2025, 1, 1, 0, 5):Minute(5):DateTime(2025, 1, 1, 0, 10)
    @test_throws ArgumentError chunks(steps; chunk = Minute(7))
    @test_throws ArgumentError chunks(steps; chunk = Minute(0))
    @test_throws ArgumentError chunks(steps; chunk = :calendar_day)
    @test_throws ArgumentError chunks(steps; chunk = Month(1))
    # Two trading days split at 04:05 on the second day, by default.
    @test length(chunks(DateTime(2026, 1, 1, 4, 5):Minute(5):DateTime(2026, 1, 3, 4, 0))) == 2
    @test length(chunks(DateTime(2026, 1, 1, 1, 0):Minute(5):DateTime(2026, 1, 1, 2, 55); chunk = Hour(1))) == 2
end
