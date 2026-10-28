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

### Cost, solver gaps and duals

Interconnectors with a single segment (a straight loss line) add no binaries, and a system whose
interconnectors are all single-segment keeps no indicator container and stays an LP. A
multi-segment interconnector adds one binary per segment boundary per interval. The cached
`LOSSMODEL` carries 61 to 121 breakpoints per interconnector, so a real 5-minute problem has
about 520 binaries in use, plus unused indicator cells (interconnectors with fewer segments than
the largest) that appear in no constraint and are removed by presolve. They are needed because
PSI's dual pass reads one variable kind per container. The ordered-fill chain is tight (big-M
equals the segment width) and the LP relaxation is already exact when the price is positive,
but with about 520 binaries the solve-time impact is not negligible and has not been measured.

Because the problem is now a MILP, `replicate_interval` defaults to HiGHS with `mip_rel_gap = 0`
and `mip_abs_gap = 1e-10`. HiGHS' default relative gap of 1e-4 would let dispatch stop short of
the optimum when the objective is 1e6 to 1e8 with constraint violation slacks. nempy sets absolute
and relative gaps of 1e-10 and 1e-20 for the same reason.

PSI then fixes the integers at their solved values and re-solves the LP to read duals, which is
how the replication pipeline gets regional prices. A failed dual LP leaves the duals non-finite,
so `replicate_interval` raises on non-finite regional prices. PSI warns "resulted in a MILP"
once per dual container; the pipeline filters that message.

### Departure from nempy and NEMDE: duals at fixed indicators

With every indicator fixed, one side of a breakpoint is blocked in the dual LP. When the optimal
flow sits exactly on a breakpoint, the dual range is one-sided and regional prices can violate
the loss relationship (the price difference across the interconnector need not equal the marginal
loss on either side). nempy keeps the nearest three breakpoint weights free in its pricing LP
(`markets.py`, around lines 3147-3171), which gives the two-sided range. This package does not,
and nothing here shows that NEMDE prices at a fixed dispatch point. Validation item: on the
real-data baseline, count intervals whose solved flow is within tolerance of a breakpoint and
compare their regional prices with published ones against the other intervals.

Assessment of the fix: relaxing the indicators of the segments adjacent to the solved flow before
the dual pass is feasible but is not a small shim. PSI's discrete dual pass is a single private
function (`process_duals`) that unsets and fixes every binary from the solved values with no hook,
and a same-signature method cannot be redefined from a precompiled package. The workable approach
is a hook in the pinned PSI fork (about 25 lines, a per-variable-key policy deciding which
indicators stay free with bounds `[0, 1]`) plus about 40 lines here choosing the policy from the
solved indicators (free the last full indicator and its two neighbours). Deferred.

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
Real-data follow-up, besides the breakpoint item above: rerun the 10-interval baseline and compare `MWLOSSES` for NSW1-QLD1 (06-03),
V-SA and V-S-MNSP1, and record the per-interval solve time against the previous run.
