# 0094. HiGHS root heuristics and tied optima

## Status

Proposed. Records measured trade-offs; the replay optimizer is unchanged (all four root sub-MIP
heuristics off, as set by commit 863ea1d).

## Context

`NEMDE_HIGHS_OPTIONS` (`AustralianElectricityMarketsSimulations/src/problems/optimizer.jl`) turns off
four HiGHS root sub-MIP heuristics: `mip_heuristic_run_rins`, `mip_heuristic_run_rens`,
`mip_heuristic_run_root_reduced_cost` and `mip_heuristic_run_feasibility_jump`. Commit 863ea1d
introduced this for speed and described the solutions as identical.

The replay MILP has many tied optima: different primal solutions with the same objective. The
options change which tied solution HiGHS returns. Objectives match on every interval, but prices
(duals of the fixed LP), interconnector flows and FCAS prices differ, and so does their match to
AEMO's published outcome. NEMDE resolves ties by its own rules, which the replay does not model.

A bisection of the regression in full-day fidelity between 55ccc2a and 465fae9 isolated 863ea1d as
the only cause. Running 465fae9 with the four heuristics back on reproduces every signature interval
of the earlier run.

## Measurements

Trading day 2026-06-04 (288 intervals), batch runner, time series in memory, single HiGHS thread,
MIP gaps `1e-8` relative and `1e-10` absolute. Errors are mean absolute errors against AEMO's
published values.

| Configuration | Energy price ($/MWh) | FCAS price ($/MWh) | Flow (MW) | Losses (MW) | Summed solve (s) | Median interval (s) | Slowest interval (s) |
| --- | --- | --- | --- | --- | --- | --- | --- |
| All four on (HiGHS defaults) | 0.0328 | 0.00061 | 0.212 | 0.0054 | 1301 | 3.28 | 91.9 |
| RENS on, other three off | 0.0345 | 0.00146 | 0.213 | 0.0054 | 755 | 2.32 | 17.3 |
| All four off (current) | 0.0380 | 0.00160 | 0.226 | 0.0061 | 635 | 2.14 | 9.6 |

Three-interval windows around 09:40 and 13:10 isolate each option. Only RENS restores the published
values: QLD1 09:40 at 21.918 against 22.81 with all off, VIC1 13:10 at 40.358 against 37.83, and
13:10 RAISEREG at 7.158 against 4.63. RINS, root reduced cost and feasibility jump on their own
leave those intervals at the all-off values.

## Options

1. **Keep all four off (current).** This is the fastest: the slowest interval takes 9.6 s. Energy
   prices match AEMO less closely (MAE +0.005 $/MWh), FCAS prices least closely (about 2.6 times the
   defaults' MAE), and flows are slightly off.
2. **Turn RENS on, keep the other three off.** This recovers about two thirds of the energy-price
   loss and almost all of the flow loss. Summed solve time rises by about 120 s per day and the
   slowest interval by about 8 s. FCAS prices barely improve, because their remaining misses sit at
   other tied intervals.
3. **Restore the HiGHS defaults.** This gives the best measured fit to AEMO, but doubles solve time
   and makes the slowest interval about ten times slower (92 s).
4. **Make the choice among tied optima deterministic.** A secondary objective or tie-break would
   select the tied solution by rule rather than by the solver's search path, so prices would no
   longer depend on solver options. This is a model change: it needs a check against AEMO's
   documented tie-breaking and an ADR of its own. Fidelity is unmeasured.

## Decision

None yet. The measurements cover one trading day; any choice should be confirmed on several days
(for example the overnight batch sample) before the options change.

## Consequences

- Any change to solver options has to be checked on full-day prices against AEMO, not only on the
  objective. Equal objectives do not imply equal prices.
- Small FCAS price differences between runs (for example TAS1 RAISEREG at 4.72 or 5.72) come from
  the same non-uniqueness and are expected while the current options stand.
