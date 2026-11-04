include(joinpath(@__DIR__, "..", "..", "scripts", "replay_workflow.jl"))
using .ReplayWorkflow: replicate_range

# Prepares a cache-built system for the script's result-reading regressions.
function workflow_test_system(db, date_range; kwargs...)
    return AEMS._prepare_replay_forecasts!(nem_system(db, NEMDEConfiguration(); date_range, kwargs...))
end

@testset "interval timing UTC offset is rounded to quarter hours" begin
    @test ReplayWorkflow._round_utc_offset(36_000_000 + 400_000) == Millisecond(36_000_000)
    @test ReplayWorkflow._round_utc_offset(36_000_000 + 500_000) == Millisecond(36_900_000)
    @test ReplayWorkflow._round_utc_offset(-19_800_000 - 20_000) == Millisecond(-19_800_000)
    @test iszero(Dates.value(ReplayWorkflow._utc_offset()) % 900_000)
end

@testset "interval timings come from native PSI records" begin
    # No replay-side override of the PSI methods the timings used to wrap.
    @test which(PSI.update_model!, (PSI.DecisionModel, PSI.Simulation)).module === PowerSimulations
    @test which(PSI.solve_impl!, (PSI.DecisionModel,)).module === PowerSimulations
    db = aem_connect(HiveConfiguration(hive_location = AEM_TEST_REPLAY_HIVE_DIR, filesystem = "file"))
    t1, t2 = DateTime(2025, 1, 1, 0, 5), DateTime(2025, 1, 1, 0, 10)
    d = mktempdir()
    result = replicate_range(db, t1, t2; output_dir = d)
    paths = [joinpath(root, f) for (root, _, files) in walkdir(d) for f in files if f == "interval_timings.csv"]
    @test length(paths) == 1
    lines = readlines(only(paths))
    columns = split(lines[1], ',')
    @test columns == [
        "timestamp_utc", "interval_aest", "execution_count", "phase", "wall_s", "allocated_bytes",
        "gc_s", "compilation_s", "timed_solve_s", "pricing_s", "auxiliary_s", "schema_version",
    ]
    rows = [Dict(zip(columns, split(line, ','))) for line in lines[2:end]]
    intervals = [string(t1), string(t1 + Minute(5))]
    @test [(r["interval_aest"], r["phase"]) for r in rows] ==
        [(i, phase) for i in intervals for phase in ("parameter_update", "solve_and_write")]
    @test all(==("2"), (r["schema_version"] for r in rows))
    @test [parse(Int, r["execution_count"]) for r in rows] == [0, 0, 1, 1]
    wall(r) = parse(Float64, r["wall_s"])
    @test all(>=(0), wall.(rows))
    solves = filter(r -> r["phase"] == "solve_and_write", rows)
    @test all(>(0), wall.(solves))
    @test wall(rows[3]) > 0
    # Solver fields are the optimizer statistics of each executed step.
    stats = PSI.read_optimizer_stats(only(result.results))
    for (row, i) in zip(solves, 1:2)
        @test parse(Float64, row["timed_solve_s"]) ≈ stats.timed_solve_time[i]
        @test parse(Float64, row["pricing_s"]) ≈ stats.timed_calculate_dual_variables[i]
        @test parse(Float64, row["auxiliary_s"]) ≈ stats.timed_calculate_aux_variables[i]
        @test parse(Float64, row["allocated_bytes"]) ≈ stats.solve_bytes_alloc[i]
        @test parse(Float64, row["gc_s"]) ≈ stats.sec_in_gc[i]
    end
    @test parse(Float64, solves[1]["timed_solve_s"]) ≈ result.solver_stats.timed_solve_time[1]
    for row in filter(r -> r["phase"] == "parameter_update", rows)
        @test all(isnan, parse.(Float64, (row["timed_solve_s"], row["compilation_s"], row["allocated_bytes"])))
    end
end

include("replay_batch.jl")
include("interconnector_loss_gaps.jl")
