# 0107 Simple dispatch templates

## Status

Accepted. Extends ADR 0090, the template is the problem scope, with presets and a lossless interchange. The departures from NEMDE are listed in `nemde-documentation-audit.md`.

## What

- `template_nemde(; interconnectors, fcas, constraints, tie_break, exclude_constraints, loss_breakpoints)` is the one keyword builder. Six templates come from it: the full default and five presets, each a call with fixed keywords.
- `template_energy_only()`: no interchange, FCAS, constraints or tie-break. nempy examples 1 and 2 (bid stack, ramps).
- `template_interconnected()`: lossless interchanges and no other part. The lossless counterpart of nempy example 3, which takes a constant 5 percent loss that is not modelled here.
- `template_losses()`: dynamic losses. nempy example 4.
- `template_fcas()`: dynamic losses and the FCAS market, with constraints `:fcas_requirements`. nempy example 5.
- `template_constraints()`: dynamic losses and every generic constraint, no FCAS. No nempy counterpart.
- `template_nemde()`: the full model with tie-break. Corresponds to nempy example 6, the historical recreation.
- `NEMInterconnectorLossless` prices the same flow variable, flow limits and CVP x MPC flow slack as `NEMInterconnectorLoss`. Its balance terms are `-flow` and `+flow` only: no loss variables, loss curve, MNSP offers or direction binary.
- Under `NEMInterconnectorLossless` an MNSP is a regulated flow within its limits. This departs from ADR 0035 and ADR 0076.
- `loss_breakpoints = N` keeps the first and last breakpoints of each loss model and thins the interior evenly by index.
- `constraints = :fcas_requirements` keeps only the generic constraints that carry FCAS requirements.
- `MWLOSSES` is `missing` in a lossless run.
- Lossless departs from NEMDE, which always applies the LOSSMODEL quadratic. Regional prices differ from NEMDE only through binding flow limits, never through a loss factor.
- The kept flow rows are AEMO's Constraint Violation Penalty item 5, "Interconnector Capacity Limit" (FlowDeficit and FlowSurplus, factor 1150 x Market Price Cap). Bounds are IMPORTLIMIT <= flow <= EXPORTLIMIT from DISPATCHINTERCONNECTORRES, clamped to [-MAXMWIN, MAXMWOUT] and applied to MWFLOW.
- Under lossless an MNSP also loses its availability CVP and MAXAVAIL offer, the ramp rows (CVP item 4, 1155), the Total Band MW Offer row (item 9), the MNSP operating limits and MNSPSlack, the link-end loss factors and the NEMInitialFlow closed-loop state. Its balance is a plain `-flow` at the from area and `+flow` at the to area, and its flow is bounded only by the item 5 rows.
- Basslink ceases MNSP registration from 1 July 2026, so after that date the MNSP departure no longer applies to Basslink.
- `loss_breakpoints` departs from linearising on every MWBREAKPOINT. When a dropped breakpoint was zero, the zero-flow lift moves to the chord that brackets zero.
- Under `constraints = :fcas_requirements`, skipped constraints (no component) stay strict in the input check. Dropped terms and defaulted weights are checked only for in-scope constraints.

## How

- Presets are calls to the builder. Tie-break is on only in the full `template_nemde`; every other preset has `tie_break = false`.
- Ramps are always modelled. No keyword removes them.
- Fast start is the `fast_start = false` option of `nem_dispatch_sequence`, not a template setting. Every preset is fast-start capable.
- `loss_breakpoints` is stored as the `"loss_breakpoints"` attribute of the interchange device model and applied when the interchanges are built. The `System` is not changed.
- `read_interconnector_loss_gaps` reads the full curve from the `System`, so a thinned run reports the thinning error in `gap_mw`.
- `constraints = :fcas_requirements` filters the generic constraints at build, and `template_skipped_constraints` leaves the filtered-out constraints out of its report.
- A lossless run has no `InterconnectorLossVariable`: `read_solved_interval` gives `MWLOSSES = missing` and `read_interconnector_loss_gaps` returns an empty table.
- Invalid keyword combinations throw `ArgumentError` when the template is constructed, not at build. `:fcas_requirements` needs `fcas = true`, and `loss_breakpoints` needs `interconnectors = :losses` and at least 2.

## Why

- The presets follow the nempy ladder, so each NEMDE part can be added on its own and compared with one nempy example.
- Lossless is not NEMDE, which always applies the loss model (ADR 0022). It is a study setting, recorded as a departure in the audit with the flow limits cited to AEMO's CVP item 5 (1150).
- An FCAS requirement is a `GenericConstraint`, and the FCAS market clears only against the constraints that carry one. `:fcas_requirements` models exactly those; `true` would add the other generic constraints, and `false` would drop the requirements.
- Thinning keeps the endpoints, so the flow range is unchanged, and keeps the curve convex, so the segment fill still holds. The gap reader shows the error instead of hiding it.
- Tie-break is kept to the full model, so each preset adds only the parts it names.
- Ramps are never switched off. nempy example 1 has none, so comparing with it uses large ramp rates in the data.
- Fast start is a sequence option, because it changes how many decision models a run builds, not the problem.
