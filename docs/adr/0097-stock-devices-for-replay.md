# 0097 Stock PowerSystems devices carry NEM unit data for replay

## Status

Accepted. Supersedes the device-type decision of [0093](0093-nem-device-types-and-offer-cost.md) (its `NEMOfferCost` decision stands) and the device-type parts of [0095](0095-typed-nem-system.md).

## What

- Replay systems use stock PowerSystems (PSY) devices. `NEM_DISPATCH_DEVICE_TYPES` is `ThermalStandard`, `HydroDispatch`, `RenewableDispatch`, `InterruptiblePowerLoad`, `EnergyReservoirStorage`, in that order. `operation_cost` is the stock zero cost.
- Each replay device carries a mutable `NEMUnitData` supplemental attribute (top-level `AustralianElectricityMarkets` module, so `IS.get_module` resolves it on deserialisation) holding `offer::NEMOfferCost` and `registration`, `telemetry`, `observed_state` (each `Union{Nothing, T}`).
- A device is a replay unit exactly when `has_nem_unit_data` holds, never by its Julia type. Regional systems carry no `NEMUnitData`. A system built without it is not a replay system, and there is no fallback.
- Every series-key field of the typed structs is the concrete `IS.StaticTimeSeriesKey`, never the abstract `IS.TimeSeriesKey`; a forecast key is not a valid value. `GenericConstraint.terms` is a `Vector` of the concrete term union.

## How

- `RegionalNetworkConfiguration` and `NEMDEConfiguration` share the device builders, which take a `replay` keyword. The regional build records the non-scheduled and commissioned flags on a load's `ext`; the replay build records them in `NEMRegistration` (`schedule_type`, `commissioned`).
- The NEMDE build attaches `NEMUnitData` right after each dispatch device is added, before registration, bids or unit conditions are written.
- Code reaches unit data through accessors (`get_registration`, `get_telemetry`, `get_observed_state`, their setters, `_nem_offer_cost`). They annotate the `get_supplemental_attributes` result, which InfrastructureSystems infers as `Any`.
- `template_nemde` assigns `NEMReplayDispatch` to each type in `NEM_DISPATCH_DEVICE_TYPES`. `check_template_against_sys` refuses a device with `NEMUnitData` under a formulation that is not an `AbstractNEMDispatch`. A stock device without unit data passes, is modelled by `NEMReplayDispatch` and is skipped by `nem_dispatch_devices`; no replay build creates one.

## Why

- Copies of the PSY device types existed only to hold a `NEMOfferCost` in `operation_cost`, and no formulation reads `operation_cost` on a replay device; the formulations are generic over `T <: PSY.StaticInjection`.
- Supplemental attributes are PSY's typed, serialised home for data a stock component does not model, and the NEM interconnector and MNSP structs already used them.
- Copies duplicated each PSY constructor and accessor set, recompiled every PSI method in the build and step path once per type, and made "is this a replay unit" a question about five types.
- The concrete key type removes runtime dispatch on every read at no cost, since every writer stores a static key.
