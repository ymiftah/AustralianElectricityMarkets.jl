# 0027. Regional demand in the interconnector loss equations

## Status

Accepted

## Context

AEMO's inter-regional loss factor equations take regional demand as an input (Treatment of Loss
Factors, 2012, section 6 "Average Loss Factors" and section 7 "Loss Model"; Marginal Loss
Factors report, section 4 "Inter-regional loss equations": `Nd`, `Qd`, `Vd`, `Sd` are regional
demand). LOSSFACTORMODEL.DEMANDCOEFFICIENT is "the coefficient applied to the region demand in
the calculation of the interconnector loss factor". The Treatment of Loss Factors document
predates five-minute settlement. No AEMO document states which DISPATCHREGIONSUM column NEMDE
evaluates the equation at. The candidates are `TOTALDEMAND` ("Demand (less loads)") and
`INITIALSUPPLY + DEMANDFORECAST` ("Sum of initial generation and import for region" plus the
"5 minute forecast adjust").

## Decision

- The loss equations are evaluated at `INITIALSUPPLY + DEMANDFORECAST`, falling back to
  `TOTALDEMAND` where either is missing. This is the reference open-source replication's
  choice (nempy `loss_function_demand`, demand.py: "the estimated regional demand, as
  calculated by initial supply + demand forecast"), and AEMO is silent on the column. It is a
  departure from the previous `TOTALDEMAND`, not from a stated AEMO rule.
- `read_demand` returns it as `LOSSDEMAND`; `set_demand!` attaches it to each `PowerLoad` as a
  second series named `loss_demand`; `_area_demand` reads that series when present and falls
  back to `max_active_power`. Energy balance still clears at `TOTALDEMAND`.
- The effect is small: demand coefficients are about 1e-5 per MW, so a 175 MW difference moves
  the slope by about 2e-3. This change is about the definition, not a fidelity fix.
