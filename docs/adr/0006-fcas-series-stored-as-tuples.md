# 0006 Typed FCAS structs cannot be time-series elements

## Status

Accepted; the `FCASBid` struct it named is replaced by `NEMFCASBid` ([0099](0099-one-series-per-bid-input.md)).

## What

- Time-series values are limited to what `IS.Deterministic` accepts: `Real`, concrete `Tuple`, `Matrix` and PSY's named curve types. A struct with `Union{Nothing, Float64}` fields is rejected at construction.
- Bid fields are therefore stored one series per field: offer curves as `PiecewiseStepData`, the trapezium as a four-point tuple.

## How

- `FCASTrapeziumPoints` is a named tuple of four `Float64` (`ENABLEMENTMIN`, `LOWBREAKPOINT`, `HIGHBREAKPOINT`, `ENABLEMENTMAX`). `Tuple(::FCASTrapezium)` and `FCASTrapezium(::NTuple{7, Float64})` convert the typed struct, using `NaN` for an absent ramp rate.
- Round-trip tests need `isequal`, not `==`.

## Why

- The tuple shape is a storage-layer constraint, not a design preference.
