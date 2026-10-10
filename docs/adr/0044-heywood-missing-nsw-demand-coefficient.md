# 0044. Restore the missing 2025 Heywood NSW demand coefficient during model assembly

## Status

Accepted

## Context

AEMO's *Marginal Loss Factors: Financial Year 2025-26* (2025 report), section 3, page 56, gives
the V-SA loss factor with an NSW demand term of `1.6981e-6 * NSW_demand`. Table 25 on page 59 and
section 4 on page 60 corroborate the regional loss-factor inputs and their demand dependence.
The published `LOSSFACTORMODEL` rows effective 2025-07-01, version 1 omit NSW1. A fresh June 2026
MMSDM archive has the same omission, while the July 2026 model publishes a different NSW
coefficient, so the correction must be tied to the exact missing version.

Sources: [AEMO 2025-26 report](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/loss_factors_and_regional_boundaries/2025-26-marginal-loss-factors/marginal-loss-factors-for-the-2025-26-fin-year.pdf?la=en)
and [AEMO June 2026 LOSSFACTORMODEL archive](https://nemweb.com.au/Data_Archive/Wholesale_Electricity/MMSDM/2026/MMSDM_2026_06/MMSDM_Historical_Data_SQLLoader/DATA/PUBLIC_ARCHIVE%23LOSSFACTORMODEL%23FILE01%23202606010000.zip).

## Decision

Keep `read_interconnector_demand_coefficients` faithful to the published rows. During loss-model
assembly, retain effective date and version metadata and add the report's NSW coefficient only
when V-SA resolves to 2025-07-01/version 1 and has no NSW1 row. Never replace a published value.

## Consequences

The assembled 2025-26 Heywood model includes the report's three-region demand equation, while raw
data readers and later model versions retain AEMO's published values. The report's page 56 equation
and the comparison documented in
[`interconnector-loss-fixes-2026-10-10.md`](../validation/interconnector-loss-fixes-2026-10-10.md)
are the source for this correction.
