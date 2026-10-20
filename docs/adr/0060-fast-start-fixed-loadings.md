# 0060: Fixed loadings of fast-start units are not replayed

## Status

Accepted.

## Context

AEMO's Schedule of Constraint Violation Penalty Factors (v8.0, item 13) defines the Energy
Inflexible Offer constraint: a unit equality at the participant's fixed loading, with a penalty
factor of 380. The schedule says the fixed loading "cannot override a lower priority Unit MaxAvail
for FS unit during modes 1, 2 and 3 (cumulative CVP) to ensure that target complies with FS
Inflexibility Profile". The carve-out applies only while the unit is in a fast-start profile mode.

The replay does not model the fast-start inflexibility profile (`BIDDAYOFFER_D.T1` to `T4`), so it
cannot tell which intervals fall in modes 1 to 3.

## Decision

`read_fixed_loads` excludes every unit whose latest `BIDDAYOFFER_D` row for the trading day has
`T1 > 0`, for the whole day. The `$<DUID>` constraint is built for all other units with
`FIXEDLOAD > 0`. A fast-start unit's `$<DUID>` row in `DISPATCHCONSTRAINT` is reported as skipped
by `add_nem_constraints!`.

## Departure from AEMO

AEMO applies the profile only in modes 1 to 3. Excluding the unit for the whole day also drops its
fixed loading in the intervals after the profile ends (mode 4 and later), where AEMO would enforce
the equality. Dispatch of such a unit in those intervals is then governed by its offer bands and
availability alone.

## Consequences

- Replay of a fast-start unit with a fixed loading can differ from NEMDE after its profile ends.
- Modelling the profile and restoring the fixed loading outside modes 1 to 3 removes the departure.
