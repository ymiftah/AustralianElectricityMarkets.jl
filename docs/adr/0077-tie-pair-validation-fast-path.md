# 0077. Reuse validation pair sets when active prices are unchanged

## Status

Accepted.

## Context

The full-day build benchmark at c18118f measured 2.711 GB of warm pre-flight/template
allocations. The tie-pair checker alone allocated 2.394 GB and took a median 3.225 seconds.
It rebuilt and hashed the same regional, directional band-pair sets at every interval.

## Decision

Keep the global active-band mask, the first requested interval as the reference, and the
existing pair-set construction. Before building another interval's pair set, compare its
active-band prices with the reference. Equal prices and equal band counts prove that the
existing grouping inputs are unchanged. Widths can vary without changing this membership;
widths continue to determine dispatch scales independently.

A price or band-count change falls back to the existing full comparison. Timestamp lookup
still precedes the fast path. The grouping tolerance, transitive-tie rejection, returned
errors, optimisation constraints, coefficients and penalties are preserved.

AEMO's Schedule of Constraint Violation Penalty Factors v8.0, item 53, defines regional,
directional ties on adjusted energy-band prices within 1e-6 and dispatch proportional to
band quantities. The faithful extract is `constraint-violation-penalty-factors/06-items-36-53.md`,
pages 27-37. This optimisation makes no departure from that rule.

## Verification

The baseline public-validator allocation regression failed: 30,655,376 bytes for 288
intervals against a 2,202,208-byte bound derived from the one-interval validation cost.
The baseline passed all functional cases. New coverage includes generation and load bids,
quantity-only changes, inactive bands, inserted/removed bands, a requested subset starting
after the first stored timestamp, changed prices preserving ties, missing timestamps and
transitive ties introduced at a later interval.

The isolated real-data prototype measured 0.093 seconds and 20.3 MB against 3.225 seconds
and 2.394 GB for the original checker. Its unchanged-price predicate was cross-checked against
original pair sets for 2,880 interval/group combinations.

The production implementation passed 23 focused checks, 293 dispatch checks and 544 stock
simulation checks. The stock group was run independently after qualifying a pre-existing
TimeArray reference that had depended on an import from another group. Review found no
important or critical issues; formatting and configured commit hooks passed.

Three warmed production checker repetitions measured median 0.100327 seconds against
3.490789 seconds for the original implementation, a 34.79-fold speedup. Allocation fell
from 2,393,616,304 to 20,330,648 bytes, a 99.15% reduction. The real-data pair-set cross-check
again covered all 2,880 interval/group combinations. These measurements cover the checker,
not the entire build or replay.
