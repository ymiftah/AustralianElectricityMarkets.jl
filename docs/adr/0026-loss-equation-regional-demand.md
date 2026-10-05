# 0026. Regional demand in the interconnector loss equations

## Status

Accepted

## Context

AEMO's inter-regional loss factor equations take "total demand in each region" as inputs
(Treatment of Loss Factors, section 5 "Average loss factors and loss model"; Marginal Loss
Factors, section 4 "Inter-regional loss equations": `Nd`, `Qd`, `Vd`, `Sd` are regional demand).
LOSSFACTORMODEL.DEMANDCOEFFICIENT is "the coefficient applied to the region demand in the
calculation of the interconnector loss factor". No AEMO document states which DISPATCHREGIONSUM
column NEMDE evaluates it at. The candidates are `TOTALDEMAND` ("Demand (less loads)", a
post-solve figure), and `INITIALSUPPLY + DEMANDFORECAST` ("Sum of initial generation and import
for region" plus the "5 minute forecast adjust"), the demand NEMDE holds as an input before it
solves. The loss equation is an input to the solve, so a post-solve figure is the wrong side of
the causal arrow.

## Decision

- The loss equations are evaluated at `INITIALSUPPLY + DEMANDFORECAST`, falling back to
  `TOTALDEMAND` where either is missing. This is nempy's `loss_function_demand`, the only
  published replication of NEMDE, and the AEMO text does not contradict it. It is a departure
  from the previous `TOTALDEMAND`, not from a stated AEMO rule.
- `read_demand` returns it as `LOSSDEMAND`; `set_demand!` attaches it to each `PowerLoad` as a
  second series named `loss_demand`; `_area_demand` reads that series when present and falls
  back to `max_active_power`. Energy balance still clears at `TOTALDEMAND`.
- The effect is small: demand coefficients are about 1e-5 per MW, so a 175 MW difference moves
  the slope by about 2e-3. This change is about the correct definition, not a fidelity fix.

## Reported loss disagreements

Reported `MWLOSSES` of 874 MW (NSW1-QLD1, 2026-06-03), 185 MW (N-Q-MNSP1) and 285 MW (V-SA,
2026-06-09) against 20-60 MW analytic at the solved flow are not a units or alignment defect.
Static reading found: flow, loss, segment widths and slopes are all per-unit of the system
base (`_to_pu` scales breakpoints by `1/base` and the 1/MW coefficients by `base`);
`_area_demand` runs under `SYSTEM_BASE` during `build!` and is tested against the hand-computed
curve; the MWFLOW/MWLOSSES time alignment is the dispatch interval end on both sides. The
cause is the free loss variable with unordered segments. Flow fixes only the sum of the segment
variables, and the loss is `base_loss + sum(slope_s * seg_s)`, so wherever a regional price is
non-positive the LP is free to place flow in the steepest segments and dissipate energy. The
segment encoding is left as is here.
