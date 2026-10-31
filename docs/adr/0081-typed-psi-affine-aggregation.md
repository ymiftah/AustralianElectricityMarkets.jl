# 0081. Build affine sums within typed PSI constraint hooks

## Status

Accepted.

## Context

An audit against [JuMP's performance guidance](https://jump.dev/JuMP.jl/stable/tutorials/getting_started/performance_tips/)
found two affine sums constructed outside JuMP macros. One adds cleared energy bands to their
first breakpoint; another forms a unit's net injection for fixed-loading rows. Isolated
experiments found lower allocations when expression construction occurs inside JuMP macros.
The user requires expression and constraint construction to follow PSI type-based dispatch.

String names are already disabled by default in the pinned PSI settings. PSI enables names
under Debug logging. Runtime checks confirm that normal Info logging also skips evaluation of
`base_name` formatting expressions. No naming setting is changed.

## Decision

Fold energy-band aggregation into the existing `@constraint` in the specialized
`PSI._add_pwl_constraint!` compatibility hook. Dispatch remains on the component type, power
variable type, NEM dispatch formulation, band variable type and band constraint type. The
row retains its existing band-constraint/component container key. The scalar first-breakpoint
offset is evaluated separately, retaining its `Float64` validation. A one-point breakpoint
vector remains invalid and raises `ArgumentError`, now with a specific missing-band diagnostic.

Fold net injection into each existing fixed-loading `@constraint` in the
`PSI.add_constraints!` specialization for `EnergyFixedLoadConstraint` and the NEM device model.
The typed upper/lower container keys, surplus/deficit slacks and invocation relaxation remain
unchanged. Storage still contributes discharge minus charging; scheduled loads retain their
consumption convention. There is no separate JuMP model-editing pass, additional expression
container or new formulation type.

## Market correctness

No physical bound, energy quantity, cost coefficient or penalty changes. AEMO's
[Electricity Data Model Report, BIDPEROFFER_D](https://visualisations.aemo.com.au/aemo/nemweb/MMSDataModelReport/)
defines the offered band quantities and fixed loading. Its zero fixed loading denotes ordinary
market dispatch. The [Schedule of Constraint Violation Penalty Factors, version 8.0, item 13](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/congestion-information/2025/schedule-of-constraint-violation-penalty-factors.pdf)
defines participant fixed loading as the Energy Inflexible Offer constraint. This refactoring
retains those equations, their invocation behavior and their existing penalty. There is no
market-policy departure.

## Verification

Direct tests call the production PSI hook and inspect typed constraint containers, equality
coefficients, offset and individual band-width rows for generation, scheduled loads and both
storage directions. They cover nonzero/negative offsets, zero-width bands and invalid one-point
inputs. Solved regressions cover charging/discharging fixed loading and inactive invocation,
plus existing energy offers, recurrent widths and violations.

The source snapshots, isolated expression audit, production-hook benchmark and test logs are
retained in `scripts/results/jump_performance_20261026/`. These are construction measurements,
not dispatch solve or complete-system speedups.

The four affected test groups pass 600 checks. Runic, configured hooks and independent review
pass. A production-hook benchmark constructs 2,000 ten-band offer links per sample through
the actual typed PSI method, with five warm samples and one excluded warm-up per implementation.
All measured samples have zero compilation and no overlapping tests. Allocations fall from
50,316,832 to 34,028,832 bytes (32.4% fewer), with median construction time
0.040273 to 0.027231 seconds. All 22,000 equality/band-bound rows have identical fingerprints.
Fixture construction, manual GC and fingerprinting are excluded. This is a local hook result,
not a full-system, whole-model or dispatch-solve speedup.
