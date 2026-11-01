using Dates
using Test

include(joinpath(@__DIR__, "..", "..", "scripts", "replay_batch_support.jl"))
using .ReplayBatchSupport

@testset "overnight day selection and budget" begin
    days = scheduled_days(Date(2026, 1, 1), Date(2026, 6, 30), 17)
    @test length(days) == length(unique(days)) == 181
    @test Set(days) == Set(Date(2026, 1, 1):Day(1):Date(2026, 6, 30))
    @test days == scheduled_days(Date(2026, 1, 1), Date(2026, 6, 30), 17)
    @test days != scheduled_days(Date(2026, 1, 1), Date(2026, 6, 30), 18)
    @test trading_steps(Date(2026, 6, 30)) == DateTime(2026, 6, 30, 4, 5):Minute(5):DateTime(2026, 7, 1, 4)
    @test length(trading_steps(Date(2026, 1, 1))) == 288
    @test may_start_day(35999.0, 36000.0)
    @test !may_start_day(36000.0, 36000.0)
    @test !may_start_day(36001.0, 36000.0)
    @test_throws ArgumentError scheduled_days(Date(2026, 7, 1), Date(2026, 1, 1), 1)
    @test_throws ArgumentError parse_options(["--hours", "0"])
    @test_throws ArgumentError parse_options(["--hours", "NaN"])
    @test_throws ArgumentError parse_options(["--sample-seconds", "-1"])
    @test_throws ArgumentError parse_options(["--unknown", "x"])
    @test_throws ArgumentError parse_options(["--output"])
    @test dirname(parse_options(String[])["output"]) == "/run/media/simba/Store/aem_validation"
end

@testset "memory samples and durable status" begin
    mktempdir() do dir
        write_status(dir, "model_build"; trading_day = "2026-01-01")
        sample = memory_sample(getpid(), dir, 2.0)
        @test sample.phase == "model_build"
        @test sample.trading_day == "2026-01-01"
        @test sample.rss_mib > 0
        @test sample.peak_rss_mib >= sample.rss_mib
        @test sample.elapsed_s == 2.0
        @test isnothing(memory_sample(typemax(Int32), dir, 3.0))
        path = joinpath(dir, "escaped.csv")
        write_csv(path, ("name", "value"), [("a,\"b", missing), ("c\nd", 2)])
        @test read(path, String) == "name,value\n\"a,\"\"b\",\n\"c\nd\",2\n"
    end
end

@testset "budget stops only between complete days; failures are retained" begin
    mktempdir() do dir
        elapsed = Ref(0.0)
        days = [Date(2026, 1, 1), Date(2026, 1, 2), Date(2026, 1, 3)]
        completed = Date[]
        outcome = run_schedule(dir, days, 10.0; elapsed = () -> elapsed[]) do day, folder
            push!(completed, day)
            elapsed[] += 7.0
            write(joinpath(folder, "complete.txt"), "done")
            return (; intervals = 288)
        end
        @test completed == days[1:2]
        @test outcome == (; completed = 2, failed = 0, reason = "budget")
        @test isfile(joinpath(dir, "2026-01-02", "complete.txt"))
        @test !isdir(joinpath(dir, "2026-01-03"))
        @test length(readlines(joinpath(dir, "days.csv"))) == 3
    end
    mktempdir() do dir
        days = [Date(2026, 1, 1), Date(2026, 1, 2)]
        outcome = run_schedule(dir, days, 10.0; elapsed = () -> 1.0) do day, folder
            day == first(days) && error("missing cached offers")
            write(joinpath(folder, "complete.txt"), "done")
            return (; intervals = 288)
        end
        @test outcome == (; completed = 1, failed = 1, reason = "exhausted")
        @test occursin("missing cached offers", read(joinpath(dir, "2026-01-01", "error.txt"), String))
        @test isfile(joinpath(dir, "2026-01-02", "complete.txt"))
    end
end
