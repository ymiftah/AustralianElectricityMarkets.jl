# 0112 Build order selects among degenerate FCAS duals; refactors are validated on inputs and primal

## Status

Accepted. Extends [0094](0094-highs-root-heuristics-and-tied-vertices.md), which covers solver options,
to code changes that leave the System's contents unchanged.

## What

- At an interval where the FCAS duals are degenerate, a change that does not touch any NEMDE input
  can still move FCAS prices. The System's contents are the same, so what changes is the order in
  which components, services and series are stored and the decision model is assembled. HiGHS then
  returns a different dual vertex.
- A refactor of system construction or of a reader is therefore checked by:
  1. equal System inputs: every static time series of the built System, compared value by value;
  2. equal objective, unit dispatch and interconnector flows on the sampled intervals;
  3. energy prices as a secondary check. FCAS prices that differ while 1 and 2 hold are expected and
     are neither a regression nor a fix.
- A movement of FCAS prices toward or away from AEMO's published values is not evidence about model
  fidelity unless the primal changed too.

## Why

- PR #246 (system construction as DataFrame pipelines, [0111](0111-system-construction-as-dataframe-pipelines.md))
  moved FCAS prices at two of the ten intervals sampled with seed 246, with solver options, the
  pinned PowerSimulations fork and the HiGHS build unchanged:

  | Interval and price | Published | `6e2cc54` | `020ea14`, `d0b4cc5` | PR merge (`2a63441`) |
  | --- | --- | --- | --- | --- |
  | 2025-04-29 22:15 `RAISEREG`, all mainland regions | 17.53 | 18.65 | 17.53 | 18.65 |
  | 2025-03-11 16:00 TAS1 `LOWERREG` | 2.49 | 3.31 | 2.82 | 3.31 |

  `020ea14` changed how offer curves are built (flat band columns, one cross join onto the dispatch
  grid, shared price vectors). The PR merge, which adds `a99dc05` (allocation cuts in the bid,
  tie-break and unit-condition stages), moved them back.
- At 2025-04-29 22:15 all 18,678 static time series of the System built by `6e2cc54` and by the PR
  merge are equal. At both intervals the `6e2cc54` and `020ea14` runs have the same objective to every
  printed digit (1.3118923261113696e7 and 7.835182109428184e7), the same dispatch for every matched
  unit (507 and 500 rows), and the same interconnector flows and energy prices.
- One commit message in the PR reported the ten intervals as identical and an agent attributed the
  improvement to a commit. Neither was supported once inputs and primal were compared; FCAS prices
  alone gave the wrong answer both times.
- AEMO's constraint FAQ specifies pro-rata tie-breaking for price-tied energy bands only, not for
  FCAS, so there is no documented AEMO rule to model for these ties.

## Consequences

- Benchmark comparisons between code revisions report FCAS price changes together with the primal
  comparison, and do not count a dual-only change as an accuracy gain or loss.
- Rejected: pinning a canonical component or row order to make FCAS duals reproducible across
  revisions. It would fix one vertex without matching NEMDE's, and any later model change would
  move it again.
- Open: whether NEMDE resolves FCAS band-edge ties to the lower band, as at 2025-07-07 12:15
  `TUNGATIN` in the benchmark report, is not established.
