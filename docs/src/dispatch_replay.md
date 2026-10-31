# Run a dispatch simulation from a system

`AustralianElectricityMarkets` reads cached market data and constructs a populated
`PowerSystems.System`. `AustralianElectricityMarketsSimulations` prepares and runs models
from that system. Its simulation utilities do not take a database connection.

## Construct the system with AEM

Use `NEMDEConfiguration` to attach demand, energy and FCAS bids, dispatch inputs,
energy limits, generic constraints, interconnector losses and MNSP offers. The configuration's
`table_requirements` lists its source tables. Populate the cache before construction.

```julia
using AustralianElectricityMarkets
using Dates

steps = DateTime(2025, 1, 1, 0, 5):Minute(5):DateTime(2025, 1, 1, 0, 10)
db = aem_connect()
sys = nem_system(
    db, NEMDEConfiguration();
    date_range = first(steps):Minute(5):(last(steps) + Minute(10)),
    intervention = 0,
)
```

The construction range includes the extra input timestamps needed for forecast preparation.
Its stop is exclusive for interval input readers. Use `time_series_in_memory = false` and
optionally `time_series_directory` for file-backed time series.

`interval_flow_limits = true` attaches published interval flow limits for diagnostics.
These limits are computed after dispatch; keep the default `false` when validating simulated flows.

MNSP inputs include each directional link's offers, availability, ramp rate and fixed-loading
instruction, plus the interconnector's metered starting flow from the selected `intervention`
run. `table_requirements(NEMDEConfiguration())` includes `DISPATCHINTERCONNECTORRES`, which
`set_mnsp_offers!` requires even when `interval_flow_limits = false`.
A NULL fixed-loading value means no instruction; zero is an active instruction.

The dispatch model prices MNSP violations at the interval's Market Price Cap times CVP factors
1155 for net-flow ramping, 1135 for total offered MW, 380 for fixed loading and 365 for
availability. Violation reports retain the directional link and express quantities in MW.
The existing loss-model domain still bounds flow. MNSP loss-equation violations, Basslink
converter losses, its no-go zone and frequency-controller alternative runs are not modelled.

## Prepare and run with PSI

```julia
using AustralianElectricityMarkets
using AustralianElectricityMarketsSimulations
import PowerSimulations as PSI

# From the repository root: the runner and result extraction live in `scripts/`.
include("scripts/replay_simulation.jl")
include("scripts/replay_results.jl")
using .ReplaySimulation: replication_simulation
using .ReplayResults: replication_results

prepare_replay_forecasts!(sys)
simulation = replication_simulation(sys, steps; folder = mktempdir())
PSI.build!(simulation; store_systems_in_results = false)
PSI.execute!(simulation)

results = PSI.get_decision_problem_results(PSI.SimulationResults(simulation), "dispatch")
report = replication_results(results, sys)
report.solved.prices
report.constraint_violations
```

`nem_system(db, NEMDEConfiguration(); ...)` already derives the effective FCAS offers and the
tie-break scales. `prepare_replay_forecasts!` transforms the single time series into five-minute
forecast windows; call it once on a system with at least two input timestamps.
`replication_simulation` returns an unbuilt `PSI.Simulation`; the caller controls building,
execution and result access.

The constructor checks input coverage, compatible tie-break pairs, one Market Price Cap,
FCAS services and dispatch envelopes. Its `parts` keyword selects from `REPLICATION_PARTS`.
Pass a vector through `skipped` to collect constraints omitted from the template.

## Compare historical results with NEMDE

The repository scripts coordinate cache access, system construction, simulation and published
outcome comparisons. Run them from the repository root with an existing cache:

```sh
julia --project=AustralianElectricityMarketsSimulations/test scripts/replicate_range.jl \
    2025-01-01T00:05:00 2025-01-01T00:10:00 /path/to/cache

julia --project=AustralianElectricityMarketsSimulations/test scripts/diagnose_infeasible.jl \
    2025-01-01T00:05:00 /path/to/cache
```

The range workflow creates a new system for each trading-day or financial-year chunk, and for
custom chunk periods. This refreshes static system data through AEM. AEMSim checks the supplied
system and does not rebuild it from the cache. Comparison reads use AEM's
`read_published_interval`; published outcomes are not fetched by the simulation utilities.
