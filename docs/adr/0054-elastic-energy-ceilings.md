# 0054. Separate elastic energy availability and UIGF limits

## Status

Accepted.

## Problem and evidence

The complete-input replay at 2026-01-02 02:00 AEST dispatched SNOWNTH1 at 51.22536 MW and
SNOWSTH1 at 82.99134 MW, instead of the published 61.19922 and 87.39844 MW. Their invoked
non-conformance constraints required their INITIALMW at weight 1160, but the model imposed
DISPATCHLOAD.AVAILABILITY as a hard upper bound. For these semi-scheduled units AVAILABILITY
equalled UIGF, while bid MAXAVAIL was 144 and 126 MW respectively.

A diagnostic surplus on just those two UIGF rows at CVP385 restored both targets and reduced
the regional price and flow errors to rounding-sized differences. The independent 2026-01-01
04:55 AEST case reproduced the cause and correction. Details and raw artifact locations are
in `docs/validation/snowtown-uigf.md`.

## Official sources

The nem-expert knowledge base contains faithful extracts of these AEMO sources:

- Schedule of Constraint Violation Penalty Factors v8.0, effective 2025-12-02, Table 1:
  item 2 non-conformance factor 1160 and item 3 unit ramp factor 1155, pp. 6-12,
  `references/constraint-violation-penalty-factors/03-items-01-11.md`.
- The same schedule, item 12 UIGF surplus factor 385, item 13 participant fixed loading
  factor 380 and item 14 unit MaxAvail factor 370, pp. 13-17,
  `references/constraint-violation-penalty-factors/04-items-12-21.md`.
- Electricity Data Model Report v5.7.0, BIDPEROFFER_D, pp. 65-67, for per-direction bid
  MAXAVAIL; DISPATCHLOAD, pp. 271-276, for INITIALMW, UIGF and the combined AVAILABILITY
  field; DUDETAILSUMMARY, pp. 508-511, for the effective schedule type.

## Decision

For non-storage NEM dispatch devices, in system-base per-unit, use:

```text
power >= 0
energy_max_avail_surplus >= 0
power - energy_max_avail_surplus <= bid_MAXAVAIL

For semi-scheduled devices only:
uigf_surplus >= 0
power - uigf_surplus <= UIGF
```

The surpluses cost `base_power * interval_cost_coefficient(CVP * MPC, resolution)` per
per-unit, at CVP370 and CVP385 respectively. The existing MPC selection and override apply.
The bounds, constraint meanings and costs follow items 12 and 14 above. The non-negative
power axis retains the existing generator and scheduled-load convention; load withdrawal
continues to use the negative network-balance multiplier. These are continuous slacks,
not additional discrete decisions.

`read_energy_limits` resolves per-direction energy offers, separate UIGF and effective
registration at each interval. `set_nem_energy_limits!` validates every active non-storage
device's full interval grid, finite non-negative values and a stable schedule type before
attaching series or classification. Missing inputs never select a different formulation.
Semi-scheduled zero forecasts are binding values. Non-scheduled FCAS-only loads are explicitly
classified and fixed at zero energy dispatch.

The old hard combined ceiling and the static rating upper bound on the active-power variable
are removed from the non-storage NEM formulation. The legacy `max_active_power` and raw
`availability` series remain attached, preserving native PSY conventions and FCAS preconditions.
They do not defeat the separate elastic energy rows. Ramping remains elastic at CVP1155.
The pre-flight envelope check now validates complete energy inputs rather than rejecting a
valid conflict that the penalty ordering resolves.

Both new slack families are registered PSI variables, exported in MW and included in standalone
and recurrent `constraint_violations` as `energy_max_avail` and `energy_uigf`. Their limits use
registered recurrent time-series parameters and update with each interval. Pricing retains
the existing fixed-binary LP mechanism.

## Scope and departures

This replaces the hard non-storage energy availability/UIGF treatment described in 0037.
The change is general across non-storage NEM devices and contains no Snowtown identifiers.
Storage's directional availability and ramp-envelope handling are unchanged. This does not
claim complete implementation of NEMDE's storage capacity violations.

Offer-band quantities remain bounded by the existing bid-stack implementation. The Total Band
MW Offer CVP (AEMO Schedule item 8, factor 1135, pp. 6-12) is not introduced here, so a conformance target beyond the total offered band MW
remains a separate gap. Fast-start inflexibility profiles and loss-breakpoint pricing are also
unchanged. No claim of full NEMDE equivalence follows from the two validation intervals.

## Verification

The original toy regression failed with dispatch 45 MW instead of its 60 MW non-conformance
target before the fix. Regressions cover non-conformance against one and both energy limits,
fixed loading between the two CVPs, ramping against the combined violation costs, negative
offers, zero forecasts, required input validation, reported MW and recurrent updates in both
interval orders. Root input tests cover separate values and atomic rejection of missing or
invalid forecasts, offers and classifications.

Production replay validation and final suite results are recorded in the validation report.
