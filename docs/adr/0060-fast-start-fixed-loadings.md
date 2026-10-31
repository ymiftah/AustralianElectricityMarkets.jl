# 0060: Fast-start fixed loadings are dropped only in profile modes 1 and 2

## Status

Accepted.

## Context

AEMO's Schedule of Constraint Violation Penalty Factors (v8.0, item 13) defines the Energy
Inflexible Offer constraint: a unit equality at the participant's fixed loading. The schedule ranks
the fixed loading below a fast-start unit's Unit MaxAvail in modes 1 to 3 (cumulative CVP). It does
not remove the fixed loading in those modes.

The Fast Start Inflexibility Profile (FSIP) section 5.2.1 says the profile fixes dispatch during
T1 and T2 (modes 1 and 2). In T3 and T4 it is only a lower bound, at the minimum loading.

NEMDE invokes the `$<DUID>` constraint at every fast-start fixed-load interval. The replay does not
model the inflexibility profile (`BIDDAYOFFER_D.T1` to `T4`), so it cannot derive the modes itself.

Real-data evidence, January to June 2026 fast-start fixed-load intervals: 672 in total, all with
`$<DUID>` invoked. In mode 2, 2 intervals, dispatch followed the profile. In mode 3, 12 intervals, 9
met the fixed loading exactly and 3 were ramp-limited. In mode 4, 658 intervals, met except where
ramp-limited.

## Decision

`read_fixed_loads` flags a row `IN_PROFILE` when `DISPATCHLOAD.DISPATCHMODE` of the unit at the
interval is 1 or 2. Only fast-start units reach those modes. `IN_PROFILE` rows are not attached as
fixed loadings. Every other fixed loading is attached. The `$<DUID>` invoked rows at all
fixed-loading intervals, `IN_PROFILE` or not, are recognised as fixed-load constraints and are
neither built nor reported as skipped.

Mode 4 with time-in-mode below T4 needs no special treatment. The profile lower bound only matters if
`FIXEDLOAD` is below it, which happens in 1 interval in the data, and that interval was met.

## Departure from AEMO

- `DISPATCHMODE` is `DISPATCHLOAD`'s target mode. NEMDE's commitment step computes it from its first
  solve, so it is a solution output, not a pre-solve input like `INITIALMW`. The replay reads it as an
  input because it has no commitment pass.
- The inflexibility profile itself is not modelled: the T1 and T2 trajectory and the T3 and T4 lower
  bound are absent. The fixed loading is left unenforced in modes 1 and 2, so dispatch there is
  governed by the offer bands and availability alone.

## Consequences

- Fixed loadings of fast-start units are enforced at every interval outside modes 1 and 2.
- Modelling the inflexibility profile removes the remaining departure.
