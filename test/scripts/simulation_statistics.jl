# Regression tests for the saved run analysis; no market data or solver needed.
using Dates
using Test

isdefined(@__MODULE__, :SimulationStatistics) ||
    include(joinpath(@__DIR__, "..", "..", "scripts", "simulation_statistics.jl"))
const SS = SimulationStatistics

function ss_csv(path, fields, rows)
    mkpath(dirname(path))
    open(path, "w") do io
        println(io, join(fields, ","))
        foreach(r -> println(io, join(string.(r), ",")), rows)
    end
    return
end

function ss_day(root, name = "run"; completed = true)
    run = joinpath(root, name)
    day = joinpath(run, "2026-04-07")
    mkpath(day)
    write(joinpath(day, "provenance.toml"), "revision = \"abc\"\nhdf5 = \"0.17.5\"\n")
    completed && ss_csv(joinpath(run, "days.csv"), ["trading_day", "status", "elapsed_s", "execute_s"], [["2026-04-07", "completed", 100, 80]])
    return run, day
end

ss_dispatch(day, rows) = ss_csv(joinpath(day, "comparison_dispatch.csv"), ["SETTLEMENTDATE", "DUID", "TOTALCLEARED_published", "TOTALCLEARED_solved"], rows)
ss_timings(day, fields, rows; chunk = 1) = ss_csv(joinpath(day, "chunk_$chunk", "problems", "dispatch", "interval_timings.csv"), fields, rows)
ss_violations(day, rows) = ss_csv(joinpath(day, "constraint_violations.csv"), ["family", "name", "DateTime", "MW", "direction", "variable"], [[f, n, t, 1, "up", ""] for (f, n, t) in rows])
ss_energy(day, rows) = ss_csv(joinpath(day, "comparison_prices.csv"), ["SETTLEMENTDATE", "REGIONID", "ROP_published", "ROP_solved"], rows)
ss_fcas(day, rows) = ss_csv(joinpath(day, "comparison_fcas_prices.csv"), ["SETTLEMENTDATE", "REGIONID", "BIDTYPE", "ROP_published", "ROP_solved"], rows)

function ss_state_timer(day, seconds; chunk = 1, calls = 1)
    write(
        joinpath(day, "timers_execute_chunk_$chunk.toml"),
        "[inner_timers.\"Execute Simulation\"]\nn_calls = $calls\n" *
            "[inner_timers.\"Execute Simulation\".inner_timers.\"Execute dispatch\".inner_timers.\"Update State\"]\ntime_ns = $(seconds * 10^9)\n",
    )
    return
end

