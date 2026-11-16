# 0091 Interconnector loss input assumptions

## Status

Accepted. The loss formulation itself is in [0022](0022-interconnector-loss-formulation.md), [0027](0027-loss-equation-regional-demand.md) and [0031](0031-interconnector-loss-contiguous-segment-fill.md).

## What

- Each interconnector's loss equation is built from `INTERCONNECTORCONSTRAINT` (`LOSSCONSTANT`, `LOSSFLOWCOEFFICIENT`, `FROMREGIONLOSSSHARE`), `LOSSFACTORMODEL` (`REGIONID`, `DEMANDCOEFFICIENT`) and `LOSSMODEL` (`MWBREAKPOINT`), selected by effective date and version. Archive month dates only identify cache partitions. Equations change each financial year (1 July to 30 June).
- The cached tables do not always match AEMO's Marginal Loss Factors reports, and AEMO does not say how NEMDE fills gaps. The assumptions below are reconstructions, not AEMO values.

## How

All in `src/system/interconnectors.jl`:

- **Missing fields**: a missing `LOSSCONSTANT` is 1.0, `LOSSFLOWCOEFFICIENT` 0.0 and `FROMREGIONLOSSSHARE` 0.5. An absent demand term is zero unless a patch applies. Published values, including zero, win.
- **V-SA NSW1 demand term** (`_DEMAND_COEFFICIENT_PATCHES`): the audited July 2025 and June 2026 `LOSSFACTORMODEL` archives omit the term the FY2025-26 report publishes (`1.6981e-6`; report section 3 p. 56, Table 25 p. 59). It is added for 1 July 2025 to 30 June 2026 only where the table has no value for the pair. The cause of the omission is unknown; this is not a general fill rule.
- **Basslink loss share** (`_LOSS_SHARE_OVERRIDES`): `FROMREGIONLOSSSHARE` of `T-V-MNSP1` is 1, as nempy does to match NEMDE. Without directional offers all Basslink losses fall on Tasmania. With offers the sending region supplies the whole loss and each end is referred by its terminal loss factor (FY2025-26 report section 5.1 p. 63).
- Static proportioning of regulated losses between regions follows the FY2026-27 report section 6 p. 78.

## Why

- Project EnergyConnect Stage 1 uses an isolated Victorian "micro-slice" between NSW and SA, represented through VNI and V-SA. The FY2025-26 report ties the extra NSW demand term to that modelling (section 3 footnote 11; Appendix A2.6 Table 41 note C).
- Stage 2 removes the slice and creates NSW1-SA1, a loop among NSW, Victoria and SA. The FY2026-27 report publishes separate VNI, V-SA and NSW-SA equations conditional on market establishment, assumed around October 2026 (section 3.3, Appendix A2.5.2 pp. 95-96).
- A forecast transition date does not fix an interval's historical topology, and the report's loop-flow regression is an MLF study tool, not a dispatch constraint. FY2026-27 Basslink treatment and Stage 2 intervals need validation against the applicable network, loss equations and generic constraints before they can be trusted.
- Replays from 1 July 2025 to 30 June 2026 use the patched V-SA equation; a later archive that carries the term takes precedence.
