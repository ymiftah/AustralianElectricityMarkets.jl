# 0095. Typed NEM system

## Status

Accepted. [0093](0093-nem-device-types-and-offer-cost.md) defines the NEM device types and
`NEMOfferCost`, [0092](0092-psi-shaped-replay-interface.md) defines the replay interface, and
[0096](0096-per-step-state-updates.md) defines how the state source reaches PowerSimulations each
step.

## Context

A replay system has three kinds of quantity:

- exogenous inputs that AEMO publishes once per build: registration, bids, telemetry limits,
  network limits and constraint data;
- the observed unit state, which is AEMO's dispatch outcome but is read as an input;
- effective inputs that the formulation reads, derived from the first two.

The build is the only stage that touches the cache. Everything later reads the `System`, including a
system that has been persisted and reloaded, and the per-step updates read the state source.

## Decision

### AEM processes all data, AEMSim reads only the `System`

Every cache read happens in `AustralianElectricityMarkets`, once per table per build. No
`AustralianElectricityMarketsSimulations` function takes a database connection or a cache path. The
`System` is therefore a complete description of a replay interval, and the same derivation runs on
a freshly built system, a system loaded from JSON and HDF5, and a system built by a future rolling
horizon.

### Every quantity is a typed field

A field holds either a static value or a key into a series attached to the component that owns the
field. No component carries an `ext` entry. A quantity that AEMO publishes once is static; a quantity
that varies over the range is an `IS.TimeSeriesKey`. Constructors coerce numeric static fields to
`Float64` because JSON reads `0.0` back as an integer. `nothing` is allowed only where AEMO permits
absence, such as the UIGF of a unit that is not semi-scheduled or an MNSP bid's fixed load.

The typed boundary records a series key for every derived family it owns. PSI parameter construction
reads the ramp and availability families back through those keys, and still resolves the offer
families, the FCAS effective and ramping series, the tie-break scale and the loss-demand coefficient
by their series names.

### The typed boundary

On each NEM device type, one per kind of data:

- `NEMRegistration`: the schedule type, loss factors, registration span and station commissioned
  flag from `DUDETAILSUMMARY`, the loss-factor tables and the station's operating status.
- `NEMTelemetry`: the telemetered limits from `DISPATCHLOAD`, in natural units. The ramp up and down
  rates are stored as published and the bid rate is applied later by `effective_ramp_limit`; the
  regulation availability fields are stored as published because AEMO already publishes them as the
  minimum of the bid and the telemetered value.
- `NEMObservedState`: the starting MW and fast-start dispatch mode from `DISPATCHLOAD`.
- `NEMOfferCost`: the keys of the energy and FCAS offer series, from [0093](0093-nem-device-types-and-offer-cost.md).

Derived inputs have their own attribute because they are written by AEMSim, not AEM:

- `NEMDispatchInputs` on the device holds the keys of the derived energy offers, energy availability,
  ramp rates and UIGF.
- `NEMFCASInputs` entries inside `NEMDispatchInputs` hold the keys of each FCAS service's derived
  offer, trapezium and AGC ramp series.

The runtime state is separate from both:

- `NEMUnitState` is the starting MW and dispatch mode of one device at one interval.
- A `StateSource` produces it. `ObservedState` reads `NEMObservedState`. A rolling horizon will supply
  `SimulatedState` without changing any derivation's signature.

Stock components hold supplemental attributes rather than new subtypes:

- `NEMStation` on a unit, shared by the units at one station.
- `NEMInterconnectorLimits` and `NEMInterconnectorRegistration` on an `AreaInterchange`.
- `NEMMNSPLink`, `NEMMNSPBid` and `NEMMNSPObservedState` on an MNSP interchange.

Typed fields also replace named series and `ext` entries on AEM's own types:

- `GenericConstraint.rhs` and `GenericConstraint.invoked` are a typed value or a key, and the other
  `GENCONDATA` metadata is a typed field.
- `NEMBuildReport` holds the skipped constraints, missing intervals, defaulted weights and dropped
  terms, reached through `get_build_report(sys)`.

### One writer per series

Each series name on each component has exactly one writer in a build:

- `nem_system` writes the exogenous and observed series.
- `set_effective_offers!` writes each state-independent derived series once. It records a key in
  `NEMDispatchInputs` for the families that struct owns; the FCAS effective and ramping series, the
  tie-break scale and the loss-demand coefficient are written without a field there.
- The first-solve seed series are written once from the state source and are not replaced by a later
  stage.

No later stage removes or replaces a series. A series that disappears invalidates a key already
recorded in a typed field, and a series written twice leaves two owners for one name. Values that
change per step reach the solver through PowerSimulations parameters, never by rewriting a series.

### State is an input, not a series name

A state-dependent quantity is a pure function of the typed structs and a `NEMUnitState`. The
derivation is the same for a build-time seed and for a per-step update. A formulation reads the
starting MW through the state source, not through a fixed series name, so a system rebuilt for a
rolling horizon needs no new series. The mechanism that pushes these values into PowerSimulations is
recorded in [0096](0096-per-step-state-updates.md).

### Build-time target

The target is a warm `nem_system(db, NEMDEConfiguration(); date_range = trading_day)` for the
2026-06-04 trading day in under 10 seconds. The batch runner builds one system per chunk,
so the build cost must stay small against the solve; the target also guards the typed path against a
regression that reintroduces a repeated cache read or a lookup that bypasses a recorded key.

## Consequences

- A device that participates in dispatch must carry all three unit structs. `nem_system` checks this
  before returning and throws naming every device that does not.
- The `System` is self-contained and persistable. A JSON and HDF5 round trip must preserve every
  struct and every series value. Shared object identity, such as one `NEMStation` instance for
  several units, is not part of the contract; values are.
- AEMSim's derivation can be tested as pure functions over the structs and a synthetic state.
- Adding a derived series means recording its key in the owning struct or attribute. A family that a
  formulation reads by name needs its key recorded before it can move off the name.
- A series written by a second stage, or removed by a later one, is a design error rather than a
  styling choice.
