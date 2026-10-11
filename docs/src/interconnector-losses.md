# Interconnector loss inputs and assumptions

AustralianElectricityMarkets (AEM) owns the interpretation of NEM loss data, including documented
corrections, curve anchoring and regional allocation. AustralianElectricityMarketsSimulations
(AEMSim) consumes the resolved model to construct optimization variables and constraints.

## Source hierarchy and applicability

The raw readers preserve AEMO's published values. Model assembly selects the latest effective date
at or before `as_of`, then the highest version, independently for each interconnector in each table:

| Input | Source | Fields |
| --- | --- | --- |
| Regions | `INTERCONNECTOR` | `REGIONFROM`, `REGIONTO` |
| Equation and static loss share | `INTERCONNECTORCONSTRAINT` | `LOSSCONSTANT`, `LOSSFLOWCOEFFICIENT`, `FROMREGIONLOSSSHARE` |
| Regional demand terms | `LOSSFACTORMODEL` | `REGIONID`, `DEMANDCOEFFICIENT` |
| Piecewise breakpoints | `LOSSMODEL` | `MWBREAKPOINT` |
| Directional terminal factors | `MNSP_INTERCONNECTOR` through `set_mnsp_offers!` | `FROM_REGION_TLF`, `TO_REGION_TLF` |

Table schemas are defined in AEMO's [Electricity Data Model Report](https://visualisations.aemo.com.au/aemo/nemweb/MMSDataModelReport/).
Monthly archive dates identify storage partitions. They do not select the applicable loss equation.
Region pairs currently come from the newest cached `INTERCONNECTOR` partition.

[`interconnector_loss_assumptions`](@ref) identifies the annual report and candidate correction
records for a date. [`get_loss_model_provenance`](@ref) identifies the selected source versions,
the corrections actually applied, and fallback assumptions for an assembled model. This metadata
survives attachment, per-unit conversion and System JSON serialization. A report reference provides
context; it does not certify that every cached coefficient matches that report.

Explicit published demand coefficients, including zero, take precedence. A report correction fills
a missing term only when its date window, source versions and base equation all match. The code
declares these records in `src/interconnector_loss_assumptions.jl`. Years without a correction use
their published MMSDM values. Years without a registered report still resolve MMSDM versions;
their report metadata is absent. No annual coefficient is extrapolated by the correction registry.

Nullable equation fields retain the assembly defaults: missing `LOSSCONSTANT` becomes 1.0,
missing `LOSSFLOWCOEFFICIENT` becomes 0.0, and missing static `FROMREGIONLOSSSHARE` becomes 0.5
unless the named Basslink fallback applies. Provenance lists each default actually used. An absent
demand-term row contributes zero; it does not imply that the entire source table can be omitted.

## Financial years and V-SA

Report references cover calendar dates from 1 January 2022 through FY2026-27, including FY2021-22
for January through June 2022. Each financial year runs from 1 July through 30 June.

The following V-SA loss-factor equations illustrate why annual applicability matters. Coefficients
multiply flow `f` and regional demands `Vd`, `Sd`, `Nd`, all in MW.

| Financial year / configuration | Constant | Flow | VIC demand | SA demand | NSW demand | Report |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| 2021-22 | 1.0121 | 3.5511e-4 | -4.5341e-7 | -6.1623e-6 | Absent | [§3 p. 50, Table 21 p. 52](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/loss_factors_and_regional_boundaries/2021-22/marginal-loss-factors-for-the-2021-22-financial-year.pdf?rev=f5097f1dc1b14c649aa9541e8c8edb30&sc_lang=en) |
| 2022-23 | 1.0181 | 3.5925e-4 | -3.4191e-6 | 1.8182e-8 | Absent | [§3 p. 49, Table 21 p. 52](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/loss_factors_and_regional_boundaries/2022-23/marginal-loss-factors-for-the-2022-23-financial-year.pdf?rev=a057c7f9c36b48f09e59dd283906db4f&sc_lang=en) |
| 2023-24 | 1.0166 | 3.4263e-4 | -1.2753e-6 | -1.5712e-6 | Absent | [§3 p. 53, Table 22 p. 56](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/loss_factors_and_regional_boundaries/2023-24/marginal-loss-factors-for-the-2023-24-financia-year-pdf.pdf?rev=6e56696685cc4cc482f8c981502d72c5&sc_lang=en) |
| 2024-25 | 0.9936 | 2.2992e-4 | -1.6267e-5 | 6.2183e-5 | Absent | [§3 p. 54, Table 26 p. 57](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/loss_factors_and_regional_boundaries/2024-25-financial-year/mlfs-for-the-2024-25-financial-year.pdf?la=en) |
| 2025-26 | 0.9721 | 2.6801e-4 | -1.4896e-5 | 5.1080e-5 | 1.6981e-6 | [§3 p. 56, Table 25 p. 59](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/loss_factors_and_regional_boundaries/2025-26-marginal-loss-factors/marginal-loss-factors-for-the-2025-26-fin-year.pdf?la=en) |
| 2026-27 before NSW1-SA1 market establishment | 0.9742 | 2.29e-4 | -1.09e-5 | 6.63e-5 | -2.22e-6 | [§3.3.1 pp. 61-62](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/loss_factors_and_regional_boundaries/2026-27/marginal-loss-factors-for-the-2026-27-financial-year.pdf) |
| 2026-27 upon NSW1-SA1 market establishment | 1.0288 | 2.57e-4 | -1.27e-5 | 3.44e-5 | 1.00e-7 | [§3.3.2 p. 62](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/loss_factors_and_regional_boundaries/2026-27/marginal-loss-factors-for-the-2026-27-financial-year.pdf) |

