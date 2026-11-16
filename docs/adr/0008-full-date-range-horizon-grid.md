# 0008 Constraint series grid is `date_range` minus its last point

## Status

Accepted

## What

- The `rhs` and `invoked` series of every `GenericConstraint` are indexed on `collect(date_range)[1:(end - 1)]`.
- Values carry forward across intervals where a constraint was not invoked; the `invoked` mask (1.0 or 0.0) is the only record of enforcement. A carried-forward `rhs` is not enforced unless `invoked` says so.

## How

- `_add_nem_constraints!` builds the grid once and pads each series to it.

## Why

- A grid from `unique(invoked.SETTLEMENTDATE)` is too short (some intervals have nothing bound), so the series disagree in length with other series on the `System` and PowerSystems' horizon check fails.
- Keeping all of `date_range` is one row too long: its N+1 timestamps label N interval starts, and `read_fcas_bids` and `set_demand!` already use the half-open `start <= x < stop` convention.
- A caller wanting another convention changes `date_range`, not the derivation.
