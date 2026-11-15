# Overnight batch runner for replay dispatch. The supervisor samples trading days and runs each in a
# worker process (`--worker <folder> <day>`), which loads the market and optimisation packages.
isdefined(@__MODULE__, :ReplayBatchSupport) || include("replay_batch_support.jl")
using .ReplayBatchSupport
using Dates

function main(args = ARGS)
    if args == ["--help"]
        println(
            """
            Replay randomly ordered trading days, or selected intervals, against published NEMDE outcomes.

            julia --project=AustralianElectricityMarketsSimulations/test scripts/replay_batch.jl [options]

              --first DATE          First trading day, inclusive (2026-01-01)
              --last DATE           Last trading day, inclusive (2026-06-30)
              --start DATETIME      First interval-ending time of a single range (off: whole days)
              --intervals N         Number of 5-minute intervals in that range (with --start)
              --intervals-file PATH CSV of interval-ending times (header `interval`) to replay instead of whole days
              --sample N            Replay N random distinct intervals of --first..--last (seed --seed), each solved alone
              --hours NUMBER        Stop starting days after this wall time (10); finish the current day
              --seed INTEGER        Reproducible shuffle seed (20261026); no repeated days
              --output FOLDER       New run folder (required; must not exist)
              --hive FOLDER         Existing local market cache (~/.nemdb_cache)
              --solver-threads N    HiGHS threads (1)
              --cache-size-mib N    PSI results write cache in MiB (64)
              --time-series-in-memory B  hold time series in memory (false)
              --closed-loop B       start each interval from the previous solve, not AEMO's state (false);
                                    not allowed with --sample or --intervals-file

            HiGHS mip_rel_gap=1e-8, mip_abs_gap=1e-10.
            See scripts/README.md for outputs and overnight launch commands.
            """
        )
        return
    end
    supervise(parse_options(args))
    return
end

if abspath(PROGRAM_FILE) == @__FILE__
    if length(ARGS) == 3 && ARGS[1] == "--worker"
        include("replay_batch_worker.jl")
        ReplayBatchWorker.main(ARGS[2], Date(ARGS[3]))
    else
        main()
    end
end
