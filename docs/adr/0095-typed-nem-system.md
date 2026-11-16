# 0095 Typed NEM system

## Status

Accepted. Replay devices are stock PowerSystems types ([0097](0097-stock-devices-for-replay.md)); AEM writes every input and AEMSim only reads the System ([0101](0101-aem-writes-aemsim-reads.md)); bids are in [0093](0093-nem-device-types-and-offer-cost.md).

## What

- Every quantity of a replay system is a typed field: a static value, or a key into a series attached to the component that owns the field. No component carries an `ext` entry on the replay path.
- A quantity AEMO publishes once is static; one that varies over the range is an `IS.StaticTimeSeriesKey`. Numeric static fields are coerced to `Float64`, since JSON reads `0.0` back as an integer. `nothing` is allowed only where AEMO permits absence (a non-semi-scheduled unit's UIGF, an MNSP bid's fixed load).
- The System is self-contained and persistable. A JSON and HDF5 round trip preserves every struct and series value; shared object identity (one `NEMStation` for several units) is not part of the contract.

## How

Per-device structs, held by `NEMUnitData` ([0097](0097-stock-devices-for-replay.md)):

- `NEMRegistration`: schedule type, loss factors, registration span and commissioned flag.
- `NEMTelemetry`: the telemetered limits from `DISPATCHLOAD` in natural units. Ramp rates are stored as published and the bid rate is applied by `effective_ramp_limit`; regulation availability is stored as published (AEMO already publishes the minimum of bid and telemetry).
- `NEMObservedState`: starting MW and fast-start dispatch mode.
- `NEMOfferCost`: the bids.

Supplemental attributes on stock components, not new subtypes: `NEMStation` on a unit (shared by units at a station); `NEMInterconnectorLimits` and `NEMInterconnectorRegistration` on an `AreaInterchange`; `NEMMNSPLink`, `NEMMNSPBid` and `NEMMNSPObservedState` on an MNSP interchange.

On AEM's own types: `GenericConstraint.rhs` and `.invoked` are a typed value or key, and `NEMBuildReport` (`get_build_report(sys)`) holds the skipped constraints, missing intervals, defaulted weights and dropped terms.

`NEMUnitState` (starting MW, dispatch mode, time in mode) is the state argument of the pure derivation kernels in `src/derivations/`.

## Why

- Typed fields survive serialisation and reload, which a free-form `ext` dictionary does not guarantee, and make derivations testable as pure functions over structs and a synthetic state.
- `nem_system` checks that every dispatch device carries registration, telemetry and observed state, and throws naming each one that does not.
- A series that is written twice or removed later invalidates keys already recorded in typed fields; the one-writer rule is in [0101](0101-aem-writes-aemsim-reads.md).
