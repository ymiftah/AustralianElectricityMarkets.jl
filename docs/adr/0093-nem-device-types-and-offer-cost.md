# 0093. NEM device types and `NEMOfferCost` replace `MarketBidCost`

## Status

Accepted. Supersedes parts of [0067](0067-nem-offer-views.md) and
[0084](0084-native-sienna-recurrent-updates.md), listed under Supersedes.

## Context

Replay systems carried each unit's bid in a PowerSystems `MarketBidCost`, with the other parts of
the bid (`MAXAVAIL`, fixed loading, FCAS trapezium) as unrelated named series. PowerSimulations
(PSI) priced energy from the `MarketBidCost`, and a fork of PowerSystems (PSY) was needed to carry
the FCAS service bids.

## Why not stock PowerSystems types

`MarketBidCost` as the bid:

- It holds one part of an AEMO offer: curves, initial inputs and no-load, start-up and shut-down
  costs. `MAXAVAIL`, fixed loading and the FCAS trapezium have no field, and daily `PRICEBAND`
  values are copied to every interval.
- PSI does not price it the NEM way. AEMSim already overrode the private `_add_pwl_constraint!`,
  `_add_variable_cost_to_objective!` and `_add_vom_cost_to_objective!` to add offer-mismatch slacks
  and handle batteries and scheduled loads.
- PSI's only service-bid reader applies to `PSY.Reserve` subtypes, takes the first band price,
  ignores quantities and has no load side, so NEM FCAS needed its own `FCASMarket` formulation and
  never used PSI's reader.
- Carrying FCAS service bids needed PSY fork changes (device scaling, a decremental side, lookups
  independent of the energy curves, JSON loading of `MarketBidCost(0.0, ..., 0.0)`) and PSI fork
  changes (#11, #13) that exist only for this.

A custom cost type on stock devices:

- `MarketBidCost` is a concrete struct and cannot be subtyped.
- The `operation_cost` field of `ThermalStandard`, `RenewableDispatch`, `HydroDispatch`,
  `HydroTurbine`, `InterruptiblePowerLoad` and `EnergyReservoirStorage` is a closed
  `Union{<own cost>, MarketBidCost}` in generated structs, so a new `OperationalCost` subtype cannot
  be attached without changing PowerSystems upstream.

Other containers stay rejected as in 0067: series on a supplemental attribute are skipped by PSI's
per-step parameter update, and one `PSY.Service` per unit, market and side means about a thousand
service models.

## Why NEM device types

The union is a property of PSY's concrete structs, not of its abstract types. A struct subtyping
`PSY.ThermalGen`, `PSY.HydroGen`, `PSY.RenewableGen`, `PSY.Storage` or `PSY.ControllableLoad` can
declare `operation_cost::NEMOfferCost` and still answers queries on the abstract types, reaches code
that dispatches on them, and serializes because it lives in the top-level
`AustralianElectricityMarkets` module. The cost is writing the unit-aware PSY accessors for each
type and ensuring PSI only meets them through AEMSim formulations.

## Decision

- Replay systems (`NEMDEConfiguration`) hold `NEMThermalGen`, `NEMHydroGen`, `NEMRenewableGen`,
  `NEMStorage` and `NEMLoad`. `RegionalNetworkConfiguration` keeps the stock types.
- `operation_cost` is a `NEMOfferCost` holding the keys of the energy and FCAS offer series, the
  `MAXAVAIL` and trapezium series, and the fixed-load series. Series names are unchanged.
- `set_energy_offer!` and `set_fcas_offer!` store the `PiecewiseStepData` series and record the key.
  `get_energy_offer` and `get_fcas_offer` read through `NEMOfferCost`.
- AEMSim prices energy bands itself in `AbstractNEMDispatch`: `EnergyOfferBandVariable`, band width
  and price parameters, `EnergyOfferBandConstraint` with the existing CVP slacks, and a cost target
  of price times base power times interval hours (`+1` for `GEN`, `-1` for `LOAD`). The tie-break
  rows read the same band variables.
- `check_template_against_sys` rejects a NEM device type under a formulation that is not an
  `AbstractNEMDispatch`.
- The PowerSystems fork pin is dropped. The registered PowerSystems 5.12.4 contains
  Sienna-Platform/PowerSystems.jl#1832, which PSI `81c0259` relies on. The PSI fork (`81c0259`)
  and IS fork pins are unchanged.

## Behaviour

Dispatch, energy prices, interconnector flows and the objective match the pre-change baseline on
the 2026-06-04 window within 1e-6. FCAS prices differ in three duals changed earlier on this
branch by the FCAS offer rework, and they now match AEMO published prices: TAS1 `RAISEREG` at 04:05
and SA1 `RAISE6SEC` and `RAISE60SEC` at 04:15. TAS1 `RAISEREG` also flips between 4.72 and 5.72 at
one interval from capture to capture, a pre-existing degenerate dual. One interval showed
`GPWFWST1` dispatch and `T-V-MNSP1` losses differing by about 1.06e-6 once (solver tolerance).

`get_operation_cost(device)` is a `NEMOfferCost` on replay systems, and code that asked for
`ThermalStandard` and similar now asks for the NEM type or its abstract parent.

## Dependencies after the change

| Dependency | State |
| --- | --- |
| PowerSystems | Registered `5.12.4`; fork changes (#5, #6, `9ea184c2`, `51abe93b`, #7) not needed |
| PSI #11, #13 | Not exercised; drop when the PSI stack is next rebuilt |
| PSI #3, #10, #12 | Still required (coefficient, named and cost parameters) |
| PSI #7, #8, #9, #14, HDF5 escape; IS fork | Unchanged |

## Supersedes

- 0067: the device-series-only storage of offers and the stock-device read-time views. Offers are
  still device-owned named series, but `get_energy_offer` and `get_fcas_offer` read through the
  keys of `NEMOfferCost`. The rejection of an `OperationalCost` subtype on stock devices is
  replaced by the NEM device types.
- 0084: the PSY fork row (decremental service bids, device-scaled service bids, independent
  lookups) and "Energy offers: PSI's native `MarketBidCost` path". FCAS offers are no longer PSY
  service bids; energy bands are priced by AEMSim.

## Follow-up

- FCAS price non-uniqueness: degenerate duals such as TAS1 `RAISEREG` need a deterministic dual
  selection. This is separate from this work.
- Move the `ext` classification flags into NEM type fields.
- Rebuild the PSI fork stack without #11 and #13, then re-pin.
- Close fork PRs PSY #5, #6, #7 and decide on upstream PSY #1843.
