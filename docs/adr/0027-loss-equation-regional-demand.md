# 0027. Regional demand in the interconnector loss equations

## Status

Accepted

## Context

AEMO's inter-regional loss factor equations take regional demand as an input (Treatment of Loss
Factors, 2012, section 6 "Average Loss Factors" and section 7 "Loss Model"; Marginal Loss
Factors report, section 4 "Inter-regional loss equations": `Nd`, `Qd`, `Vd`, `Sd`).
LOSSFACTORMODEL.DEMANDCOEFFICIENT is "the coefficient applied to the region demand in the
calculation of the interconnector loss factor". The Treatment of Loss Factors document predates
five-minute settlement and bidirectional units, and no AEMO document states which quantity NEMDE
evaluates the equation at. nempy uses `INITIALSUPPLY + DEMANDFORECAST`, which also predates
bidirectional units.

## Decision

NEMDE's own case files settle it. In the NEMDE XML (nempy `xml_cache`, e.g.
`NEMSPDOutputs_2026060913200.loaded`) the loss equation is evaluated at the region's
`DemandForecast = InitialDemand + DF`, where `DF` is exactly `DISPATCHREGIONSUM.DEMANDFORECAST`
and

```text
InitialDemand = INITIALSUPPLY + sum over the region's BIDIRECTIONAL units of min(INITIALMW, 0)
```

so initial battery charging is subtracted. `read_demand` returns this as `LOSSDEMAND`;
`set_demand!` attaches it to each `PowerLoad` as a second series named `loss_demand`;
`_area_demand` reads that series when present and falls back to `max_active_power`. Energy
balance still clears at `TOTALDEMAND`. Unit type and region come from the `DUDETAILSUMMARY` row
in force at the interval (`START_DATE <= t < END_DATE`, latest archive), and `DISPATCHLOAD` is
read at `INTERVENTION = 0`.

## Evidence

- `read_demand`'s `LOSSDEMAND` reproduces the XML `DemandForecast` (`InitialDemand + DF`) over
  all 55 region-intervals of the 11 case files with a maximum absolute difference of 9.3e-6 MW,
  read from the cache with the shipped query.
- Back-solving the XML `InterconnectorPeriod` `LossDemandConstant` over 11 intervals gives a
  demand error of 4.7e-16 (NSW1-QLD1) and 3.4e-16 (VIC1-NSW1) with this definition, against
  4.5e-3 and 8.7e-4 for `TOTALDEMAND`, and 1.8e-2 for `INITIALSUPPLY + DEMANDFORECAST` (up to
  1021 MW apart in VIC1 while batteries charge).
- Published `MWLOSSES` against the modelled loss, 2026-06-01 to 2026-06-15, mean absolute error
  NSW1-QLD1 / VIC1-NSW1: 0.75 / 0.40 MW with `TOTALDEMAND`, 2.35 / 2.56 MW with
  `INITIALSUPPLY + DEMANDFORECAST`, 0.026 / 0.010 MW with this definition.

## Open follow-up

V-SA matches none of the definitions (residual about 0.011 to 0.018, not constant), probably a
term missing from the cached `LOSSFACTORMODEL`.
