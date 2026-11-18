# 0009 `FCASService` is a bare `(region, bid_type)` anchor

## Status

Accepted

## What

- One `FCASService` per `(region, bid_type)`, named `"<REGIONID>_<BIDTYPE>"`, with `region`, `bid_type`, `available` and `ext`. It has no RHS and no time series (`supports_time_series` is `false`).
- The requirement RHS stays on the governing `GenericConstraint`; the service only joins devices.

## How

- `add_fcas_services!(sys; bid_types)` creates a service for each region and market with at least one available bidder, independent of any `GenericConstraint`, and returns `(added, excluded)`.
- It attaches only devices whose bid direction `FCASMarket` models (incremental, decremental-only on a `Storage` or load, or a `Storage` regulation bid on both sides) and warns once about the rest.
- A service already in `sys` under that name is left as is.

## Why

- AEMO clears one FCAS price per `(region, bid_type, interval)`, not per unit; the decision variable stays per `(device, t)`.
- NEMDE enables FCAS from offers alone and the requirement constraints bind on those enablements, so services must exist first.
- Sparse FCAS participation is ordinary, so a pair with no bidder is skipped, not an error (unlike [0007](0007-empty-region-terms-throw-by-default.md)).
