# 0048. AEM owns loss-input assumptions and source provenance

## Status

Accepted

## Context

The numerical fixes in ADRs 0044, 0045 and 0047 left report matching inside model assembly and
dispatch curve anchoring inside AEMSim. Users could not inspect the selected source versions or
the report correction on an assembled model. An annual coefficient correction also needed a
clear relationship to the PEC configuration changes described by AEMO.

## Decision

Declare report references for FY2021-22 through FY2026-27, covering calendar 2022 onward and versioned demand-term
correction records in AEM's `interconnector_loss_assumptions.jl`. Preserve raw reader contracts.
The FY2025-26 correction retains all source-version, equation and precedence guards; no new
historical correction is inferred from the report comparison. Unregistered years resolve their
MMSDM inputs normally without borrowing a registered year's report or correction.

AEM exposes the normalized dispatch vertices and allocation convention. AEMSim uses those APIs
for the total loss equation, directional bounds and diagnostics. Algebraic segment fill, gating,
terminal balance terms and offer costs remain in AEMSim.

Record source versions independently for INTERCONNECTORCONSTRAINT, LOSSFACTORMODEL and LOSSMODEL.
Store provenance in InfrastructureSystems `internal.ext` and expose a copying accessor. Preserve
the metadata through per-unit conversion and System serialization without changing serialized
component fields. Report metadata provides context and does not certify cache agreement.

Document PEC Stage 1's Victorian micro-slice, Stage 2's NSW1-SA1 market interconnector, annual
equation changes and the distinction between study assumptions and effective market arrangements
on a public explanation page. Effective MMSDM versions select equations; the report's anticipated
October 2026 study date does not create or activate a network configuration.

## Sources and departures

- [AEMO FY2021-22 MLF report](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/loss_factors_and_regional_boundaries/2021-22/marginal-loss-factors-for-the-2021-22-financial-year.pdf?rev=f5097f1dc1b14c649aa9541e8c8edb30&sc_lang=en), §3 pp. 50-52; §4 p. 53; §5.1 p. 56.
- [AEMO FY2022-23 MLF report](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/loss_factors_and_regional_boundaries/2022-23/marginal-loss-factors-for-the-2022-23-financial-year.pdf?rev=a057c7f9c36b48f09e59dd283906db4f&sc_lang=en), §3 pp. 49-52; §4 p. 53; §5.1 p. 56.
- [AEMO FY2023-24 MLF report](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/loss_factors_and_regional_boundaries/2023-24/marginal-loss-factors-for-the-2023-24-financia-year-pdf.pdf?rev=6e56696685cc4cc482f8c981502d72c5&sc_lang=en), §3 pp. 53-56; §4 p. 57; §5.1 p. 60.
- [AEMO FY2024-25 MLF report](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/loss_factors_and_regional_boundaries/2024-25-financial-year/mlfs-for-the-2024-25-financial-year.pdf?la=en), §3 p. 54 and Table 26 p. 57 (V-SA), §4 p. 58 (loss integration), §5.1 p. 61 (Basslink).
- [AEMO FY2025-26 MLF report](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/loss_factors_and_regional_boundaries/2025-26-marginal-loss-factors/marginal-loss-factors-for-the-2025-26-fin-year.pdf?la=en), §3 p. 56 footnote 11 and Table 25 p. 59 (V-SA demand term), §4 p. 60 (integration), §5.1 p. 63 (receiving-end flow and terminal factors).
- [AEMO FY2026-27 MLF report](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/loss_factors_and_regional_boundaries/2026-27/marginal-loss-factors-for-the-2026-27-financial-year.pdf), §3.3 pp. 61-62 (alternative V-SA equations), Appendix A2.5.2 pp. 95-96 (PEC).
- [AEMO Electricity Data Model Report](https://visualisations.aemo.com.au/aemo/nemweb/MMSDataModelReport/), the loss configuration tables and MNSP_INTERCONNECTOR.

Zero-reference discrete anchoring remains the sampled reconstruction assumption in ADR 0045.
The Basslink static-share override remains a nempy replication fallback, explicitly recorded in
provenance. Physical converter fixed losses, no-go operation, MNSP ramp/fixed-load/elastic-offer
behaviour and separate regulated Basslink validation remain outside this change. Directional loss
bounds still span all normalized vertices and zero; this refactoring introduces no new variable
bound, constraint or cost term.

## Validation

Added regression coverage for three annual equations, explicit coefficient precedence, a synthetic
PEC effective date different from the study date, independent source versions, provenance copying,
per-unit conversion and System JSON serialization. Curve-level tests move to AEM; AEMSim retains
the regional balance and solver tests. The new API tests failed before implementation. Final test
execution was skipped at the user's request; formatting and static review are recorded separately.
