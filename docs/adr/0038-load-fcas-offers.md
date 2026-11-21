# 0038 Load FCAS offers

## Status

Accepted. Scheduled loads are in [0032](0032-scheduled-loads-and-unresolved-constraint-terms.md); the net-axis battery form is in [0017](0017-fcas-market-formulation.md).

## What

- Loads enable FCAS in NEMDE: scheduled loads and the non-scheduled ancillary-service and demand-response loads (`ASTHYD1`, `APD01`, `AS*`, `DRVIOT*`). `DISPATCHTYPE = LOAD` units were 203 of 628 MW of enabled RAISE6SEC on 2026-06-21 18:00, and `ASTHYD1`'s 52.45 MW equals the RHS of the binding `F_T_AUFLS2_R6`.
- A load is the `InterruptiblePowerLoad` of 0032 and its `ActivePowerVariable` is consumed MW, i.e. the "Energy Dispatch Target" of AEMO *FCAS Model in NEMDE* §6.1-§6.3 with the energy axis relabelled "Consumption" (footnotes 4-7). No new device type.

## How

- `nem_system` builds every `DISPATCHTYPE = LOAD` unit, unavailable. A non-scheduled load (no `ENERGY` bid, zero `LoadCost`) is flagged by `is_non_scheduled_load` and is made available only when it is commissioned and carries an FCAS bid; otherwise it stays out of the model.
- The dispatch-limit series pin a non-scheduled load's energy to zero (initial MW, ramp rates, availability, upper limit), whatever `DISPATCHLOAD` meters: its consumption is already in regional demand, and a ramp floor at a metered 0.1 MW would double count. With energy 0 the §5 pre-conditions hold and the joint rows reduce to `0 <= 0`, leaving `MaxAvail` as the only bound.
- A `LOAD`-direction FCAS bid is attached under the `_decremental` series names; a load carries no incremental series.
- Formulation: consumed MW enters every row with +1 and the slope coefficients are unchanged. Regulation targets swap: in a contingency service's joint capacity rows `LowerReg` enters the upper (`<= EnablementMax`) row and `RaiseReg` the lower row (§6.2). §6.1 joint ramping reads `consumption + LowerReg <= InitialMW + up` and `consumption - RaiseReg >= InitialMW - down`. This matches nempy's `dispatch_type = load` in `joint_capacity_constraints`.
- The AGC ramp-rate series of a load swaps sides (`LowerReg` reads the ramp-up rate, `RaiseReg` the ramp-down rate).
- `add_fcas_services!` attaches a decremental-only bidder when it is a `Storage` device or a `ControllableLoad`. A generic-constraint FCAS term is `+1 x` the load's enablement through the same `FCASService` lookup; an FCAS `RegionTerm` includes loads, an `ENERGY` one does not.

## Departure from nempy

- For the ramping row nempy gives a load's `raise_reg >=` row the ramp-up rate (`markets.py` 1529-1537); this package follows AEMO and uses the ramp-down rate.

## Not modelled

- FCAS scaling inputs (§4) are not attached to loads, so a scheduled load's regulation trapezium is used as bid. The non-scheduled loads in the data offer contingency services on point trapeziums, where scaling is a no-op.
- `ACTUALAVAILABILITY` is not applied to a load's `MaxAvail`; in the sampled intervals it equals the bid.
- Wholesale demand response units that bid `GEN` stay unavailable (0032).
