# 0076. MNSP commercial limits and operating inputs

## Status

Implemented on `codex/mnsp-fidelity`, based on `v0.2`.

## Context

MNSP link flow was bounded by both offered MW and availability. The direction-selection
binary used the same commercial ceiling. Adding an availability or offer-total slack without
changing that bound would still prohibit the violation. The offer reader already returns
RAMPUPRATE and FIXEDLOAD, but the system setter did not attach them.

## Official sources

- AEMO *Schedule of Constraint Violation Penalty Factors*, v8.0, effective 2 December 2025:
  item 4, MNSP ramping, CVP1155 (p. 8); item 9, MNSP total band MW, CVP1135 (p. 11);
  item 13, participant fixed loading, CVP380 (p. 13); item 16, MNSP availability,
  CVP365 (p. 15). Item 16 expressly permits a participant fixed loading to override availability.
- AEMO *Electricity Data Model Report*, v5.7.0: MNSP_BIDOFFERPERIOD pp. 67-69 defines
  RAMPUPRATE in MW/min in the link's positive direction and FIXEDLOAD in MW, with NULL
  indicating no fixed instruction. DISPATCHINTERCONNECTORRES pp. 269-271 defines
  METEREDMWFLOW as SCADA flow and MWFLOW as the dispatch target. MNSP_INTERCONNECTOR
  pp. 517-518 defines each link's direction and terminal transmission loss factors.

Faithful copies are in the nem-expert reference library under
`constraint-violation-penalty-factors/03-items-01-11.md`, `04-items-12-21.md`, and the
corresponding `data-model/` table files.

## Decision

For each non-negative directional link flow q, keep bounded offer-band variables b and add:

```text
q = sum(b) + offer_surplus
q - availability_surplus <= MAXAVAIL
```

The two surpluses are non-negative and independent, priced at CVP1135 and CVP365.
The direction binary keeps exactly one link available at a time. Its bound comes from
that direction's endpoint of the existing loss-model flow domain, not MAXAVAIL or offered MW.
No new physical capacity or arbitrary large bound is introduced.

For signed net flow x, metered initial flow x0, interval length dt in minutes, and forward
and reverse positive-direction ramp rates Rf and Rr:

```text
x - ramp_up_surplus <= x0 + dt * Rf
x + ramp_down_deficit >= x0 - dt * Rr
```

Each non-negative ramp violation costs CVP1155. These rows restrict net physical movement;
there is no second set of per-direction ramps that would double-count a reversal.

A non-NULL fixed-loading instruction fixes its directional q to FIXEDLOAD, with independent
non-negative surplus and deficit variables at CVP380. Missing instructions deactivate both
rows. Numeric zero remains an active instruction. Existing loss-domain bounds suffice to
relax inactive rows, without an invented inactive-target constant.

All penalty costs use system base power, interval hours and the existing per-interval MPC
parameters. Operating-input series are attached in natural MW and MW/min, and registered
PSI time-series parameters supply their recurrent values. Reported violations are in MW;
directional constraints retain the link direction in the report.

## Remaining deviations

This change does not reconstruct the two-end MNSP loss violation equations (schedule item 17),
Basslink converter losses, its no-go zone or the frequency-controller alternative runs.
Existing loss-curve endpoint bounds and fixed-binary pricing remain. These require verified
additional equations and scenario inputs, rather than a guessed extension of the current
hard loss-split equality. Historical MNSP and post-conversion regulated operation remain
selected from standing ICTYPE data; a replay crossing a type change must be split.

## Verification

The full root suite and all 1,905 Simulations checks passed using Julia 1.11.9 and the pinned
PowerSimulations fork. The temporary verification environment used the worktree packages;
repository dependency files were unchanged. Runic formatting and `git diff --check` passed.

Regression coverage checks independently elastic availability and offer totals, including zero
commercial limits; both net-flow ramp senses; both fixed-loading violation senses; active zero
versus absent fixed instructions; fixed-loading priority over availability; pricing versus
physical-run metered inputs; and operating-parameter updates over recurrent simulation steps.
Objective coefficients are checked after recurrence, and the MNSP ramp penalty repricing
function is exercised at the 2025-26 financial-year MPC change.

No historical NEMDE numerical-equivalence claim is made by these synthetic regressions.