The audited July 2025 and June 2026 `LOSSFACTORMODEL` archives omit the FY2025-26 V-SA/NSW1
term. AEM supplies it for `[2025-07-01, 2026-07-01)` only when both selected equation and demand
sources are effective 2025-07-01/version 1 and match the report's remaining coefficients. The
successor and earlier equations are used as published. The reason for the source discrepancy is
unknown. This correction is supported by the FY2025-26 report's footnote 11 and those audited
source versions; it is not a general rule that every absent demand term needs filling.

## Project EnergyConnect (PEC)

PEC Stage 1 uses an isolated Victorian "micro-slice" between NSW and SA. Its market representation
incorporates PEC into VNI and V-SA. The FY2025-26 report associates the extra NSW demand term with
PEC modelling ([§3 footnote 11; Appendix A2.6 Table 41 note C](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/loss_factors_and_regional_boundaries/2025-26-marginal-loss-factors/marginal-loss-factors-for-the-2025-26-fin-year.pdf?la=en)).

PEC Stage 2 removes that slice and establishes NSW1-SA1, creating a loop among NSW, Victoria and SA.
AEMO's FY2026-27 study assumes a transition around October 2026, and publishes separate VNI and
V-SA equations plus a new NSW-SA equation. These study dates are anticipated; the equations are
conditional on market establishment ([§3-4; Appendix A2.5.2 pp. 95-96](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/loss_factors_and_regional_boundaries/2026-27/marginal-loss-factors-for-the-2026-27-financial-year.pdf)).

Runtime assembly follows effective MMSDM versions. It does not switch topology on 1 October or
create NSW1-SA1 from a report forecast. A Stage 2 replay needs the corresponding published network,
loss models and generic constraints. The report's loop-flow regression was developed for its MLF
study and does not establish the dispatch constraint to install.

## Curve and regional balance conventions

[`interconnector_losses`](@ref) is the analytic integral of `(loss factor - 1)` from zero flow.
[`loss_segments`](@ref) returns its chord slopes. [`loss_curve_vertex_values`](@ref) supplies
the dispatch curve's vertices: when a chord strictly brackets zero, subtract its interpolated
zero-flow value from every vertex. This preserves slopes. A zero breakpoint already anchors the
curve; a range wholly on one side retains its analytic anchoring. AEMO describes integration in
[FY2024-25 §4 p. 58](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/loss_factors_and_regional_boundaries/2024-25-financial-year/mlfs-for-the-2024-25-financial-year.pdf?la=en)
and [FY2025-26 §4 p. 60](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/loss_factors_and_regional_boundaries/2025-26-marginal-loss-factors/marginal-loss-factors-for-the-2025-26-fin-year.pdf?la=en).
The discrete anchoring is a reconstruction assumption supported by sampled NEMDE XML segment
factors, rather than an algorithm specified by those reports.

[`interconnector_loss_allocation`](@ref) selects configured static regional sharing for devices
without directional offers. With paired MNSP offers, receiving-end flow `q` and DC loss `loss`
contribute `-from_tlf * (q + loss)` to the sender and `+to_tlf * q` to the receiver. Terminal
factors are read from the directional offer metadata. This follows the receiving-end convention in
[FY2024-25 §5.1 p. 61](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/loss_factors_and_regional_boundaries/2024-25-financial-year/mlfs-for-the-2024-25-financial-year.pdf?la=en)
and [FY2025-26 §5.1 p. 63](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/loss_factors_and_regional_boundaries/2025-26-marginal-loss-factors/marginal-loss-factors-for-the-2025-26-fin-year.pdf?la=en).
The direction binary assigns the total loss to the active sender. Loss bounds include zero and
the minimum and maximum resolved vertices, so inactive directions and signed losses remain feasible.
These terms add no separate loss cost; the existing directional offer bands supply the offer costs.

The Basslink static-share fallback of 1.0, used when directional offers are absent, is an explicit
replication assumption inherited from nempy. It is recorded in model provenance and is not a
report-derived annual terminal factor. The loss-only model also omits Basslink's physical fixed
converter losses and no-go zone. MNSP ramp, fixed-load and elastic-offer formulations remain
incomplete. FY2026-27's regulated Basslink treatment needs separate validation.

## Inspecting a model

```julia
models = interconnector_loss_models(db, DateTime(2025, 8, 1))
model = models["V-SA"]
provenance = get_loss_model_provenance(model)
provenance["tables"]       # independently selected effective dates and versions
provenance["corrections"]  # report corrections actually applied
loss_curve_vertex_values(model, Dict("VIC1" => 4000.0, "SA1" => 1500.0, "NSW1" => 7000.0))
```
