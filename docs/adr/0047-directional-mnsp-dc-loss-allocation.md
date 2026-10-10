# 0047. Allocate MNSP DC losses to the sending region

## Status

Accepted for interconnectors carrying paired directional MNSP offers.

## Context

A static regional loss share for a net interconnector does not follow the
sending end when its flow reverses. The directional offer model already has
separate non-negative receiving-end flows and a binary selecting their direction.

[AEMO's 2025-26 Marginal Loss Factors report](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/loss_factors_and_regional_boundaries/2025-26-marginal-loss-factors/marginal-loss-factors-for-the-2025-26-fin-year.pdf?la=en),
section 5.1, page 63, defines Basslink's flow at the receiving end and relates
sending-end power to receiving-end power plus DC losses. It gives the Victorian
connection factor as 0.9907 and the Tasmanian factor as 1.0 for that financial year.

## Decision

Add one loss variable per directional link, sum them to the existing total
interconnector loss variable, and gate them with the existing direction binary.
For receiving-end flow `q` and selected loss `loss`, the sending balance contains
`-from_tlf * (q + loss)` and the receiving balance contains `+to_tlf * q`.
These balance coefficients follow from referring each terminal's power to its
regional reference node. Read the directional terminal factors from the offer
metadata rather than hard-coding the reported Basslink values.

The loss bounds use the minimum and maximum of the normalized piecewise vertices,
expanded to include zero so that the inactive direction is feasible. Linear
interpolation stays within those vertex bounds. The binary therefore selects
the sender without imposing a non-negative-loss assumption or changing the
existing loss curve. Remove the additional static loss-share contribution for
these offered devices; devices without directional offers retain it.

## Consequences

This changes the regional energy balance when the sending region differs from
the net interconnector's fixed `from` region. It does not add a new loss cost:
the balance terms determine the energy required at each end, while offered
directional bands retain their existing costs. Tests cover both directions,
non-unit terminal factors, signed vertex bounds and natural/per-unit conversion.

The paired offers still have hard availability and band bounds, and MNSP ramp,
fixed-load and elastic priority behavior remains incomplete. The loss-only pilot
evidence and these limitations are recorded in
[`interconnector-loss-fixes-2026-10-10.md`](../validation/interconnector-loss-fixes-2026-10-10.md).
The June sample does not validate the separate regulated-Basslink treatment from July 2026.
