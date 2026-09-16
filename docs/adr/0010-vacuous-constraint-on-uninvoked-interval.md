# 0010. Filling an uninvoked `(component, t)` cell: vacuous constraint vs. a custom dual-reader

## Status

Accepted — the vacuous constraint. Measured against a working sparse implementation on real
data, as this ADR asked for; see "Decision" below.

## Context

`GenericConstraint`'s `"invoked"` series (see `add_nem_constraints!`) is `0.0` at any interval
this constraint wasn't actually enforced. A `PowerSimulations.jl` formulation consuming it will
be tempted to skip building a constraint at those `(component, t)` cells entirely, since there's
nothing to enforce.

PSI's `ServiceModel` constraint containers are typically dense arrays pre-allocated over the
full `(component, timestep)` grid — not something a formulation author controls — and
`_calculate_dual_variable_value!` broadcasts over that whole container to extract duals. A cell
with no `ConstraintRef` assigned throws `UndefRefError` rather than reading back a dual.

## Decision

Emit a vacuous `0.0 <= 1.0` constraint at every uninvoked cell.

Both options below were implemented against the `LinearFactorLimit` formulation and measured on
one real dispatch day (2026-06-04, 288 five-minute intervals, 644 buildable `GenericConstraint`
versions, 185,472 `(name, t)` cells of which 154,439 are invoked — 31,033 vacuous rows):

| | vacuous | sparse |
| --- | --- | --- |
| `build!` | 106.3 s | 104.6 s |
| `solve!` | 254.7 s | 230.1 s |
| RSS added by `build!` | 628 MB | 518 MB |
| JuMP constraints | 2,211,840 | 2,180,807 |

The 31,033-row difference is the whole effect, and it is within run-to-run noise at this scale.
In isolation a vacuous row costs ~3.2 µs and ~40 bytes, so even the extreme case — a whole
month held in one model, where AEMO's own data is 79% uninvoked (about 42M vacuous cells) —
projects to ~135 s and a few GB, and no model of that horizon is built: the replication harness
runs a single interval, and operational horizons are a day.

Sparsity is also a function of horizon, and that cuts against the sparse option at the horizons
actually used: over a single day 83% of cells are invoked, against 21% over a whole month.

The sparse container additionally needs a hand-built `SparseAxisArray`, because
`PowerSimulations.jl`'s own `sparse_container_spec` pre-fills every cell of the axes product
with `nothing` for a `ConstraintRef` — sparse only in being `Dict`-backed. Leaving an uninvoked
cell unassigned there makes the dual read-back call `jump_value(nothing)`. That is a private
behaviour to re-verify on every PSI upgrade, bought for no measured gain.

The two options considered:

- **Vacuous constraint**: emit `0.0 <= 1.0` at every uninvoked cell instead of omitting it. It
  has no decision-variable coefficients, adds nothing to the LHS, and reads back a dual of
  exactly `0.0` — the mathematically correct answer, since a constraint not in force has no
  shadow price. Cheap to write and stays inside PSI's generic dual-reading machinery, but adds
  one live `ConstraintRef`/MOI object per uninvoked cell — real per-constraint bookkeeping
  overhead in JuMP's model-build and memory footprint that scales with
  `(constrained devices × horizon length)`, even though an empty row typically presolves away
  before the solve itself.
- **Custom sparse dual-reader**: use a sparse/`Dict`-keyed container instead of PSI's dense
  array for this constraint type, and write a dual-reader that only touches cells that actually
  exist. Avoids the row bloat entirely, at the cost of bypassing PSI's generic dual-computation
  path — more custom code to write and keep in sync with PSI's own container conventions across
  version upgrades.

## Consequences

- `LinearFactorLimit` builds a dense `NEMConstraintLimit` container per constraint instance and
  fills uninvoked cells with a vacuous row. Its dual reads back as exactly `0.0` there.
- The sparse implementation is not kept in the code. Should a use case appear that holds a
  month or more in one model, it is worth reviving; the measurements above say which numbers
  would have to change first.
- Row count scales with `constrained instances × horizon`, so a future horizon much longer than
  a day should re-measure rather than assume this result carries over.
