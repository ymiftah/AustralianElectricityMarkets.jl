# 0006. FCAS bid series are stored as tuples/`PiecewiseStepData`, not `FCASBid`/`FCASTrapezium`

## Status

Accepted

## Context

`FCASTrapezium` has `Union{Nothing, Float64}` fields; `FCASBid` nests a `PiecewiseStepData`
plus an `FCASTrapezium`. `IS.Deterministic`'s inner constructor gates the per-step element
type through `is_transform_array_for_hdf_supported`, a closed dispatch table (`Real`, concrete
`Tuple`, `Matrix`, and PSY's named curve types). Neither `FCASTrapezium` nor `FCASBid` matches
any of those, so both are rejected outright at construction — confirmed directly, not assumed
(`test/fcas.jl`'s `"FCASBid time series round-trip"` testset).

## Decision

Store an `NTuple{7,Float64}` for the trapezium (`NaN` for an absent ramp rate) and a
`PiecewiseStepData` for the offer curve. `Tuple(::FCASTrapezium)`/`FCASTrapezium(::NTuple)`
convert between the typed struct and the tuple; `src/fcas/access.jl`'s accessors reconstruct
typed values on every read, so nothing outside `bids.jl`/`access.jl`/`parser.jl` sees a raw
tuple. `FCASBid.offer_curve` is typed `PiecewiseStepData`, matching what `_extract_power_bids`
already produces, not the `CostCurve` it was previously declared as.

## Consequences

- The tuple shape is a storage-layer constraint, not a design preference.
- Testing the `Tuple`/`FCASTrapezium` round trip needs `isequal`, not `==`: `NaN != NaN`.
- `FCASBid.offer_curve`'s type change is breaking for any external caller constructing
  `FCASBid` directly with a cost curve.
