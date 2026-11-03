# 0091. Interconnector loss input assumptions

## Status

Accepted. Records assumptions previously described on the removed `docs/src/interconnector-losses.md`
page. The loss formulation itself is in 0022, 0027 and 0031.

## Context

The loss equation of each interconnector is built from `INTERCONNECTORCONSTRAINT`
(`LOSSCONSTANT`, `LOSSFLOWCOEFFICIENT`, `FROMREGIONLOSSSHARE`), `LOSSFACTORMODEL`
(`REGIONID`, `DEMANDCOEFFICIENT`) and `LOSSMODEL` (`MWBREAKPOINT`), each selected by effective date
and version. Monthly archive dates identify cache partitions only; they do not select the applicable
equation. Equations change every financial year (1 July to 30 June). The cached tables do not always
match AEMO's published Marginal Loss Factors reports, and AEMO does not say how NEMDE fills gaps.

V-SA illustrates the yearly changes. Coefficients multiply flow `f` and regional demands `Vd`, `Sd`,
`Nd`, in MW:

| Financial year / configuration | Constant | Flow | VIC demand | SA demand | NSW demand | Report |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| 2021-22 | 1.0121 | 3.5511e-4 | -4.5341e-7 | -6.1623e-6 | Absent | [§3 p. 50, Table 21 p. 52](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/loss_factors_and_regional_boundaries/2021-22/marginal-loss-factors-for-the-2021-22-financial-year.pdf?rev=f5097f1dc1b14c649aa9541e8c8edb30&sc_lang=en) |
| 2022-23 | 1.0181 | 3.5925e-4 | -3.4191e-6 | 1.8182e-8 | Absent | [§3 p. 49, Table 21 p. 52](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/loss_factors_and_regional_boundaries/2022-23/marginal-loss-factors-for-the-2022-23-financial-year.pdf?rev=a057c7f9c36b48f09e59dd283906db4f&sc_lang=en) |
| 2023-24 | 1.0166 | 3.4263e-4 | -1.2753e-6 | -1.5712e-6 | Absent | [§3 p. 53, Table 22 p. 56](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/loss_factors_and_regional_boundaries/2023-24/marginal-loss-factors-for-the-2023-24-financia-year-pdf.pdf?rev=6e56696685cc4cc482f8c981502d72c5&sc_lang=en) |
| 2024-25 | 0.9936 | 2.2992e-4 | -1.6267e-5 | 6.2183e-5 | Absent | [§3 p. 54, Table 26 p. 57](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/loss_factors_and_regional_boundaries/2024-25-financial-year/mlfs-for-the-2024-25-financial-year.pdf?la=en) |
| 2025-26 | 0.9721 | 2.6801e-4 | -1.4896e-5 | 5.1080e-5 | 1.6981e-6 | [§3 p. 56, Table 25 p. 59](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/loss_factors_and_regional_boundaries/2025-26-marginal-loss-factors/marginal-loss-factors-for-the-2025-26-fin-year.pdf?la=en) |
| 2026-27 before NSW1-SA1 market establishment | 0.9742 | 2.29e-4 | -1.09e-5 | 6.63e-5 | -2.22e-6 | [§3.3.1 pp. 61-62](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/loss_factors_and_regional_boundaries/2026-27/marginal-loss-factors-for-the-2026-27-financial-year.pdf) |
| 2026-27 upon NSW1-SA1 market establishment | 1.0288 | 2.57e-4 | -1.27e-5 | 3.44e-5 | 1.00e-7 | [§3.3.2 p. 62](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/loss_factors_and_regional_boundaries/2026-27/marginal-loss-factors-for-the-2026-27-financial-year.pdf) |

## Decision

- **Missing equation fields** (`src/system/interconnectors.jl`): a missing `LOSSCONSTANT` is 1.0, a
  missing `LOSSFLOWCOEFFICIENT` is 0.0 and a missing `FROMREGIONLOSSSHARE` is 0.5. An absent demand
  term contributes zero unless a patch below applies. Published coefficients, including zero, take
  precedence. These are reconstruction assumptions, not AEMO's stated values.
- **V-SA NSW demand term, FY2025-26** (`_DEMAND_COEFFICIENT_PATCHES`): the audited July 2025 and
  June 2026 `LOSSFACTORMODEL` archives omit the V-SA/NSW1 term that the FY2025-26 report publishes.
  The package adds `1.6981e-6` for 1 July 2025 to 30 June 2026, only where the table has no value
  for that pair. The cause of the omission is unknown; it is not a general rule for filling absent
  terms.
- **Basslink loss share** (`_LOSS_SHARE_OVERRIDES`): `FROMREGIONLOSSSHARE` for `T-V-MNSP1` is set
  to 1, as nempy does to match NEMDE, so without directional offers all Basslink losses fall on
  Tasmania. With offers, the sending region supplies the whole loss and each end is referred by its
  terminal loss factor (FY2025-26 report §5.1 p. 63).
- **Static proportioning** of regulated losses between the two regions follows FY2026-27 report §6
  p. 78.

## Project EnergyConnect

PEC Stage 1 uses an isolated Victorian "micro-slice" between NSW and SA, represented in the market
through VNI and V-SA. The FY2025-26 report associates the extra NSW demand term with PEC modelling
(§3 footnote 11; Appendix A2.6 Table 41 note C). PEC Stage 2 removes the slice and establishes
NSW1-SA1, a loop among NSW, Victoria and SA. AEMO's FY2026-27 study assumes a transition around
October 2026 and publishes separate VNI and V-SA equations plus a new NSW-SA equation, conditional on
market establishment (§3-4; Appendix A2.5.2 pp. 95-96).

A forecast transition date does not establish the historical topology of an interval. A Stage 2
replay needs the published network, loss equations and generic constraints for that configuration.
The report's loop-flow regression was built for its MLF study and does not by itself define a
dispatch constraint.

## Consequences

- Replays from 1 July 2025 to 30 June 2026 use the patched V-SA equation; a later archive that
  carries the term takes precedence.
- FY2026-27 regulated Basslink treatment and PEC Stage 2 intervals need validation against the
  applicable configuration before they can be trusted.
