using Dates
using Test

isdefined(@__MODULE__, :ReplayBatchSupport) ||
    include(joinpath(@__DIR__, "..", "..", "scripts", "replay_batch_support.jl"))
using .ReplayBatchSupport

@testset "overnight day selection and budget" begin
    days = scheduled_days(Date(2026, 1, 1), Date(2026, 6, 30), 17)
    @test sort(days) == collect(Date(2026, 1, 1):Day(1):Date(2026, 6, 30))
    @test days == scheduled_days(Date(2026, 1, 1), Date(2026, 6, 30), 17)
    @test days != scheduled_days(Date(2026, 1, 1), Date(2026, 6, 30), 18)
    @test trading_steps(Date(2026, 6, 30)) == DateTime(2026, 6, 30, 4, 5):Minute(5):DateTime(2026, 7, 1, 4)
    @test may_start_day(35999.0, 36000.0)
    @test !may_start_day(36000.0, 36000.0)
    @test_throws ArgumentError scheduled_days(Date(2026, 7, 1), Date(2026, 1, 1), 1)
    defaults = parse_options(String[])
    for flag in ("time-series-in-memory", "closed-loop")
        @test defaults[flag] == "false"
        @test parse_options(["--$flag", "true"])[flag] == "true"
    end
    @test dirname(defaults["output"]) == "/run/media/simba/Store/aem_validation"
    @test batch_steps(parse_options(["--start", "2026-06-04T04:05:00", "--intervals", "10"]), Date(2026, 6, 4)) ==
        DateTime(2026, 6, 4, 4, 5):Minute(5):DateTime(2026, 6, 4, 4, 50)
    @test batch_steps(defaults, Date(2026, 6, 4)) == trading_steps(Date(2026, 6, 4))
    for args in (
            ["--hours", "0"], ["--hours", "NaN"], ["--sample-seconds", "5"], ["--unknown", "x"], ["--output"],
            ["--time-series-in-memory", "yes"], ["--closed-loop", "maybe"],
            ["--start", "2026-06-04T04:05:00"], ["--intervals", "10"],
            ["--start", "2026-06-04T04:07:00", "--intervals", "10"], ["--start", "2026-06-04T04:05:00", "--intervals", "0"],
            ["--start", "2026-06-05T04:00:00", "--intervals", "2"],
        )
        @test_throws ArgumentError parse_options(args)
    end
end

@testset "durable status and CSV escaping" begin
    mktempdir() do dir
        @test read_status(dir) == (; trading_day = "", phase = "loading")
        write_status(dir, "model_build"; trading_day = "2026-01-01")
        @test read_status(dir) == (; trading_day = "2026-01-01", phase = "model_build")
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

@testset "day workers have independent process lifetimes" begin
    mktempdir() do folder
        polled = Int[]
        worker(code) = ReplayBatchSupport.run_worker(
            `$(Base.julia_cmd()) --startup-file=no -e $code`, folder, time_ns();
            poll_seconds = 0.01, notice = false, on_poll = pid -> push!(polled, pid),
        )
        first_pid = worker("sleep(0.5)")
        second_pid = worker("sleep(0.5)")
        @test first_pid != second_pid
        @test first_pid in polled && second_pid in polled
        @test !isfile(joinpath(folder, "memory.csv"))
        @test_throws ProcessFailedException worker("exit(2)")
    end
end

@testset "a supervisor failure reaps its owned child" begin
    mktempdir() do folder
        owned = Ref(0)
        @test_throws ErrorException ReplayBatchSupport.run_worker(
            `$(Base.julia_cmd()) --startup-file=no -e 'sleep(30)'`, folder, time_ns();
            poll_seconds = 0.01, notice = false, on_poll = pid -> (owned[] = pid; error("polling failed"))
        )
        @test owned[] > 0
        # `kill -0` probes the process without signalling it; it fails once the child is reaped.
        @test !success(ignorestatus(`kill -0 $(owned[])`))
    end
end

@testset "source provenance changes with package code" begin
    mktempdir() do root
        mkpath(joinpath(root, "src"))
        write(joinpath(root, "Project.toml"), "name = \"fixture\"\n")
        source = joinpath(root, "src", "fixture.jl")
        write(source, "value() = 1\n")
        first = ReplayBatchSupport.package_source_hashes(root)
        @test haskey(first, "src/fixture.jl")
        @test haskey(first, "Project.toml")
        write(source, "value() = 2\n")
        @test ReplayBatchSupport.package_source_hashes(root) != first
        snapshot = joinpath(root, "snapshot")
        copied = ReplayBatchSupport.snapshot_package_sources(root, snapshot)
        @test copied == ReplayBatchSupport.package_source_hashes(root)
        @test read(joinpath(snapshot, "src", "fixture.jl"), String) == "value() = 2\n"
    end
end
