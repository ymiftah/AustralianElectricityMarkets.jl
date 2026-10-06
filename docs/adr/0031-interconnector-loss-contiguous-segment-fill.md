# 0031. Interconnector loss segments fill contiguously

## Status

Accepted. Supersedes the "Known gap: no hard floor against over-dissipation" section of 0022.

## Context

`NEMInterconnectorLoss` linearises the interconnector loss curve on `LOSSMODEL`'s `MWBREAKPOINT`
segments, one bounded flow variable per segment, with `flow = bp1 + sum(segments)` and
`loss = loss(bp1) + sum(slope * segment)`. The curve is convex, so the slopes ascend. Under that
encoding the LP only reproduces the curve when a unit of loss costs something: with a
non-positive weighted price (`share * price_from + (1 - share) * price_to`) it can fill a steep
segment while a cheaper one sits idle, and the model burns energy. The 10-interval baseline
showed it: NSW1-QLD1 reported loss 875 MW against 1 MW published, V-SA 285 against 61, and
V-S-MNSP1 209 against 0, all at negative weighted prices.

## Decision

Add a binary fill indicator `z[s]` per segment boundary and two rows per boundary:

```text
segment[s + 1] <= width[s + 1] * z[s]
segment[s]     >= width[s]     * z[s]
```

Segment `s + 1` can carry flow only when segment `s` is full, so segments fill contiguously from
the first breakpoint and the loss at a flow is the chord value, for any price sign. These are the
same two-adjacent-points semantics as `nempy`'s SOS2 interpolation weights, expressed on the
existing segment variables so no variable or constraint is rewritten.

### Why not an LP-only form

The convex loss curve gives `loss >= chord_s(flow)` for every chord as an LP epigraph, which is
exact when more loss is costly. When the price is negative the LP wants more loss, and bounding it
above by the curve is a non-convex constraint. Any exact encoding for both price signs therefore
needs integrality, either SOS2 or binaries. Binaries were chosen because they need no solver
SOS support and PSI already handles them.

### Cost and duals

Interconnectors with one segment (a straight loss line) add no binaries. A multi-segment
interconnector adds `segments - 1` binaries per interval; the NEM has six interconnectors with a
handful of segments each, so a few tens of binaries per 5-minute problem. Their structure is
tight (an ordered-fill chain, big-M equal to the segment width), so branch and bound is expected
to be shallow, but the problem becomes a MILP. PSI then fixes the integers at their solved values
and re-solves the LP to read duals, which is how the replication pipeline gets regional prices.
Prices are therefore the duals of the LP with the loss segments fixed, the same notion as NEMDE
pricing at a fixed dispatch point.

The unused cells of the segment-indicator container (interconnectors with fewer segments than the
largest) are free binaries that appear in no constraint, because PSI's dual pass needs every
container to hold one variable kind.

## Narrow breakpoint range

0022's other caveat is unchanged. The breakpoint range still bounds flow and a narrower range than
`flow_limits` still produces one summary warning at construction. This is the intended behaviour:
`LOSSMODEL` breakpoints define where the curve is valid.

## Sources

AEMO, Marginal Loss Factors FY2026-27, section 4, pp. 64-70 (loss equations in the notional-link
transfer); Electricity Data Model Report, `LOSSMODEL`, `LOSSFACTORMODEL`. None of the sources
checked document NEMDE's internal linearisation; the encoding follows nempy's SOS2 semantics, and
a departure from NEMDE's own solver internals is possible but unobservable.

## Validation

Mock test: with negative-cost supply the receiving-region price is negative and the check
`interconnector_loss_gaps` reports zero gap; on the previous encoding the same test fails.
Real-data follow-up: rerun the 10-interval baseline and compare `MWLOSSES` for NSW1-QLD1 (06-03),
V-SA and V-S-MNSP1, and record the per-interval solve time against the previous run.