@testset "simulation statistics" begin
    @testset "signed and absolute percentiles" begin
        stats = SS.error_distribution([-10.0, 0.0, 2.0])
        @test stats["mae"] ≈ 4
        @test stats["bias"] ≈ -8 / 3
        @test stats["p95"] ≈ 9.2
        @test stats["signed_p5"] ≈ -9
        @test SS.distribution(Float64[])["n"] == 0
    end

    @testset "the day window is the trading day's 288 interval-ending stamps" begin
        times = SS.expected_times("2026-04-07")
        @test length(times) == 288
        @test "2026-04-07T04:05:00" in times && "2026-04-08T04:00:00" in times
        @test !("2026-04-07T04:00:00" in times) && !("2026-04-08T04:05:00" in times)
        @test SS.normalize_timestamp("2026-04-07T04:05:00+10:00") == "2026-04-07T04:05:00"
        @test SS.normalize_timestamp("2026-04-06T18:05:00Z") == "2026-04-07T04:05:00"
        @test isnothing(SS.normalize_timestamp("not a time"))
    end

    @testset "missing, duplicate and out-of-day rows are not zero-filled" begin
        mktempdir() do root
            run, day = ss_day(root)
            ss_dispatch(
                day, [
                    ["2026-04-07T04:05:00", "A", 10, 12], ["2026-04-07T04:10:00", "A", 3, ""],
                    ["2026-04-07T04:15:00", "A", 0, 1], ["2026-04-07T04:15:00", "A", 0, 7], ["2026-04-08T04:05:00", "A", 0, 9],
                ],
            )
            stats = SS.analyze([run])["days"][1]["comparisons"]["dispatch_mw"]
            @test stats["errors"]["n"] == 1
            @test stats["errors"]["mae"] == 2
            @test stats["missing_nonzero_published"] == 1
            @test stats["duplicate_keys"] == 1
            @test stats["out_of_day_rows"] == 1
            @test stats["groups"]["A"]["paired_intervals"] == 1
        end
    end

    @testset "overlapping days and partial days are excluded from the pool" begin
        mktempdir() do root
            first_run, a = ss_day(root, "one")
            second_run, b = ss_day(root, "two")
            partial, c = ss_day(root, "partial"; completed = false)
            foreach(d -> ss_dispatch(d, [["2026-04-07T04:05:00", "A", 1, 2]]), (a, b, c))
            result = SS.analyze([first_run, second_run, partial])
            @test result["pooled"]["dispatch_mw"]["n"] == 1
            @test result["unique_completed_days"] == 1
            @test result["days"][3]["status"] == "in_progress"
            @test any(w -> occursin("overlap", w), result["warnings"])
        end
    end

    @testset "nested solve timers are not added to their parent twice" begin
        mktempdir() do root
            run, day = ss_day(root)
            ss_timings(
                day, ["phase", "execution_count", "interval_aest", "wall_s", "timed_solve_s", "pricing_s", "auxiliary_s"], [
                    ["solve_impl", 0, "2026-04-07T04:05:00", 50, 40, 8, 1],
                    ["result_write", 0, "2026-04-07T04:05:00", 5, "NaN", "NaN", "NaN"],
                    ["parameter_update", 1, "2026-04-07T04:10:00", 10, "NaN", "NaN", "NaN"],
                ],
            )
            timing = SS.analyze([run])["days"][1]["timing"]
            @test timing["execution_unattributed_s"] == 15
            @test timing["series"]["mip"]["total_s"] == 40
            @test timing["series"]["solve_wrapper_residual"]["total_s"] == 1
        end
    end

    @testset "schema 2 rows are counted and the residual does not subtract the native state update twice" begin
        mktempdir() do root
            run, day = ss_day(root)
            ss_state_timer(day, 10)
            ss_timings(
                day, ["phase", "execution_count", "interval_aest", "wall_s", "timed_solve_s", "pricing_s", "auxiliary_s", "gc_s", "compilation_s", "allocated_bytes", "schema_version"], [
                    ["parameter_update", 0, "2026-04-07T04:05:00", 4, "NaN", "NaN", "NaN", "NaN", "NaN", "NaN", 2],
                    ["solve_and_write", 0, "2026-04-07T04:05:00", 50, 40, 8, 1, 0.5, "NaN", 1000, 2],
                ],
            )
            timing = SS.analyze([run])["days"][1]["timing"]
            # execute 80 - (parameter_update 4 + solve_and_write 50); the state update is inside solve_and_write.
            @test timing["timing_schema"] == 2
            @test timing["written_intervals"] == 1
            @test timing["series"]["mip"]["total_s"] == 40
            @test timing["series"]["solve_and_write"]["total_s"] == 50
            @test timing["execution_unattributed_s"] == 26
            @test timing["native_state_s"] == 10
            @test timing["series"]["solve_and_write_residual"]["total_s"] == 1
            @test !haskey(timing["series"], "solve_wrapper_residual")
            @test isnothing(timing["instrumented_compilation_s"]) && isnothing(timing["instrumented_gc_s"])
            @test timing["optimize_gc_s"] == 0.5
            @test timing["optimize_allocated_bytes"] == 1000
        end
    end

    @testset "the schema 1 residual still subtracts the native state update" begin
        mktempdir() do root
            run, day = ss_day(root)
            ss_state_timer(day, 10)
            ss_timings(
                day, ["phase", "execution_count", "interval_aest", "wall_s", "timed_solve_s", "pricing_s", "auxiliary_s"], [
                    ["parameter_update", 1, "2026-04-07T04:10:00", 10, "NaN", "NaN", "NaN"],
                    ["solve_impl", 0, "2026-04-07T04:05:00", 50, 40, 8, 1],
                ],
            )
            timing = SS.analyze([run])["days"][1]["timing"]
            @test timing["timing_schema"] == 1
            @test timing["execution_unattributed_s"] == 10
            @test timing["series"]["solve_wrapper_residual"]["total_s"] == 1
        end
    end

    @testset "mixed timing schemas within a day or across days throw" begin
        mktempdir() do root
            run, day = ss_day(root)
            ss_timings(day, ["phase", "execution_count", "interval_aest", "wall_s", "schema_version"], [["solve_and_write", 0, "2026-04-07T04:05:00", 50, 2]])
            ss_timings(day, ["phase", "execution_count", "interval_aest", "wall_s"], [["solve_impl", 0, "2026-04-07T04:10:00", 50]]; chunk = 2)
            @test_throws r"cannot be pooled" SS.analyze([run])
        end
        mktempdir() do root
            one, day_one = ss_day(root, "one")
            two, day_two = ss_day(root, "two")
            ss_timings(day_one, ["phase", "execution_count", "interval_aest", "wall_s"], [["solve_impl", 0, "2026-04-07T04:05:00", 50]])
            ss_timings(day_two, ["phase", "execution_count", "interval_aest", "wall_s", "schema_version"], [["solve_and_write", 0, "2026-04-07T04:05:00", 50, 2]])
            @test_throws r"across days" SS.analyze([one, two])
        end
    end

    @testset "an incomplete final CSV record is ignored with a warning; quoted fields parse" begin
        mktempdir() do root
            path = joinpath(root, "samples.csv")
            write(path, "timestamp,value\na,100\nb,2")
            warnings = String[]
            @test SS.read_csv(path, warnings) == [["timestamp" => "a", "value" => "100"]]
            @test !isempty(warnings)
            write(path, "name,value\n\"a,\"\"b\",\n\"c\nd\",2\n")
            @test SS.read_csv(path, String[]) == [["name" => "a,\"b", "value" => ""], ["name" => "c\nd", "value" => "2"]]
        end
    end

    @testset "cumulative native snapshots use the last total" begin
        mktempdir() do root
            run, day = ss_day(root)
            ss_state_timer(day, 6; chunk = 1, calls = 1)
            ss_state_timer(day, 10; chunk = 2, calls = 2)
            @test SS.analyze([run])["days"][1]["timing"]["native_state_s"] == 10
        end
    end

    @testset "missing regions are visible and the outputs are written" begin
        mktempdir() do root
            run, day = ss_day(root)
            ss_csv(joinpath(day, "comparison_prices.csv"), ["SETTLEMENTDATE", "REGIONID", "ROP_published", "ROP_solved", "RRP_published"], [["2026-04-07T04:05:00", "NSW1", 10, 12, 999]])
            result = SS.analyze([run])
            comparison = result["days"][1]["comparisons"]["energy_price"]
            @test comparison["errors"]["mae"] == 2
            @test comparison["groups"]["TAS1"]["n"] == 0
            @test comparison["groups"]["TAS1"]["expected_intervals"] == 288
            output = joinpath(root, "report")
            SS.save_report(result, output)
            for f in ("report.md", "statistics.json", "errors.csv", "category_errors.csv", "entity_errors.csv")
                @test isfile(joinpath(output, f))
            end
            @test occursin("## Error distributions by category", read(joinpath(output, "report.md"), String))
        end
    end

    @testset "category distributions pool FCAS by service, region and direction" begin
        mktempdir() do root
            run, day = ss_day(root)
            ss_fcas(day, [["2026-04-07T04:05:00", "NSW1", "RAISEREG", 10, 13], ["2026-04-07T04:05:00", "SA1", "RAISEREG", 10, 11], ["2026-04-07T04:05:00", "SA1", "LOWER6SEC", 5, 5]])
            categories = SS.analyze([run])["categories"]["fcas_price"]
            @test categories["service"]["RAISEREG"]["n"] == 2
            @test categories["service"]["RAISEREG"]["mae"] == 2
            @test categories["region"]["SA1"]["mae"] == 0.5
            @test categories["direction"]["LOWER"]["mae"] == 0
        end
    end

    @testset "over-constrained intervals" begin
        mktempdir() do root
            run, day = ss_day(root)
            ss_violations(day, [("generic_constraint", "C1", "2026-04-07T04:05:00")])
            ss_fcas(day, [["2026-04-07T04:05:00", "NSW1", "LOWER5MIN", 20300, 20310], ["2026-04-07T04:10:00", "NSW1", "LOWER5MIN", 1, 3]])
            result = SS.analyze([run])
            @test length(result["over_constrained_intervals"]) == 1
            flagged = only(result["over_constrained_intervals"])
            @test SS.field(flagged, "trigger") == "fcas_high"
            @test SS.field(flagged, "interval") == "2026-04-07T04:05:00"
            @test SS.field(flagged, "constraints") == "C1"
            @test result["pooled"]["fcas_price"]["n"] == 2
            @test result["pooled_excluding_over_constrained"]["fcas_price"]["n"] == 1
            @test result["pooled_excluding_over_constrained"]["fcas_price"]["mae"] == 2
        end
        mktempdir() do root
            # A high price without a violation in its interval is not flagged.
            run, day = ss_day(root)
            ss_violations(day, [("generic_constraint", "C1", "2026-04-07T04:10:00")])
            ss_energy(day, [["2026-04-07T04:05:00", "NSW1", 20300, 20310]])
            result = SS.analyze([run])
            @test isempty(result["over_constrained_intervals"])
            @test result["pooled_excluding_over_constrained"]["energy_price"]["n"] == 1
        end
        mktempdir() do root
            # A violation with a normal price is not flagged.
            run, day = ss_day(root)
            ss_violations(day, [("generic_constraint", "C1", "2026-04-07T04:05:00")])
            ss_energy(day, [["2026-04-07T04:05:00", "NSW1", 50, 52]])
            @test isempty(SS.analyze([run])["over_constrained_intervals"])
        end
        mktempdir() do root
            # A unit ramp violation with a high price is not flagged.
            run, day = ss_day(root)
            ss_violations(day, [("unit_ramp", "U1", "2026-04-07T04:05:00")])
            ss_energy(day, [["2026-04-07T04:05:00", "NSW1", 20300, 20310]])
            @test isempty(SS.analyze([run])["over_constrained_intervals"])
        end
        mktempdir() do root
            # A floor price with a generic violation is flagged.
            run, day = ss_day(root)
            ss_violations(day, [("generic_constraint", "C1", "2026-04-07T04:05:00")])
            ss_energy(day, [["2026-04-07T04:05:00", "NSW1", -1000, -1000], ["2026-04-07T04:05:00", "QLD1", 40, 41]])
            result = SS.analyze([run])
            @test [(SS.field(r, "trigger"), SS.field(r, "entity")) for r in result["over_constrained_intervals"]] == [("energy_low", "NSW1")]
            @test result["pooled_excluding_over_constrained"]["energy_price"]["n"] == 0
        end
        mktempdir() do root
            # A missing violation file warns and flags nothing.
            run, day = ss_day(root)
            ss_energy(day, [["2026-04-07T04:05:00", "NSW1", 20300, 20310]])
            result = SS.analyze([run])
            @test isempty(result["over_constrained_intervals"])
            @test any(w -> occursin("constraint violations", w), result["warnings"])
        end
    end

    @testset "energy price tail: signed summary, price bands and price duration" begin
        mktempdir() do root
            run, day = ss_day(root)
            # Errors are solved minus published; the last QLD1 row has no published value and is not paired.
            ss_energy(
                day, [
                    ["2026-04-07T04:05:00", "NSW1", 400, 410], ["2026-04-07T04:05:00", "QLD1", 600, 590],
                    ["2026-04-07T04:10:00", "NSW1", 50, 52], ["2026-04-07T04:10:00", "QLD1", 150, 150],
                    ["2026-04-07T04:15:00", "NSW1", -20, -25], ["2026-04-07T04:15:00", "QLD1", 0, 1],
                    ["2026-04-07T04:20:00", "NSW1", 300, 299], ["2026-04-07T04:20:00", "QLD1", "", 5],
                ],
            )
            result = SS.analyze([run])
            tail = result["price_tail"]
            # Signed errors 10, -10, 2, 0, -5, 1, -1.
            signed = tail["regional_signed"]
            @test signed["n"] == 7
            @test signed["mean"] ≈ -3 / 7
            @test signed["median"] == 0
            @test signed["p5"] ≈ -8.5
            @test signed["p95"] ≈ 7.6
            bands = tail["bands"]
            @test bands["above_300"]["n"] == 2 && bands["above_300"]["mae"] == 10
            @test bands["0_to_300"]["n"] == 4 && bands["below_0"]["n"] == 1
            @test bands["below_0"]["bias"] == -5
            @test bands["above_300"]["share_pct"] ≈ 100 * 2 / 7
            # Interval prices are unweighted regional means, ranked by published price.
            duration = result["price_duration"]
            @test [SS.field(r, "published") for r in duration] == [500, 300, 100, -10]
            @test SS.field(duration[1], "interval") == "2026-04-07T04:05:00" && SS.field(duration[1], "position") == 1
            @test SS.field(duration[end], "solved") == -12
            @test tail["interval_signed"]["n"] == 4
            output = joinpath(root, "report")
            SS.save_report(result, output)
            lines = readlines(joinpath(output, "price_duration.csv"))
            @test lines[1] == "position,interval,published,solved"
            @test startswith(lines[2], "1,2026-04-07T04:05:00,500.0,500.0") && length(lines) == 5
            @test occursin("## Energy price tail", read(joinpath(output, "report.md"), String))
            json = read(joinpath(output, "statistics.json"), String)
            @test occursin("\"price_tail\"", json) && !occursin("\"price_duration\"", json)
        end
    end

    @testset "the command line writes the report and refuses a source run as output" begin
        mktempdir() do root
            run, day = ss_day(root)
            ss_dispatch(day, [["2026-04-07T04:05:00", "A", 1, 2]])
            @test SS.main([run]) == 0
            @test isfile(joinpath(run, "simulation_statistics", "report.md"))
            @test SS.main([run, "--output", run]) == 2
            @test SS.main([run, "--cache-windows", "0"]) == 2
            @test SS.main(String[]) == 2
        end
    end
end
