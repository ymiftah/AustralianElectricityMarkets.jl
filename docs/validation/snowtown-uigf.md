# Snowtown non-conformance and UIGF investigation

Two isolated interval experiments confirm that the hard energy ceiling prevents the replay from
honouring Snowtown's higher-priority non-conformance constraints. Adding correctly priced UIGF
surplus variables restores both Snowtown targets and brings regional prices and interconnector
flows close to NEMDE. The initial experiment was a diagnostic prototype. The production
implementation and its validation are described below.

## Inputs and cause

The investigation uses branch `stock-simulation-v02` at
`a96e554828c5875406d8bcfa78df0dfcfa18c107`, the fully populated local cache, all default replay
parts, and static interconnector limits (`interval_flow_limits=false`). All timestamps are AEST
and denote interval ends. No cache population was required.

The first case is the largest Snowtown dispatch discrepancy in the corrected full-day replay:
2 January 2026 at 02:00. A second affected interval, 1 January at 04:55, tests the same cause.

| Interval | DUID | Initial MW and NEMDE target | UIGF and published availability, MW | Bid MAXAVAIL, MW |
| --- | --- | ---: | ---: | ---: |
| 2 Jan 02:00 | SNOWNTH1 | 61.19922 | 51.22536 | 144 |
| 2 Jan 02:00 | SNOWSTH1 | 87.39844 | 82.99134 | 126 |
| 1 Jan 04:55 | SNOWNTH1 | 48.00000 | 45.55553 | 144 |
| 1 Jan 04:55 | SNOWSTH1 | 62.50000 | 54.58220 | 126 |

The effective definitions of `NC_S_SNOWNTH1` and `NC_S_SNOWSTH1`, dated 10 November 2017,
version 1, each contain one ENERGY term with coefficient 1 and constraint weight 1160.
Their interval RHS values equal the corresponding INITIALMW. Published violation degrees are zero.

`DISPATCHLOAD.AVAILABILITY` combines bid availability and UIGF for semi-scheduled units. Our
setter carries that combined ceiling into `max_active_power`, raised only when a ramp-down floor
requires it. In these cases the ramp-down floor is lower, so the model imposes `power <= UIGF`
as a hard constraint. It consequently pays for a non-conformance violation even though NEMDE
honours the non-conformance target and exceeds UIGF.

The source checks used AEMO's *Schedule of Constraint Violation Penalty Factors*, v8.0,
effective 2 December 2025: Table 1 item 2, non-conformance factor 1160, pp. 6-12; item 12,
UIGF factor 385, and item 14, MaxAvail factor 370, pp. 13-17. The local faithful extracts are
`nem-expert/references/constraint-violation-penalty-factors/03-items-01-11.md` and
`04-items-12-21.md`. AEMO's *Electricity Data Model Report* v5.7.0, DISPATCHLOAD,
pp. 271-276, documents the combined AVAILABILITY field and separate UIGF field. These sources
support separate constraints and costs rather than treating the combined ceiling as inviolable.

## Controlled change

Each scenario builds a fresh model from the same complete-input system. The prototype changes
only the two Snowtown renewable upper-limit rows to `power - UIGFSurplus <= original_ceiling`,
with non-negative continuous surplus variables. Each surplus is priced at
`base_power * interval_cost_coefficient(385 * MPC, resolution)`, where the January 2026 MPC
is 20,300 AUD/MWh and the interval is five minutes. The coefficient is therefore
65,129,166.666667 per system-base per-unit for this 100 MW system base.

The original non-conformance equations, targets, weights, energy bids, ramp rows, demand, losses,
FCAS and other generic constraints are retained. The prototype does not use published dispatch
or prices to set new targets. The non-conformance RHS already belongs to the supplied dispatch
constraint inputs. Both units' offered capacities exceed the restored targets, so bid availability
does not need to be violated in these cases.

HiGHS uses one thread, `parallel=off`, zero relative MIP gap, absolute gap `1e-10`, and a
180-second time limit per solve. The pricing pass uses the existing fixed-binary LP mechanism.
No alternative solver or automatic retry is introduced by the probe.

## Results

| Interval | DUID | Baseline MW | Prototype MW | NEMDE MW | UIGF surplus, MW |
| --- | --- | ---: | ---: | ---: | ---: |
| 2 Jan 02:00 | SNOWNTH1 | 51.22536 | 61.19922 | 61.19922 | 9.97386 |
| 2 Jan 02:00 | SNOWSTH1 | 82.99134 | 87.39844 | 87.39844 | 4.40710 |
| 1 Jan 04:55 | SNOWNTH1 | 45.55553 | 48.00000 | 48.00000 | 2.44447 |
| 1 Jan 04:55 | SNOWSTH1 | 54.58220 | 62.50000 | 62.50000 | 7.91780 |

