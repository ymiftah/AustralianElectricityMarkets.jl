# 0093 `NEMOfferCost` carries the bids; no `MarketBidCost`

## Status

Accepted. The device-type half of the original decision is superseded by [0097](0097-stock-devices-for-replay.md): replay devices are stock PowerSystems types. Band pricing is in [0071](0071-objective-only-penalty-and-band-costs.md) and [0101](0101-aem-writes-aemsim-reads.md).

## What

- A replay unit's bids live in a `NEMOfferCost <: PSY.OperationalCost`, held in the `offer` field of its `NEMUnitData` attribute. It holds `energy::Vector{NEMEnergyBid}` and `fcas::Vector{NEMFCASBid}`; each bid field is a static value or a key of a series on the device.
- AEMSim prices energy bands itself in `AbstractNEMDispatch` (`EnergyOfferBandVariable`, band width and price parameters, the band constraint with its CVP slacks). Nothing reads `operation_cost` on a replay device.
- The PowerSystems fork pin is dropped: the registered PowerSystems (`5.12.4`) is used.

## Why

- `MarketBidCost` holds only part of an AEMO offer (no `MAXAVAIL`, fixed loading or FCAS trapezium) and PSI does not price it the NEM way: AEMSim already overrode PSI's private cost internals for offer-mismatch slacks, batteries and scheduled loads.
- PSI's service-bid reader covers `PSY.Reserve` subtypes only, takes the first band price, ignores quantities and has no load side, so FCAS uses its own `FCASMarket` formulation.
- `MarketBidCost` is a concrete struct. The `operation_cost` field of stock `ThermalStandard`, `RenewableDispatch`, `HydroDispatch`, `HydroTurbine`, `InterruptiblePowerLoad` and `EnergyReservoirStorage` is a closed union with it, so attaching an `OperationalCost` subtype to a stock device needs an upstream PowerSystems change. A supplemental attribute avoids that ([0097](0097-stock-devices-for-replay.md)).
- Rejected containers, as in [0067](0067-nem-offer-views.md): series on a supplemental attribute are skipped by PSI's per-step parameter update, and one `PSY.Service` per unit, market and side means about a thousand service models.
