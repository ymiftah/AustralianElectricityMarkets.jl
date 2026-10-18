# Replay a range of dispatch intervals

`replicate_range` replays consecutive 5-minute dispatch intervals against AEMO's published outcome.
It builds one PowerSimulations `Simulation` per chunk of the range, so a whole trading day is solved
by a single model build whose parameters are updated at each interval. For one interval at a time,
`replicate_interval` builds a fresh model per call instead.

## Replay a trading day

Keep the output on a disk, not in `/tmp`, which is RAM-backed on most Linux systems. The cache must
hold data from `start` to `stop + 5 minutes`.

```julia
using AustralianElectricityMarkets
using AustralianElectricityMarketsSimulations
using Dates
using HiGHS
using PowerSimulations: optimizer_with_attributes

db = aem_connect()
optimizer = optimizer_with_attributes(HiGHS.Optimizer, "mip_rel_gap" => 0.0, "mip_abs_gap" => 1.0e-10)
out = replicate_range(
    db, DateTime(2026, 1, 1, 4, 5), DateTime(2026, 1, 2, 4, 0);
    optimizer = optimizer, output_dir = "/data/aem/replay_2026_01_01",
)
```

## Required inputs

Replay rejects missing dispatch inputs, skipped constraint definitions, dropped constraint terms
and missing penalty weights before constructing the optimisation model. Populate the cache for
the requested intervals and the effective dates and offer dates they reference.

Energy dispatch requires each unit's bid `MAXAVAIL`, effective schedule type, and a complete
`UIGF` forecast for semi-scheduled units. Zero is a valid forecast. Missing or invalid inputs
raise an error. A range crossing a unit's schedule-type change must be split at that change.

`replication_system` attaches these inputs automatically. When assembling a system manually,
call `set_nem_energy_limits!(sys, db, date_range)` after attaching bids and FCAS participants,
before transforming time series or constructing the NEM dispatch model. The existing
`set_nem_dispatch_limits!` still attaches ramping, initial conditions and FCAS availability.

Energy bid availability and UIGF are separate elastic constraints. Their surplus variables
are priced at their respective AEMO CVP factors, so a higher-priority non-conformance or ramp
constraint can require output above them. Such violations appear in `constraint_violations`
as `energy_max_avail` and `energy_uigf`, in MW. Ordinary intervals retain their bid and forecast
limits. Non-scheduled FCAS-only loads remain fixed at zero energy dispatch. Storage retains
its existing separate direction limits.

Total offered energy bands have separate priced violations at CVP1135. Dispatch beyond
the offered quantity appears as `energy_offer` in `constraint_violations`, in MW.
Exceeding both an availability limit and the total bands incurs both penalties. The
submitted band quantities and prices are retained.

`INTERCONNECTORCONSTRAINT.ICTYPE` at the replay date determines whether each interconnector is
regulated or an MNSP. An MNSP requires both registered links, terminal loss factors, and complete
price bands, quantities and availability for every interval. Missing MNSP data raises an error;
it never changes the interconnector to a free-flow model. An interconnector explicitly registered
as regulated needs no MNSP offers.

For the first trading day of a month, offers referenced by `DISPATCH_MNSPBIDTRK` can be stored in
the preceding month's `MNSP_DAYOFFER` and `MNSP_BIDOFFERPERIOD` partitions. For example:

```julia
using AustralianElectricityMarketsData: populate

for table in (:MNSP_DAYOFFER, :MNSP_BIDOFFERPERIOD, :DISPATCH_MNSPBIDTRK)
    populate(db, table, Date(2025, 12, 1), Date(2026, 1, 1))
end
```

## Chunks

The range is split into chunks, each solved as its own `Simulation` with its own system and
pre-flight checks. A chunk starts at `start`, at every 04:05 interval (the start of a trading day,
where the energy tie-break pairs are fixed) and at 00:05 on 1 July (the start of a Market Price Cap
year). The `chunk` keyword adds further breaks: `chunk = Dates.Minute(60)` starts a chunk every hour
after its own start, as well as at the boundaries above. A chunk never spans a trading day, so
`chunk = :trading_day` (the default) gives one chunk per trading day.

Each chunk's results are written to `output_dir/chunk_<k>` (or a fresh temporary folder when
`output_dir` is omitted). A failing chunk logs the folders of the chunks already solved and rethrows
the error.

## Return value

`replicate_range` returns a named tuple:

- `chunks`: one row per chunk with its `start`, `stop`, `n_steps`, `folder` and timings in seconds.
- `results`: one `SimulationProblemResults` per chunk, reopened from its folder.
- `comparison`: the solved and published prices, dispatch, interconnector flows and losses, and FCAS
  prices, stacked over intervals with a `SETTLEMENTDATE` column.
- `solver_stats`: the objective and solver times of each interval.
- `skipped_constraints`, `ramp_violations` and `constraint_violations`: the generic constraints left
  out of the model and the slack variables that are not zero, by chunk and interval.

## Reading a chunk later

The results of a chunk stay on disk in its folder. They can be read after the call, without the
system or the simulation:

```julia
using PowerSimulations

results = PowerSimulations.SimulationResults("/data/aem/replay_2026_01_01/chunk_1", "replicate_range")
decision = PowerSimulations.get_decision_problem_results(results, "dispatch")
```

## Memory and disk

The peak memory of a replay depends on the range and on the machine. Measure it for the range at
hand with `AustralianElectricityMarketsSimulations/scripts/measure_replicate_range.jl`, which reports
the peak resident size and the store size of one chunk. The keywords that trade memory for time are:

- `time_series_in_memory` (default `true`) and `time_series_directory`: keep the system's time series
  in memory, or write them to a file on disk. Without a `time_series_directory`, each chunk writes its
  file under `<chunk folder>/time_series`, which lies in the system temporary directory when
  `output_dir` is `nothing`. A time-series file is deleted only when the Julia process exits, so the
  files of every chunk stay on disk until then.
- `cache_size_mib`: the write cache of the simulation store.
- `store_parameters` (default `true`): whether the store keeps the replication model's own
  time-series parameters. The results of the comparison do not depend on it.
