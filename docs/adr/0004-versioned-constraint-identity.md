# 0004. `GenericConstraint` identity is `(GENCONID, EFFECTIVEDATE, VERSIONNO)`, not bare `GENCONID`

## Status

Accepted

## Context

`GENCONID` is AEMO's *reporting* identity for a generic constraint — it is what a human or a
downstream report refers to a constraint by. It is not a stable mathematical identity: AEMO
revises a constraint's `CONSTRAINTTYPE` (sense), `SPD*` terms and coefficients across versions
while keeping the same `GENCONID`. `DISPATCHCONSTRAINT` records the exact
`(CONSTRAINTID, GENCONID_EFFECTIVEDATE, GENCONID_VERSIONNO)` triple NEMDE actually used at each
dispatch interval — membership in that table, at that exact version, is the definition of "NEMDE
enforced this equation".

Before this change, `add_nem_constraints!` looped `unique(invoked.GENCONID)` and keyed
`def_by_id`/`terms_by_id` by `GENCONID` alone. Whenever a `GENCONID` was invoked under more than
one version within the requested `date_range`, this silently merged two different AEMO equations
into one LP row: one `GenericConstraint`, whose terms/sense came from whichever version's row
happened to be joined, but whose `"invoked"`/`"rhs"` series blended `DISPATCHCONSTRAINT` rows
from *both* versions as if they were the same constraint.

This is not theoretical. Measured on the real cache, `DISPATCHCONSTRAINT`
`archive_month=2026-07-01`, `INTERVENTION = 0`: 6258 distinct constraint IDs but 6444 distinct
exact `(id, EFFECTIVEDATE, VERSIONNO)` triples — **178 IDs (2.8%) invoked under more than one
version, up to 7 versions for a single ID**. 96 of those switches happen **mid-day**, not at the
trading-day boundary, so a per-day or per-trading-interval build cannot sidestep the problem by
assuming one version per day. The cleanest single-day case: `#SSE_PPCCGT_1` runs under
`VERSIONNO` 1 and then `VERSIONNO` 2 from 2026-07-02 16:25.

Two further findings shaped the fix rather than being incidental to it:

- `read_constraint_terms` (in `src/constraints/read.jl`) already joined the `SPD*` tables on the
  exact `(GENCONID, EFFECTIVEDATE, VERSIONNO)` triple in its `WHERE`/`JOIN` clauses, but its
  final `SELECT`s projected only `GENCONID, TERM_KIND, KEY, BIDTYPE, FACTOR` and `UNION ALL`'d
  the three branches together — the version columns were computed then thrown away before
  reaching the caller. Two versions' term rows arrived as one undifferentiated bag, so
  `groupby(terms_long, :GENCONID)` could not separate them even after fixing the build loop.
  This had to be fixed first (`EFFECTIVEDATE`/`VERSIONNO` now carried through all three `SELECT`
  branches, including through the `cp_matched` CTE for the `UNIT` branch) or the rest of this
  change would be cosmetic — the terms would still merge even if the `GenericConstraint`s split.
- FCAS requirement attribution (`_fcas_req_union_sql`/`read_constraint_fcas_requirements`)
  **cannot** be version-matched on recent data. AEMO's current
  `DISPATCH_FCAS_REQ_CONSTRAINT` table has no successor columns for
  `GENCONEFFECTIVEDATE`/`GENCONVERSIONNO` at all — the union fragment casts them to `NULL`. Every
  version-exact join against that `NULL` would fail, silently stripping FCAS attribution from
  every constraint on post-2025-05 data. This is a genuine data limitation, not something this
  package can work around by joining differently.

## Decision

- `add_nem_constraints!` builds one `GenericConstraint` per exact
  `(GENCONID, EFFECTIVEDATE, VERSIONNO)` triple actually invoked in `date_range`, not one per
  `GENCONID`. The loop iterates `gencon_versions` (the distinct invoked triples) instead of
  `unique(invoked.GENCONID)`, and `invoked`/definitions/terms are all grouped by the full triple.
- Each such `GenericConstraint` is named `GENCONID@EFFECTIVEDATE#VERSIONNO`, with the date
  formatted `yyyy-mm-dd` (e.g. `#SSE_PPCCGT_1@2026-07-02#2`). This is the component name callers
  look components up by, and the value `add_nem_constraints!` returns in `added`/`skipped`.
- The bare `GENCONID` is kept on `ext["gencon_id"]` for reporting/grouping and read through the
  new `get_gencon_id` accessor (checked against `PowerSystems`/`InfrastructureSystems` exports
  first — no collision, unlike `get_description` in an earlier PR). `effective_date`/
  `version_no` continue to live in `ext` with their existing accessors from an earlier PR.
- Each version's `"invoked"` series is `1.0` **only** at the intervals where
  `DISPATCHCONSTRAINT` selected that exact version — never both versions `1.0` at the same
  interval, because each version's series is built exclusively from the `DISPATCHCONSTRAINT`
  rows carrying that version's own `(EFFECTIVEDATE, VERSIONNO)`. Its `"rhs"` carries that
  version's own `RHS` with the existing carry-forward. Terms, sense, weight, description and
  provenance all come from that exact version's `GENCONDATA` row and that exact version's `SPD*`
  rows — fixed by carrying `EFFECTIVEDATE`/`VERSIONNO` through `read_constraint_terms`'s three
  `SELECT` branches (see Context) rather than dropping them in the final projection.
- `fcas_requirements` is the one deliberate exception: it stays matched by bare `GENCONID` and is
  attached identically to **every** version of that `GENCONID`. Trying to version-match it would
  make every match `NULL` on current data and silently drop FCAS attribution from every
  constraint — a worse outcome than the asymmetry. This is documented at
  `_fcas_req_union_sql`/`read_constraint_fcas_requirements` and on `add_nem_constraints!` itself.
- `added`/`skipped` are keyed by the versioned component name, not `GENCONID`: a bare `GENCONID`
  key would now be ambiguous whenever more than one version of it was invoked in the same
  `date_range`, and a caller needs the versioned name anyway to look the component up.

## Consequences

- **Breaking**: `GenericConstraint` component names built by `add_nem_constraints!` change from
  bare `GENCONID` (e.g. `"N_BAYSW_THERMAL"`) to the versioned form
  (e.g. `"N_BAYSW_THERMAL@2025-01-01#1"`). Any caller looking components up by bare `GENCONID`,
  or indexing `added`/`skipped` by it, must switch to the versioned name or to
  `get_gencon_id`-based filtering over `get_components(GenericConstraint, sys)`.
- A `date_range` spanning a mid-horizon version switch now correctly yields two
  `GenericConstraint`s with complementary `"invoked"` series and their own (possibly different)
  terms/sense/coefficients, instead of one component silently blending two AEMO equations.
- `fcas_requirements` accuracy is unaffected in the common case (a `GENCONID`'s FCAS attribution
  rarely changes across its own versions) but is not, and cannot currently be, verified
  version-by-version. A future AEMO table restoring version columns on the FCAS-requirement side
  would let this be tightened; until then this asymmetry is a known, documented limitation rather
  than a silent one.
- `read_constraint_terms`'s return shape changed: it now includes `EFFECTIVEDATE`/`VERSIONNO`
  columns, so a caller consuming its raw DataFrame output (rather than going through
  `add_nem_constraints!`) sees two new columns.
