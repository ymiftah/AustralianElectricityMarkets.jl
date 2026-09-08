# 0005. AEMO constraint-authoring metadata stays in `ext`; only `description` is a field

## Status

Accepted

## Context

`add_nem_constraints!` builds a [`GenericConstraint`](@ref) for every AEMO generic constraint it
ingests, and stuffs five values from `GENCONDATA` into it: `DESCRIPTION`, `LIMITTYPE`, `SOURCE`,
`EFFECTIVEDATE` and `VERSIONNO`. All five were originally passed as loose entries in `ext`, a
`Dict{String, Any}` with no compile-time shape and no accessor functions — callers indexed the
dict by hand.

`GenericConstraint` is also meant to be hand-authored directly, for a user's own dispatch
experiment with no AEMO data behind it at all. That use case forces the question of which of
these five values are actually intrinsic to a generic constraint, versus provenance specific to
one particular data source (AEMO's `GENCONDATA` table).

`LIMITTYPE`, `SOURCE`, `EFFECTIVEDATE` and `VERSIONNO` are AEMO constraint-authoring bookkeeping:
they describe how AEMO classifies and versions the constraint definition, not anything about the
constraint's own algebra, sense, or role in a dispatch model. A hand-authored constraint has none
of this — there is no AEMO source, effective date, or version to report — so forcing every
constructor call to supply them would put AEMO plumbing in the way of the general-purpose use
case. `DESCRIPTION`, by contrast, is meaningful for any constraint whatever its origin: a
hand-authored constraint benefits from a human-readable description exactly as much as an
AEMO-sourced one does.

## Decision

- `description::String` is a real struct field on `GenericConstraint`, defaulting to `""` in the
  keyword constructor. `add_nem_constraints!` passes `def.DESCRIPTION` (falling back to `""` when
  the nullable `GENCONDATA.DESCRIPTION` column is `missing`).
- `limit_type`, `source`, `effective_date` and `version_no` stay in `ext`, keyed as before
  (`"limit_type"`, `"source"`, `"effective_date"`, `"version_no"`). They gain read accessors —
  `get_limit_type`, `get_source`, `get_effective_date`, `get_version_no` — so callers never index
  `ext` by hand. Each returns `nothing` when the key is absent, which is the normal case for a
  hand-authored constraint with an empty `ext`.
- No write accessors are added for the four `ext`-resident values: they are provenance recorded
  once at ingestion time, not something a caller mutates afterwards.

## Consequences

- `GenericConstraint(; name, sense, rhs, ...)` with no `ext` argument constructs a fully valid,
  hand-authored constraint: `description == ""` and all four provenance accessors return
  `nothing`.
- Code that reads AEMO provenance goes through the four accessors rather than indexing `ext`
  directly, so the storage detail (dict vs. field) is not part of any caller's contract. This
  makes a later decision to promote one of the four to a real field a non-breaking change for
  callers — the accessor's signature and absent-value behaviour can stay identical, only the
  implementation moves from an `ext` lookup to a field read.
- `ext["description"]` is no longer populated by `add_nem_constraints!`; existing code that read
  it that way must switch to `get_description`.
