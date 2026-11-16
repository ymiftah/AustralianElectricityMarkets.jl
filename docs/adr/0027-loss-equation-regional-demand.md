# 0027 Regional demand in the interconnector loss equations

## Status

Accepted

## What

- The loss equation is evaluated at `LOSSDEMAND`, not `TOTALDEMAND`:

```text
LOSSDEMAND = INITIALSUPPLY + DEMANDFORECAST + sum over the region's BIDIRECTIONAL units of min(INITIALMW, 0)
```

  so initial battery charging is subtracted from supply. Energy balance still clears at `TOTALDEMAND`.

- No AEMO document states which quantity NEMDE evaluates the equation at. AEMO's inputs are `Nd`, `Qd`, `Vd`, `Sd` (Marginal Loss Factors report, section 4; Treatment of Loss Factors 2012, sections 6 and 7), and `LOSSFACTORMODEL.DEMANDCOEFFICIENT` is "the coefficient applied to the region demand". Treatment of Loss Factors and nempy's `INITIALSUPPLY + DEMANDFORECAST` both predate bidirectional units.
- The definition is taken from NEMDE's own case files: the XML region `DemandForecast = InitialDemand + DF`, where `DF` is `DISPATCHREGIONSUM.DEMANDFORECAST`.

## How

- `read_demand` returns `LOSSDEMAND`; `set_demand!` attaches it to each `PowerLoad` as a second series `loss_demand`; `_set_loss_demand_coefficients!` turns the regional sums into the interchange's `"loss_demand_coefficient"` series (`loss_demand_coefficient`), which the loss formulation reads.
- Unit type and region come from the `DUDETAILSUMMARY` row in force at the interval; `DISPATCHLOAD` is read at `INTERVENTION = 0`.

## Why

- Against 11 NEMDE case files, this definition reproduces the XML `DemandForecast` to 9.3e-6 MW and back-solves `LossDemandConstant` to about 1e-16 for NSW1-QLD1 and VIC1-NSW1. `TOTALDEMAND` is off by 1e-3 and `INITIALSUPPLY + DEMANDFORECAST` by 2e-2 (up to 1021 MW apart in VIC1 while batteries charge).
- Modelled loss against published `MWLOSSES` (June 2026): mean absolute error 0.026 / 0.010 MW for NSW1-QLD1 / VIC1-NSW1, versus 0.75 / 0.40 with `TOTALDEMAND`.

## Open

- V-SA matches no definition (residual about 0.011 to 0.018, not constant), probably a term missing from the cached `LOSSFACTORMODEL` (see [0091](0091-interconnector-loss-input-assumptions.md)).
