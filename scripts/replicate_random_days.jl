# Lightweight supervisor; the worker loads the market and optimisation packages after sampling starts.
include("replay_batch_support.jl")
using .ReplayBatchSupport
using Dates

function main(args = ARGS)
    if args == ["--help"]
        println(
            """
            Replay randomly ordered trading days against published NEMDE outcomes.

            julia --project=AustralianElectricityMarketsSimulations/test scripts/replicate_random_days.jl [options]

              --first DATE          First trading day, inclusive (2026-01-01)
              --last DATE           Last trading day, inclusive (2026-06-30)
              --hours NUMBER        Stop starting days after this wall time (10); finish the current day
              --seed INTEGER        Reproducible shuffle seed (20261026); no repeated days
              --output FOLDER       New output folder (/run/media/simba/Store/aem_validation/<UTC timestamp>_<pid>)
              --hive FOLDER         Existing local market cache (~/.nemdb_cache)
              --sample-seconds N    Worker memory sampling period (5)
              --solver-threads N    HiGHS threads (1)
              --cache-size-mib N    PSI results write cache in MiB (64)
              --time-series-in-memory B  hold time series in memory (false)

            HiGHS mip_rel_gap=1e-8, mip_abs_gap=1e-10. Linux /proc required for memory sampling.
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
