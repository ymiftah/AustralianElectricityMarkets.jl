# 0044. Supply the 2025-26 Heywood NSW demand coefficient when MMSDM omits it

## Status

Accepted, bounded to the FY2025-26 V-SA model version.

## Context

AEMO's *Marginal Loss Factors: Financial Year 2025-26*, §3 p. 56, gives the V-SA equation as
`0.9721 + 2.6801e-4*VSAt - 1.4896e-5*Vd + 5.1080e-5*Sd + 1.6981e-6*Nd`. Footnote 11 says the
additional NSW demand term is included for FY2025-26 with PEC modeling.

The public MMSDM `LOSSFACTORMODEL` archive has no NSW1 row for V-SA effective 2025-07-01/version 1.
The raw July 2025 archive has only SA1 `5.108e-5` and VIC1 `-1.4896e-5` for that version; June 2026
repeats those historical values. Both archives match their corresponding caches by key and value.
The June 2026 archive also publishes the successor V-SA version effective 2026-07-01/version 1,
including NSW1 `-2.22e-6`, SA1 `6.63e-5`, and VIC1 `-1.09e-5`. These effective-date transitions
bound the report's FY2025-26 coefficient to 2025-07-01 inclusive through 2026-07-01 exclusive.
The report establishes the financial year; the MMSDM effective dates establish the runtime bounds.
Why the publication omits the report's NSW term remains unknown; applying the documented value
does not explain the source-table omission.

## Decision

Keep `read_interconnector_demand_coefficients` faithful to the published table. During model
assembly, supply `NSW1 => 1.6981e-6` only when all of the following match:

- `as_of` is in `[2025-07-01, 2026-07-01)`.
- The selected V-SA `INTERCONNECTORCONSTRAINT` is effective 2025-07-01/version 1 and has
  `LOSSCONSTANT = 0.9721` and `LOSSFLOWCOEFFICIENT = 0.00026801`.
- The selected V-SA `LOSSFACTORMODEL` rows are effective 2025-07-01/version 1 and contain the
  report's VIC1 and SA1 coefficients.
- No NSW1 coefficient is present. Any published NSW1 value, including zero, takes precedence.

The 2026-07-01 successor row is used as published. If an archive queried after that date still
resolves to the stale 2025 row, the report coefficient is not carried forward. The reader does not
infer another version or change raw query results.

## Evidence audit

- AEMO's report states FY2025-26 and footnote 11 ties the NSW term to PEC modeling; it does not
  state the literal runtime date bounds.
- The raw July 2025 archive has 422 rows and no V-SA/NSW1 row anywhere in its history. Its
  2025-07-01/version-1 rows are SA1 `5.108e-5` and VIC1 `-1.4896e-5`. Its SHA-256 is
  `67a7e343adb1b1b0c038eb91977ace592fd9d4ef55b3d0450ae910d840f1cbb5`. The cache has the same 422
  key/value rows, with no raw-only or cache-only rows.
- The raw June 2026 archive has 434 rows and the same 2025 V-SA rows, plus the successor
  2026-07-01/version-1 values above. Its SHA-256 is
  `371bf2a429ac557fb0a510cda62e0776a1614d9a74aa16dbc4b9ade05afe78be`. The cache matches all 434
  key/value rows.
- The selected-version query resolves the latest effective date/version per interconnector.
  Resolving by region cannot recover the omitted 2025 row because no older NSW1 row exists in
  either complete raw history.
- The 2025 V-SA `LOSSMODEL` entry has 121 breakpoints but blank `PERIODID` and `LOSSFACTOR` fields.
  `INTERCONNECTORCONSTRAINT` has the matching loss constant and flow coefficient but no regional
  demand field. No additional candidate table was identified in the June 2026 public archive index
  reviewed. AEMO's Data Model Report identifies `LOSSFACTORMODEL` as the intended table for
  interconnector demand coefficients.

## Sources

- AEMO, [*Marginal Loss Factors: Financial Year 2025-26*](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/loss_factors_and_regional_boundaries/2025-26-marginal-loss-factors/marginal-loss-factors-for-the-2025-26-fin-year.pdf?rev=87a79a393a1a40c7a7e0738908fe8b1e&sc_lang=en), §3 p. 56, footnote 11.
- AEMO, [July 2025 `LOSSFACTORMODEL` archive](https://nemweb.com.au/Data_Archive/Wholesale_Electricity/MMSDM/2025/MMSDM_2025_07/MMSDM_Historical_Data_SQLLoader/DATA/PUBLIC_ARCHIVE%23LOSSFACTORMODEL%23FILE01%23202507010000.zip).
- AEMO, [June 2026 `LOSSFACTORMODEL` archive](https://nemweb.com.au/Data_Archive/Wholesale_Electricity/MMSDM/2026/MMSDM_2026_06/MMSDM_Historical_Data_SQLLoader/DATA/PUBLIC_ARCHIVE%23LOSSFACTORMODEL%23FILE01%23202606010000.zip), and [June 2026 archive index](https://nemweb.com.au/Data_Archive/Wholesale_Electricity/MMSDM/2026/MMSDM_2026_06/MMSDM_Historical_Data_SQLLoader/).
- AEMO, [June 2026 `LOSSMODEL` archive](https://nemweb.com.au/Data_Archive/Wholesale_Electricity/MMSDM/2026/MMSDM_2026_06/MMSDM_Historical_Data_SQLLoader/DATA/PUBLIC_ARCHIVE%23LOSSMODEL%23FILE01%23202606010000.zip) and [June 2026 `INTERCONNECTORCONSTRAINT` archive](https://nemweb.com.au/Data_Archive/Wholesale_Electricity/MMSDM/2026/MMSDM_2026_06/MMSDM_Historical_Data_SQLLoader/DATA/PUBLIC_ARCHIVE%23INTERCONNECTORCONSTRAINT%23FILE01%23202606010000.zip).
- AEMO, [*Marginal Loss Factors: Financial Year 2026-27*](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/loss_factors_and_regional_boundaries/2026-27/marginal-loss-factors-for-the-2026-27-financial-year.pdf?rev=22b27d2eb0094634a424924bf8fc7675&sc_lang=en), §3.3.1.
- AEMO, [*Electricity Data Model Report*](https://visualisations.aemo.com.au/aemo/nemweb/MMSDataModelReport/), v5.7.0, effective 23 April 2026, `LOSSFACTORMODEL`, `LOSSMODEL`, and `INTERCONNECTORCONSTRAINT`.
