# 0045. Reference interconnector loss chords to zero flow

## Status

Accepted

## Context

The quadratic loss equation is defined by integrating `(loss factor - 1)` from zero flow.
When a piecewise chord uses breakpoints `a < 0 < z`, its interpolated value at zero is
`-b*a*z/2`, where `b` is the quadratic flow coefficient. The chord vertices therefore need a
constant adjustment to retain that zero-flow reference. This adjustment does not change segment
slopes. A breakpoint at zero already provides the reference; breakpoints on only one side of zero
do not determine it.

AEMO's *Marginal Loss Factors: Financial Year 2025-26*, section 4, page 60, describes inter-regional
loss equations through integration. The sampled dispatch XML inputs provide separate evidence for
the discrete segment convention: integrating their segment factors from zero reproduces the 600
published sample losses within 0.0000066 MW. The report does not specify NEMDE's exact internal
piecewise algorithm.

Source: [AEMO 2025-26 Marginal Loss Factors report](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/loss_factors_and_regional_boundaries/2025-26-marginal-loss-factors/marginal-loss-factors-for-the-2025-26-fin-year.pdf?la=en).
The XML comparison and offset calculations are recorded in
[`interconnector-loss-fixes-2026-10-10.md`](../validation/interconnector-loss-fixes-2026-10-10.md).

## Decision

For a loss model whose adjacent breakpoints strictly bracket zero, subtract the chord's interpolated
zero-flow value from every vertex. Use those normalized vertices in the total loss equation,
directional MNSP loss bounds, and loss-gap diagnostic. Leave the root `interconnector_losses` and
`loss_segments` APIs unchanged, and do not add a zero breakpoint.

When no breakpoint segment brackets zero, preserve the existing vertex anchoring because those
segments alone do not determine an offset. For non-MNSP interconnectors, loss sharing continues to
use the configured static regional share. Directional MNSP offers continue to assign each loss to
the sending area.

## Consequences

The piecewise model agrees with the zero-integrated analytic loss reference at zero flow without
changing marginal slopes. QNI's `[-17, 17]` MW chord has a 0.025959425 MW intercept, and VIC-NSW's
`[-44, 3]` MW chord has a 0.01040226 MW intercept. These values are removed from the piecewise
vertices only; analytic loss calculations keep their established meaning.
