# Task 4 report: initial-mode FCAS joint-ramping exemptions

## Implementation

For a represented `ThermalStandard`, the FCAS joint-ramping builder reads the existing device-model `"fast_start"` attribute. If that context has an input for the device whose preprocessed starting mode is 0, 1, or 2, both commitment and dispatch passes keep the existing vacuous joint-ramping row. Starting modes 3 and 4, ordinary devices, other device types, and absent fast-start contexts retain existing behavior. Joint-capacity and energy/regulation-capacity construction, enablement, and AGC capability reads are unchanged.

## Source-to-test matrix

| AEMO source rule | Test evidence |
| --- | --- |
| FCAS Model in NEMDE v3.0, §6.5 Table 3 footnote 19, p. 28: omit joint ramping for both fast-start solves when starting mode is 0, 1, or 2. | `fcas_market.jl`, “initial fast-start mode gates joint ramping in both dispatch passes”: builds actual FCAS models for modes 0–4 in both contexts and inspects the built `FCASJointRampingConstraint`; mode 2 also carries a planned target envelope in mode 3. |
| Modes 3 and 4 retain joint ramping; ordinary participants preserve behavior. | The same test asserts non-placeholder joint-ramping rows for modes 3 and 4. Existing “A.2 numbers”, “RAISEREG binding”, and “LOWERREG binding” tests continue to inspect/solve ordinary participant rows. |
| §6.2 joint capacity and §6.3 energy/regulation capacity remain applicable when §6.1 joint ramping is exempt. | The same test fixes energy at 460 MW and regulating FCAS at its 10 MW §6.3 limit. It confirms the exempt §6.1 row is a placeholder and both the regulation capacity row and the separate contingency joint-capacity row are present; solving binds both and leaves 10 MW contingency FCAS under the §6.2 ceiling. |
| Effective energy ramp inputs remain distinct from SCADA/AGC FCAS ramp capabilities and their interval scaling. | Existing `fast_start_toy.jl` “profile ramp envelopes preserve exact endpoints and startup anchors” checks the energy-ramp envelope; existing `fcas_market.jl` “A.2 numbers” checks the five-minute AGC caps in MW; “§6.4: the SCADA ramping cap follows AEMO's Table 3 timing” checks dispatch, 5-minute pre-dispatch, and 30-minute pre-dispatch behavior. This change does not alter either input path. |

The implementation follows the original [AEMO FCAS Model in NEMDE v3.0 PDF](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/dispatch/policy_and_process/fcas-model-in-nemde.pdf), effective 3 June 2024, §6.5, Table 3 footnote 19, p. 28. The local `nem-expert` extraction renumbers the footnote as 11.

## Verification

- Red check before the predicate: `JULIA_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 JULIA_NUM_PRECOMPILE_TASKS=1 JULIA_PKG_PRECOMPILE_AUTO=0 julia --project=AustralianElectricityMarketsSimulations/test --compiled-modules=existing --heap-size-hint=1500M -O0 AustralianElectricityMarketsSimulations/test/runtests.jl fcas_market` — 432 passed, 10 failed, all on the expected initial-mode exemption assertions. The interactive output was not saved to a file.
- Final focused run: `JULIA_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 JULIA_NUM_PRECOMPILE_TASKS=1 JULIA_PKG_PRECOMPILE_AUTO=0 julia --project=AustralianElectricityMarketsSimulations/test --compiled-modules=existing --heap-size-hint=1500M -O0 AustralianElectricityMarketsSimulations/test/runtests.jl fcas_market fast_start_toy` — 543 passed, 0 failed. Output: `/tmp/task4-fast-start-green.log`.
- Formatter: `pre-commit run runic --files AustralianElectricityMarketsSimulations/src/fcas_market.jl AustralianElectricityMarketsSimulations/test/fcas_market.jl AustralianElectricityMarketsSimulations/test/fast_start_toy.jl` — passed.

The final Julia process exited successfully.
