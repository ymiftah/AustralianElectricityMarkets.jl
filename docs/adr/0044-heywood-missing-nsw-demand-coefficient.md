# 0044. Investigate the missing 2025 Heywood NSW demand coefficient

## Status

Unresolved upstream data discrepancy; no correction is implemented.

## Context

AEMO's *Marginal Loss Factors: Financial Year 2025-26*, section 3, page 56, shows an NSW demand
term of `1.6981e-6 * NSW_demand` in the V-SA loss-factor equation. The public `LOSSFACTORMODEL`
archive does not contain a NSW1 row for V-SA effective 2025-07-01, version 1. This is not an
ingestion or cache omission: a fresh July 2025 archive contains only the SA1 and VIC1 rows for that
version, and the June 2026 archive contains the same historical rows. The cached June 2026
`LOSSFACTORMODEL` rows match the raw archive by key and value.

The July 2026 V-SA version does publish an NSW1 coefficient (`-2.22e-6`), matching AEMO's
2026-27 pre-PEC equation. It does not establish what value belongs in the 2025-26 MMSDM model.
`LOSSMODEL` and `INTERCONNECTORCONSTRAINT` provide no substitute demand coefficient: the former's
2025 V-SA rows have 121 breakpoints with `PERIODID` and `LOSSFACTOR` blank, while the latter's
V-SA rows contain the loss constant and flow coefficient but no regional demand field. The
June 2026 public archive index reviewed here lists no additional candidate table for regional
demand coefficients. AEMO's Electricity Data Model Report identifies `LOSSFACTORMODEL` as the
intended table for interconnector demand coefficients.

## Decision

Keep the public reader and assembled model faithful to the published `LOSSFACTORMODEL` rows. Do not
inject the report coefficient or infer it from another table. AEMO's public artifacts establish a
disagreement between the report and the MMSDM table, but do not explain why the row is absent. A
future correction requires authoritative clarification or corrected source data from AEMO.

NEMDE's `LossDemandConstant` input is an aggregate input value, not the missing regional demand
coefficient. A generic XML adapter could consume a supplied equation in future, but no such adapter
is implemented here.

## Evidence audit

- The raw July 2025 archive has 422 rows and no V-SA/NSW1 row anywhere in its history. For
  2025-07-01/version 1 it has SA1 `5.108e-5` and VIC1 `-1.4896e-5` only. Its SHA-256 is
  `67a7e343adb1b1b0c038eb91977ace592fd9d4ef55b3d0450ae910d840f1cbb5`. The July 2025 cache has
  the same 422 key/value rows, with no raw-only or cache-only rows.
- The raw June 2026 `LOSSFACTORMODEL` archive has 434 rows and the same V-SA history through
  2025-07-01; the cached June coefficient rows match the raw archive's keys and values. Its
  SHA-256 is `371bf2a429ac557fb0a510cda62e0776a1614d9a74aa16dbc4b9ade05afe78be`. Both have 434
  key/value rows, with no raw-only or cache-only rows.
- The current query resolves the latest effective date/version per interconnector. Resolving by
  region would not recover the 2025 NSW coefficient because there is no older NSW1 row in either
  complete raw history.
- The 2025 V-SA `LOSSMODEL` entry contains 121 breakpoints but blank `PERIODID` and `LOSSFACTOR`
  fields. `INTERCONNECTORCONSTRAINT` has a V-SA loss constant of `0.9721` and flow coefficient of
  `0.00026801`, with no NSW demand field. The archives' SHA-256 values are
  `ac347deaa74f4634a8ffcf7ff7a6579df268a832ef76a7b0fce7ae6bf3a6469d` and
  `3072ef8c8864168bdd9a74a37cf93ef046595ae292d8ebdb9814d224dc9b8509`, respectively.
- No additional candidate table was identified in the June 2026 public archive index reviewed.
  AEMO's Electricity Data Model Report identifies `LOSSFACTORMODEL` as the intended table for
  interconnector demand coefficients.

## Sources

- AEMO, [*Marginal Loss Factors: Financial Year 2025-26*](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/loss_factors_and_regional_boundaries/2025-26-marginal-loss-factors/marginal-loss-factors-for-the-2025-26-fin-year.pdf?la=en), §3 p. 56.
- AEMO, [July 2025 `LOSSFACTORMODEL` archive](https://nemweb.com.au/Data_Archive/Wholesale_Electricity/MMSDM/2025/MMSDM_2025_07/MMSDM_Historical_Data_SQLLoader/DATA/PUBLIC_ARCHIVE%23LOSSFACTORMODEL%23FILE01%23202507010000.zip).
- AEMO, [June 2026 `LOSSFACTORMODEL` archive](https://nemweb.com.au/Data_Archive/Wholesale_Electricity/MMSDM/2026/MMSDM_2026_06/MMSDM_Historical_Data_SQLLoader/DATA/PUBLIC_ARCHIVE%23LOSSFACTORMODEL%23FILE01%23202606010000.zip), and [June 2026 archive index](https://nemweb.com.au/Data_Archive/Wholesale_Electricity/MMSDM/2026/MMSDM_2026_06/MMSDM_Historical_Data_SQLLoader/).
- AEMO, [June 2026 `LOSSMODEL` archive](https://nemweb.com.au/Data_Archive/Wholesale_Electricity/MMSDM/2026/MMSDM_2026_06/MMSDM_Historical_Data_SQLLoader/DATA/PUBLIC_ARCHIVE%23LOSSMODEL%23FILE01%23202606010000.zip) and [June 2026 `INTERCONNECTORCONSTRAINT` archive](https://nemweb.com.au/Data_Archive/Wholesale_Electricity/MMSDM/2026/MMSDM_2026_06/MMSDM_Historical_Data_SQLLoader/DATA/PUBLIC_ARCHIVE%23INTERCONNECTORCONSTRAINT%23FILE01%23202606010000.zip).
- AEMO, [*Marginal Loss Factors: Financial Year 2026-27*](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/loss_factors_and_regional_boundaries/2026-27/marginal-loss-factors-for-the-2026-27-financial-year.pdf?rev=22b27d2eb0094634a424924bf8fc7675&sc_lang=en), §3.3.1.
- AEMO, [*Electricity Data Model Report*](https://visualisations.aemo.com.au/aemo/nemweb/MMSDataModelReport/), v5.7.0, effective 23 April 2026, `LOSSFACTORMODEL`, `LOSSMODEL`, and `INTERCONNECTORCONSTRAINT`.