All four Snowtown dispatch comparisons agree within `1e-8 MW`. Their non-conformance slacks
fall to zero. The corresponding UIGF surplus equals the original dispatch shortfall.

| Metric across each complete interval | 2 Jan 02:00 baseline | 2 Jan 02:00 prototype | 1 Jan 04:55 baseline | 1 Jan 04:55 prototype |
| --- | ---: | ---: | ---: | ---: |
| Regional ROP MAE, AUD/MWh | 0.019591 | 0.0001725 | 1.649485 | 0.0000412 |
| Maximum regional ROP error, AUD/MWh | 0.097432 | 0.000516 | 4.365662 | 0.0001010 |
| Maximum modelled dispatch error, MW | 9.973860 | 0.003048 | 7.917800 | 0.003748 |
| Interconnector flow MAE, MW | 3.282728 | 0.000992 | 2.033192 | 0.001921 |
| Maximum interconnector flow error, MW | 14.544075 | 0.003697 | 10.379893 | 0.004248 |
| Interconnector loss MAE, MW | 0.311065 | 0.0000441 | 0.072098 | 0.0000585 |

Each interval compares five regional prices, 511 dispatch rows with both values, six
interconnectors and 50 FCAS prices. FCAS prices are unchanged by the prototype; their maximum
absolute error is `0.00000429 AUD/MWh` across these cases.

At 02:00 the SA price changes from 18.1048518 to 18.0077621 AUD/MWh against NEMDE's 18.00742.
Heywood flow changes from 249.6675245 to 235.1217886 MW against NEMDE's 235.12345.
At 04:55 the SA price changes from 24.3487923 to 19.9831274 AUD/MWh against 19.98313, while
the TAS price changes from 62.7008980 to 58.8193336 against 58.81933.

## Verification and scope

All four dispatch MIPs and four pricing LPs terminated OPTIMAL. The solve hook checked each
result before PSI restored the binary variables, with independently calculated row, bound and
integrality residuals below `1e-6`. Actual maximum residuals were below `1e-12` in model units.
Native objectives agree with the evaluated objective expression. Each dispatch/pricing objective
pair agrees within `1e-5 + 1e-9 * abs(objective)`; the largest observed difference is below `2e-8`.

These experiments establish the cause and a working correction for the selected intervals.
They do not validate a general production implementation or establish full NEMDE equivalence.
The targeted surplus variables live outside PSI's registered variable containers, so they are
exported separately in `uigf_slacks.csv`; the existing violation table alone is incomplete for
the prototype. A production implementation must register and report them normally.

The production requirements established by this probe were to retain raw bid availability and
UIGF separately, construct their
respective elastic rows at the documented penalties, and remove overlapping hard bounds that
would defeat those rows. It must preserve recurrent parameter updates, strict complete-input
validation, ordinary intervals with no violations, and FCAS availability semantics. Regression
tests should exercise competition between non-conformance, UIGF, MaxAvail and ramping. Applying
the combined AVAILABILITY ceiling at factor 385 to every unit would assign the wrong cost when
bid MAXAVAIL is the binding limit.

During the initial investigation only these diagnostic solves were run. No production code was
edited and no package test suite was rerun at that stage. The diagnostic Julia sources were formatted with Runic and parsed;
the report and changelog were checked with Markdown lint and `git diff --check`.

## Reproduction and artifacts

Artifacts are retained at
`/run/media/simba/Store/aem_validation/stock_sim/snowtown_uigf_20261017`:

- `0200/` and `0455/`: baseline and prototype comparisons, solve audits and explicit UIGF slacks.
- `inputs/`: published dispatch inputs, selected bid capacities, non-conformance definitions,
  terms and published constraint outcomes.
- `analysis/`: combined input/dispatch comparisons, interval metrics and solve audits.
- `probe.jl` and `export_inputs.jl`: formatted diagnostic and input-export scripts. Exact
  pre-formatting executed sources are preserved alongside them; only formatting differs.
- `environment/`: Project and Manifest of the isolated environment used, including pinned local
  package paths. The root Project and Manifest were not changed.
- `verify.py`: independent results checks; its parser reconstructs the diagnostic variable-key
  field in the exploratory violation CSVs, whose embedded commas were originally unquoted.
