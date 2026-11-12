# 0097. Stock PowerSystems devices carry NEM unit data for replay

## Status

Accepted. Supersedes the device-type decision of [0093](0093-nem-device-types-and-offer-cost.md)
(its `NEMOfferCost` and band-pricing decisions stand) and the device-type parts of
[0095](0095-typed-nem-system.md) (every other rule of 0095 and of
[0096](0096-per-step-state-updates.md) stands).

## Context

ADR 0093 introduced five NEM device types (`NEMThermalGen`, `NEMHydroGen`, `NEMRenewableGen`,
`NEMLoad`, `NEMStorage`) as copies of their PowerSystems (PSY) counterparts. The only reason was
`operation_cost`: on a stock device it is a closed `Union{<own cost>, MarketBidCost}`, so it cannot
hold a `NEMOfferCost`. ADR 0095 then gave the same types the struct fields `registration`,
`telemetry` and `observed_state`.

Two facts make the copies unnecessary:

- No formulation reads `operation_cost` on a replay device. AEMSim prices energy bands from the
  bid series itself (ADR 0093, band pricing), and its formulations are generic over
  `T <: PSY.StaticInjection`; none dispatches on a NEM device type.
- PSY already has a typed, serialised home for data a stock component does not model: supplemental
  attributes. The branch used it for `NEMDispatchInputs`, `NEMFCASInputs` and every interconnector
  and MNSP struct.

The copies had costs. Each type duplicated a PSY constructor and its accessors, every PSI method in
the build and step path compiled once more per type, and code that should have asked "is this a
replay unit" asked "is this one of five types". A review after the typed-system rebuild found that
the build-time and per-step regressions it was investigating were implementation issues, and that
the device types themselves bought nothing PSY and PSI did not already provide.

## Decision

### Stock types in replay systems

| Deleted NEM type | Stock type |
| --- | --- |
| `NEMThermalGen` | `PSY.ThermalStandard` |
| `NEMHydroGen` | `PSY.HydroDispatch` |
| `NEMRenewableGen` | `PSY.RenewableDispatch` |
| `NEMLoad` | `PSY.InterruptiblePowerLoad` |
| `NEMStorage` | `PSY.EnergyReservoirStorage` |

`NEM_DISPATCH_DEVICE_TYPES` is that stock tuple, in that order. `operation_cost` on a replay device
is the stock zero cost the regional builder already uses. `RegionalNetworkConfiguration` and
`NEMDEConfiguration` share one set of device builders. The internal builders take a `replay` keyword
in place of the removed `nem_types`: the regional build records the non-scheduled and commissioned
flags on the load's `ext`, while the replay build records them on its `NEMRegistration` (the
`schedule_type` and `commissioned` fields), which lives in the device's `NEMUnitData`.

### `NEMUnitData`

A mutable supplemental attribute in the top-level `AustralianElectricityMarkets` module (so that
`IS.get_module` resolves it on deserialisation) holds what the NEM types held as fields:
`offer::NEMOfferCost`, `registration`, `telemetry` and `observed_state`, the last three
`Union{Nothing, T}`. The NEMDE build attaches one to every dispatch device right after the device is
added, before registration, bids or unit conditions are written. Regional systems carry none.

A device is a replay unit exactly when it carries a `NEMUnitData` (`has_nem_unit_data`). Code
reaches unit data only through the accessors (`get_registration`, `get_telemetry`,
`get_observed_state`, their setters, `_nem_offer_cost`); the type of the device is never the test.
A system built before this change has no `NEMUnitData` and is not a replay system; there is no
fallback.

### AEMSim

`template_nemde` keeps assigning `NEMReplayDispatch` to each type in `NEM_DISPATCH_DEVICE_TYPES`.
`check_template_against_sys` refuses a device that carries `NEMUnitData` under a formulation that is
not an `AbstractNEMDispatch`, and accepts a stock device without unit data under a stock
formulation.

### Concrete series-key fields

Every series-key field of the typed structs (bids, telemetry, observed state, MNSP and
interconnector data, generic constraints, dispatch and FCAS inputs) is declared with the concrete
`IS.StaticTimeSeriesKey`, not the abstract `IS.TimeSeriesKey`. Every writer stores a static key, so
the narrower type changes no value; it removes runtime dispatch on every read. A forecast key is not
a valid value for these fields. `GenericConstraint.terms` is a `Vector` of the concrete term union.

## Consequences

- PSY machinery is used as designed: stock constructors, accessors, serialisation and
  `TimeSeriesParameter` reads; the series stay on the device.
- Unit-data reads go through `get_supplemental_attributes`, which InfrastructureSystems infers as
  `Any`; the accessors annotate the result to keep callers type-stable.
- A stock device of a dispatch type without unit data is not a replay unit. Under `template_nemde` it is
  modelled by `NEMReplayDispatch`, passes `check_template_against_sys`, and is skipped by
  `nem_dispatch_devices`; no replay build creates one.
- Results are unchanged except for one degenerate FCAS price pair; the gate is recorded below.

## Verification

Recorded on 2026-11-11.

- Results: the 2026-06-04 04:05-06:00 replay (24 intervals) against the `51940d8` baseline at atol
  `1e-6`. Dispatch, regional prices and interconnector flows and losses agree within `3.1e-12`.
  Two of 1,200 FCAS prices differ: at 05:05 in SA1 the RAISE6SEC and RAISE60SEC prices swap
  (0.09 and 0.0772 $/MWh). The interval is degenerate. Solved alone, both trees return the same
  objective (`-628021.5111679265`) and the same swapped pair, so the baseline reaches AEMO's pair
  (RAISE6SEC 0.09, RAISE60SEC 0.07716) only through the solver state of the earlier steps of the
  simulation. The difference is accepted as a tie between optimal duals, as for ADR 0094.
- The typing pass that followed (concrete key fields, annotated reads, typed device loops) is
  bit-identical to the stock-device tree on the same replay.
- JSON and HDF5 round trip of the 2026-06-04 replay system: 0 mismatches over 528 replay units
  (registration, telemetry, observed state, dispatch inputs and 7,222 offer keys); all 706
  `NEMUnitData` attributes survive two reloads.
- Validation warnings during the 2026-06-04 build: 2,312 before, 1,606 with stock devices (the 706
  per-device "does not exist in validation configuration" warnings for the NEM types are gone),
  and 11 once NEM services are added without validation.
- Toggling `runchecks` around each service add is silent: the PowerSystems Info line it logs is suppressed.
- Warm `nem_system` for 2026-06-04 (288 intervals, three fresh processes): 12.11, 12.11 and
  12.15 s, 3.49 GiB allocated; the first build in each process took 73.8 s.
