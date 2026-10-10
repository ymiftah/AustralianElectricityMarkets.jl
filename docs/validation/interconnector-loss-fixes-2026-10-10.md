# Interconnector loss fixes: validation evidence, 10 October 2026

This note records evidence for ADRs [0044](../adr/0044-heywood-missing-nsw-demand-coefficient.md), [0045](../adr/0045-zero-reference-interconnector-loss-chords.md), and [0047](../adr/0047-directional-mnsp-dc-loss-allocation.md). The pilot figures below are historical results from seven selected intervals, not a full-sample fidelity claim.

## Piecewise loss curves

Integrating the cached NEMDE XML segment factors from zero flow reproduces all 600 published losses in the 100-interval sample within these maximum absolute errors:

| Interconnector | Maximum error, MW |
| --- | ---: |
| N-Q-MNSP1 | 0.000004527875 |
| NSW1-QLD1 | 0.000005498917 |
| T-V-MNSP1 | 0.000004691698 |
| V-S-MNSP1 | 0.000006585684 |
| V-SA | 0.000005428857 |
| VIC1-NSW1 | 0.000005265198 |

For a quadratic coefficient `b` and adjacent breakpoints `a < 0 < z`, the chord's zero-flow intercept is `-b*a*z/2`. The sampled QNI chord (`a = -17 MW`, `z = 17 MW`, `b = 0.00017965`) has a 0.025959425 MW intercept. The VIC-NSW chord (`a = -44 MW`, `z = 3 MW`, `b = 0.00015761`) has a 0.01040226 MW intercept. Removing these offsets preserves the segment slopes. AEMO describes loss equations as the integral of `(MLF - 1)` from zero flow; the XML segment factors supply the sampled discrete curve. AEMO's publication does not specify the internal piecewise interpolation algorithm.

## Historical combined pilot

The production comparison driver solved seven selected intervals with the loss-curve fixes, directional MNSP allocation, and the report's Heywood NSW coefficient for FY2025-26. That coefficient is now bounded by the matching 2025-07-01/version-1 model through the published 2026-07-01 successor boundary. These combined results do not isolate the contribution of each fix. The runs used neither supplemental XML constraint definitions nor published flow limits. Over common original/pilot rows:

| Metric | Original | Loss-fix pilot |
| --- | ---: | ---: |
| Regional ROP mean absolute gap, $/MWh (35 rows) | 2.70852046 | 2.51402568 |
| Interconnector flow mean absolute gap, MW (42 rows) | 10.60437581 | 7.06980695 |
| Interconnector loss mean absolute gap, MW (42 rows) | 1.93485 | 1.18536 |

At 6 June 2026 17:40, the combined pilot's Heywood loss was 12.713372 MW against NEMDE's 12.713370 MW, compared with 9.676971 MW in the original run. This selected interval falls within the documented FY2025-26 coefficient window. At 9 June 2026 15:00, the reverse-Basslink maximum flow gap fell from 86.03755 MW to below 0.000008 MW. These observations check selected cases; they do not establish full-sample fidelity or explain unrelated dispatch differences.

## Limits

The implemented MNSP formulation has hard availability and offer-band bounds. It does not model MNSP ramp rows, fixed-load rows, or elastic capacity and band violation slacks. The 100 sampled XML intervals show zero NEMDE MNSP ramp, offer, and capacity violations, so they do not test those priorities under conflict.

The reverse-Basslink case is from June 2026, while AEMO's 2026-27 report describes Basslink as a regulated interconnector from 1 July 2026. This pilot does not validate the separate regulated-Basslink treatment.

## Sources

- AEMO, [*Marginal Loss Factors: Financial Year 2025-26*](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/loss_factors_and_regional_boundaries/2025-26-marginal-loss-factors/marginal-loss-factors-for-the-2025-26-fin-year.pdf?la=en), §3 p. 56 (V-SA demand coefficients), §4 p. 60 (loss integration), §5.1 p. 63 (Basslink).
- AEMO, [*Marginal Loss Factors: Financial Year 2026-27*](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/loss_factors_and_regional_boundaries/2026-27/marginal-loss-factors-for-the-2026-27-financial-year.pdf?rev=22b27d2eb0094634a424924bf8fc7675&sc_lang=en), §5.1 (regulated Basslink treatment from 1 July 2026).
- AEMO, [*Electricity Data Model Report*](https://visualisations.aemo.com.au/aemo/nemweb/MMSDataModelReport/), v5.7.0, effective 23 April 2026, `LOSSFACTORMODEL` and `MNSP_BIDOFFERPERIOD`.
