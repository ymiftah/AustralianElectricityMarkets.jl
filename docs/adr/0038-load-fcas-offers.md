# 0038. Load FCAS offers

## Status

Accepted

## Context

Loads enable FCAS in NEMDE: scheduled loads and the non-scheduled ancillary-service and
demand-response loads (`ASTHYD1` on RAISE6SEC, `APD01` on the three raise contingency services,
`AS*`, `DRVIOT*`). In the nempy database for 2026-06-21 18:00, `DISPATCHTYPE = LOAD` units are 203
of 628 MW of enabled RAISE6SEC, and `ASTHYD1`'s 52.45 MW equals the right-hand side of the binding
`F_T_AUFLS2_R6`. Until now `set_fcas_bids!` attached bids to generators and storage only,
`add_fcas_services!` left decremental bidders on other devices out, and the FCAS formulation threw
for a decremental bid on a non-`Storage` device (ADR 0017 recorded the scheduled-load form as
unreachable). Every generic constraint with a load FCAS term dropped it, so requirements fell on
other providers.

In the June 2026 cache, of the 62 `LOAD` DUIDs that bid FCAS on 2026-06-21, 59 are non-scheduled and
3 are scheduled (and bid zero availability). All bid in the `LOAD` direction. Non-scheduled loads
have no `ENERGY` bid, `DISPATCHLOAD` rows with `AVAILABILITY = INITIALMW = 0`, and an FCAS trapezium
that is the point `(0, 0, 0, 0)` with `MaxAvail` the offered MW. `DUDETAILSUMMARY` and `DUDETAIL`
list them; `DUALLOC`/`GENUNITS` carry only 16 of 84.

## Decision

- **Component.** A load is the `InterruptiblePowerLoad` of ADR 0032 and its `ActivePowerVariable`
  is consumed MW, so it is the "Energy Dispatch Target" of AEMO *FCAS Model in NEMDE* §6.1-§6.3
  with the Energy axis relabelled "Consumption" (footnotes 4-7). No new device type.
- **Non-scheduled loads.** `nem_system` builds every `DISPATCHTYPE = LOAD` unit, tagged
  `ext["non_scheduled"]` when `SCHEDULE_TYPE = NON-SCHEDULED`, unavailable. `set_market_bids!`
  leaves them alone (they have no energy bid, so the zero `LoadCost` stays) and `set_fcas_bids!`
  makes a load available when it attaches an FCAS bid to it. A non-scheduled load without FCAS
  bids stays out of the model. Its energy is held at zero by `AVAILABILITY = 0`, which is how NEMDE
  sees it: §5's pre-conditions hold (`EnablementMin = 0 <= InitialMW = 0 <= EnablementMax = 0`) and
  its slope coefficients are zero, so the joint rows reduce to `0 <= 0` and `MaxAvail` is the only
  bound.
- **Bids.** A `LOAD`-direction FCAS bid is attached to an `InterruptiblePowerLoad` under the
  `_decremental` series names, as for a battery's load side; a load carries no incremental series
  (`check_fcas_services` and `_fcas_direction` refuse one).
- **Formulation.** The device's energy term is its consumed MW (`ActivePowerVariable`, +1) in every
  row, and the slope coefficients are unchanged. The regulation targets swap: in a contingency
  service's joint capacity rows `LowerReg` enters the upper (`<= EnablementMax`) row and `RaiseReg`
  the lower row (§6.2), and §6.1's joint ramping rows read `consumption + LowerReg <= InitialMW +
  up` and `consumption - RaiseReg >= InitialMW - down`. This matches nempy's `dispatch_type = load`
  mapping in `joint_capacity_constraints`. Batteries keep the net-axis form of ADR 0017.
- **Generic constraints.** An FCAS term is `+1 x` the load's enablement of its region's service
  (Constraint Implementation Guidelines), found through the same `FCASService` lookup as for a
  generator. `RegionTerm`s with an FCAS `bid_type` include the region's loads; an `ENERGY`
  `RegionTerm` still aggregates generators and storage only.
- **Services.** `add_fcas_services!` attaches a decremental-only bidder when it is a `Storage`
  device or a `ControllableLoad`.

## Not modelled

- FCAS scaling inputs (§4: AGC enablement limits, ramp rate, UIGF) are not attached to loads, so a
  scheduled load's regulation trapezium is used as bid. The non-scheduled loads in the data offer
  contingency services on point trapeziums, where scaling is a no-op.
- `ACTUALAVAILABILITY` (the telemetered FCAS availability) is not applied to a load's `MaxAvail`;
  in the sampled intervals it equals the bid.
- Wholesale demand response units that bid `GEN` stay unavailable (ADR 0032).
