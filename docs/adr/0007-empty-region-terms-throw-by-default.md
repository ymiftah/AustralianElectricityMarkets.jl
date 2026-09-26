# 0007. An empty `RegionTerm` throws by default; `allow_empty_region_terms` is the escape hatch

## Status

Accepted

## Context

A `RegionTerm` (from `SPDREGIONCONSTRAINT`) references a NEM region, not a single device.
[`resolve_term_devices`](@ref) resolves it to every `Generator`/`Storage` unit whose bus sits in
that region (`_region_devices`) — but the region's `Area` existing in `sys` does not guarantee
that vector is non-empty. Previously (`:no_region_devices`) `add_nem_constraints!` silently
skipped the whole constraint whenever this happened, the same as an unresolvable `UnitTerm` or
`InterconnectorTerm`. That conflated two different situations: a term naming something `sys`
genuinely does not have (an unknown DUID, interconnector, or region), versus a term whose
reference resolved fine but named zero devices.

Before fixing the default, this needed measuring against real data rather than guessed. Scanning
every `SPDREGIONCONSTRAINT` partition in the real cache (2015-01 → 2026-07, ~25k rows), **only
the five standard NEM regions ever appear** as region-term regions (VIC1 5721 rows / SA1 5601 /
NSW1 5451 / QLD1 4606 / TAS1 3932). Since `_region_devices` keys on the `Area` name and every
NEM region carries generators in a whole-NEM `System`, an empty region term **cannot arise from
ordinary data** — it arises only when the caller has built a `System` deliberately restricted to
a subset of regions. This is a property of the observed data, not a guarantee: a future NEM
region split, or a `System` built over an unusual subset of `SPDREGIONCONSTRAINT`'s regions,
could still produce one.

## Decision

- `add_nem_constraints!` gains `allow_empty_region_terms::Bool = false`.
- Every empty-region-term case found across the whole build is collected first (never acted on
  at the first one found).
  - `false` (default): after the build, throw one aggregated `ArgumentError` naming every
    affected `GENCONID`, region and `bid_type`.
  - `true`: after the build, emit one aggregated `@warn` and proceed — the affected
    `RegionTerm`s carry an empty `devices`, and their `GenericConstraint`s are still added.
- `:no_region_devices` is removed from `add_nem_constraints!`'s `skipped` reasons. An empty
  region term is now either an error or an accepted warning, never a silent skip.
  `:unknown_duid`/`:unknown_region`/`:unknown_interconnector` (a term referencing something
  `sys` doesn't have at all) are unaffected and remain skips.

## Consequences

- Throwing by default does not make `add_nem_constraints!` unusable against real data: the
  measurement above shows the case essentially does not occur for a whole-NEM `System`.
- A caller building a `System` restricted to a subset of NEM regions — the one case that does
  produce empty region terms — gets an aggregated error naming exactly which constraints are
  affected, and can either accept the gap explicitly via `allow_empty_region_terms = true` or
  adjust which regions/constraints it ingests.
- This is a breaking change: the default behaviour of `add_nem_constraints!` changes from a
  silent skip to a thrown error for any caller who was unknowingly relying on
  `:no_region_devices`.
