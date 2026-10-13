# Interconnector loss inputs and assumptions

Interconnector loss equations depend on regional demand, signed transfer and the network
configuration applicable to the interval. See the
[formulation chapter](examples/nemde_interconnectors.md) for the governing equations.

## Source hierarchy and applicability

Published inputs have effective dates and versions that determine which equation applies
to a dispatch interval. Relevant MMSDM sources are:

| Input | Source | Fields |
| --- | --- | --- |
| Regions | `INTERCONNECTOR` | `REGIONFROM`, `REGIONTO` |
| Equation and static loss share | `INTERCONNECTORCONSTRAINT` | `LOSSCONSTANT`, `LOSSFLOWCOEFFICIENT`, `FROMREGIONLOSSSHARE` |
| Regional demand terms | `LOSSFACTORMODEL` | `REGIONID`, `DEMANDCOEFFICIENT` |
| Piecewise breakpoints | `LOSSMODEL` | `MWBREAKPOINT` |
| Directional terminal factors | `MNSP_INTERCONNECTOR` | `FROM_REGION_TLF`, `TO_REGION_TLF` |

Table schemas are defined in AEMO's [Electricity Data Model Report](https://visualisations.aemo.com.au/aemo/nemweb/MMSDataModelReport/).
Monthly archive dates identify storage partitions. They do not select the applicable loss equation.

!!! note "Missing data assumptions"
    The replica defaults missing `LOSSCONSTANT` to 1.0, missing `LOSSFLOWCOEFFICIENT` to 0.0,
    and missing static `FROMREGIONLOSSSHARE` to 0.5, except for the Basslink assumption below.
    An absent demand term contributes zero unless a documented correction applies.
    These are reconstruction assumptions, not evidence that AEMO intended those values.
    Explicit published coefficients, including zero, take precedence.

## Financial years and V-SA

Each financial year runs from 1 July through 30 June.

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

!!! note "FY2025-26 V-SA source discrepancy"
    The audited July 2025 and June 2026 `LOSSFACTORMODEL` archives omit the V-SA/NSW1 term
    published in the FY2025-26 report. Reconstructing that equation requires `1.6981e-6`
    for NSW demand for the equation applicable from 1 July 2025 through 30 June 2026.
    Validate the applicable equation and its other coefficients against the report.
    Explicit published coefficients, including zero, take precedence. The reason for the
    discrepancy is unknown; it does not establish a general rule for filling absent terms.

## Project EnergyConnect (PEC)

PEC Stage 1 uses an isolated Victorian "micro-slice" between NSW and SA. Its market representation
incorporates PEC into VNI and V-SA. The FY2025-26 report associates the extra NSW demand term with
PEC modelling ([§3 footnote 11; Appendix A2.6 Table 41 note C](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/loss_factors_and_regional_boundaries/2025-26-marginal-loss-factors/marginal-loss-factors-for-the-2025-26-fin-year.pdf?la=en)).

PEC Stage 2 removes that slice and establishes NSW1-SA1, creating a loop among NSW, Victoria and SA.
AEMO's FY2026-27 study assumes a transition around October 2026, and publishes separate VNI and
V-SA equations plus a new NSW-SA equation. These study dates are anticipated; the equations are
conditional on market establishment ([§3-4; Appendix A2.5.2 pp. 95-96](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/loss_factors_and_regional_boundaries/2026-27/marginal-loss-factors-for-the-2026-27-financial-year.pdf)).

!!! note "Configuration applicability"
    A forecast transition date does not establish the historical topology for an interval.
    A Stage 2 reconstruction requires the corresponding published network, loss equations
    and generic constraints. The report's loop-flow regression was developed for its MLF
    study and does not by itself establish the dispatch constraint to use.

## Curve and regional balance conventions

AEMO derives analytic inter-regional losses by integrating the loss factor minus one with respect
to flow. A linear loss-factor equation gives a quadratic loss curve, anchored at zero flow
([FY2025-26 §4 p. 60](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/loss_factors_and_regional_boundaries/2025-26-marginal-loss-factors/marginal-loss-factors-for-the-2025-26-fin-year.pdf?la=en)).
`LOSSMODEL` supplies breakpoints for a piecewise linear representation.

!!! note "Discrete curve anchoring"
    Interpolating analytic values at breakpoints can give a nonzero chord value at zero flow.
    Shifting all vertices by that value preserves slopes and anchors the chord at zero.
    This is a reconstruction assumption. The annual reports do not specify the
    interpolation procedure. The replica does not apply this discrete zero-flow
    correction, so a chord spanning zero can retain a loss offset.

AEMO apportions regulated inter-regional losses between the associated regions using static
proportioning factors ([FY2026-27 §6 p. 78](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/loss_factors_and_regional_boundaries/2026-27/marginal-loss-factors-for-the-2026-27-financial-year.pdf)).
For MNSP receiving-end flow `q`, the sender supplies `q + loss` and the receiver receives `q`.
Directional terminal factors refer these transfers to their regional reference nodes
([FY2025-26 §5.1 p. 63](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/loss_factors_and_regional_boundaries/2025-26-marginal-loss-factors/marginal-loss-factors-for-the-2025-26-fin-year.pdf?la=en)).

!!! note "Basslink and MNSP coverage"
    Without directional offers, the replica assigns all Basslink losses to its configured
    from region. This is a reconstruction assumption, not an annual terminal factor.
    Direction-dependent MNSP sender loss allocation is not represented; static regional
    shares are used instead. Basslink fixed converter losses and its no-go zone are
    omitted. MNSP ramp, fixed-load and elastic-offer behavior remain incomplete.
    FY2026-27 regulated Basslink treatment
    needs separate validation against the applicable configuration and published inputs.