- `metadata.json`, `SHA256SUMS`, logs and this report.

From this worktree, use the saved environment to run `probe.jl NEW_OUTPUT_DIRECTORY` for 02:00,
or append `2026-01-01T04:55:00` for the second interval. Use Julia with `--threads=1`. The
diagnostic script runs both baseline and prototype and reads the cache without populating it.
`python3 verify.py ARTIFACT_DIRECTORY NEW_ANALYSIS_DIRECTORY` checks all eight accepted solves
and regenerates the aggregate comparisons without solving again.

## Production implementation

The general non-storage formulation now retains separate bid `MAXAVAIL` and semi-scheduled
`UIGF` inputs, resolves effective schedule classification, and requires complete valid values.
Its constraints use distinct registered surplus variables at CVP370 and CVP385 respectively.
The hard combined ceiling and overlapping static active-power bound are removed. Both new
families appear in standalone and recurrent violation reports in MW. FCAS availability and
storage's existing directional handling retain their previous semantics.

`set_nem_energy_limits!` attaches these inputs for a manually assembled system;
`replication_system` calls it automatically. Missing forecasts for semi-scheduled units remain
an error. Scheduled-only input sets need no weather forecast, including older cache schemas
without a UIGF column. A change of effective schedule type inside a range requires splitting
that range. No Snowtown-specific condition or missing-input fallback is used.

The regression first reproduced dispatch 45 MW against a higher-priority 60 MW target, then
passed with the general formulation. Tests additionally cover both simultaneous violations,
participant fixed loading between the two penalties, ramp priority, negative bids, zero
forecasts, outputs above a static rating but inside offered bands, input completeness and
atomic validation, and recurrent updates in either order.

### Production replay results

The general implementation was replayed at the same two intervals using the full cache,
all default parts, static interconnector limits and one HiGHS thread. No diagnostic row edits
were applied. Both dispatch MIPs and both fixed-binary pricing LPs terminated OPTIMAL; independent
residual and objective audits passed. The four Snowtown targets agree with NEMDE within
`1e-8 MW`. Registered `energy_uigf` violations are 9.97386 and 4.40710 MW at 02:00, and
2.44447 and 7.91780 MW at 04:55. Their non-conformance violations are zero.

| Metric | 2 Jan 02:00 | 1 Jan 04:55 |
| --- | ---: | ---: |
| Regional ROP MAE, AUD/MWh | 0.00017316 | 0.00004146 |
| Maximum regional ROP error, AUD/MWh | 0.00051800 | 0.00010172 |
| Maximum modelled dispatch error, MW | 0.00304817 | 0.00374811 |
| Interconnector flow MAE, MW | 0.00099199 | 0.00192116 |
| Maximum interconnector flow error, MW | 0.00369706 | 0.00424790 |
| Interconnector loss MAE, MW | 0.00004413 | 0.00005847 |

The new formulation also reports other units' availability violations, including TARRALEA's
0.3 MW surplus at 02:00. Its objective therefore need not equal that of the earlier prototype,
which changed only the two Snowtown rows. Dispatch/pricing objective consistency is checked
within each model; objectives across different formulations are not an equivalence test.

Production artifacts, source snapshots and audit scripts are retained at
`/run/media/simba/Store/aem_validation/stock_sim/snowtown_production_20261018`.
The validation uses Julia 1.13.1 and HiGHS 1.15.1, with relative gap zero, absolute gap `1e-10`
and a 180-second solve limit. It does not establish full-day or general NEMDE equivalence.

### Implementation checks

Both complete package runners passed on Julia 1.13.1: the root suite passed 1,621 assertions
across 17 groups, and Simulations passed 3,021 assertions across 15 groups. The latter
includes 52 assertions for separate elastic energy limits and 748 for stock simulation replay.
All repository hooks passed, including Runic and Markdown lint; `git diff --check` was clean.

Commands used with the implementation worktree:

```sh
julia --compiled-modules=existing --project=test --threads=1 test/runtests.jl
julia --compiled-modules=existing --project=/tmp/aem-solver-compare/env --threads=1 \
    AustralianElectricityMarketsSimulations/test/runtests.jl
```

The second command uses the saved replay/benchmark environment; its `Project.toml` and
`Manifest.toml` are included with the production artifacts. Logs are retained as
`root_tests.log` and `sim_tests.log`. The first Simulations run also exposed incomplete FCAS
test fixtures, now corrected to provide the new energy series and use the existing complete
replay cache. Production input validation was not relaxed.
