# 0055. Price storage availability violations on the directional offer axes

## Status

Accepted.

## Problem

Storage dispatch used hard directional limits derived from bid MAXAVAIL. Replay raised these
limits to the metered ramp envelope in advance, allowing some availability exceedances without
their violation cost. Other conflicts, including non-conformance, could not exceed the ceiling.

## Sources

- AEMO, Schedule of Constraint Violation Penalty Factors v8.0, effective 2 December 2025,
  Table 1 item 14, p. 14: energy MaxAvail uses deficit/surplus capacity variables at CVP370.
  Items 2 and 3, p. 7: non-conformance and unit ramping use CVP1160 and CVP1155.
  Official source: <https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/congestion-information/2025/schedule-of-constraint-violation-penalty-factors.pdf>
- AEMO, Electricity Data Model Report v5.7.0, BIDPEROFFER_D, pp. 65-67: MAXAVAIL is
  interval and direction specific. DUDETAIL, pp. 504-508: registered capacity is used for
  bid validation, rather than an additional immutable dispatch bound.
- AEMO, BDU final design workshop, 24 July 2023, pp. 40-41: signed net dispatch is positive
  for generation and negative for consumption. Storage energy limits apply to pre-dispatch.
  <https://www.aemo.com.au/-/media/files/initiatives/integrating-energy-storage-systems-project/aemo-iess-bdu-final-design-workshop-24-july-2023.pdf>

The nem-expert reference extracts are
`references/constraint-violation-penalty-factors/03-items-01-11.md`, pp. 6-12, and
`04-items-12-21.md`, pp. 13-17.

## Decision

Keep the non-negative generation and consumption offer variables. Apply these rows in
system-base per-unit:

```text
generation - generation_availability_slack <= raw_generation_MAXAVAIL
-consumption + consumption_availability_slack >= -raw_consumption_MAXAVAIL
generation_availability_slack >= 0
consumption_availability_slack >= 0
```

Both slacks cost CVP370 times the interval's MPC, multiplied by system base power and interval
hours. They use registered parameters for standalone and recurrent models. Their reported
`energy_max_avail` violations are in MW, with `up` for the generation bound and `down` for the
negative consumption bound. Static ratings and pre-raised dispatch ceilings no longer bound dispatch.

Both raw offer availability series are required, finite and non-negative. Missing or invalid
inputs fail before model construction; no static-rating replacement is used. The existing
`set_storage_dispatch_ceilings!` utility remains available for callers using its attached data,
but AbstractNEMDispatch does not consume those derived ceilings.

The bounds apply to the existing directional offer coordinates. A net-only availability row
would permit counterdispatch through unused crossed bands when, for example, generation
MAXAVAIL is zero and its raw generation price is below the load price. AEMO's bid convexity
validation compares only effective bands limited by MAXAVAIL, so those unused crossed bands
can occur in valid offers. Directional violation costs prevent this unpriced circulation.
Source: AEMO, Bid convexity and monotonically increasing validation, modified 30 May 2025,
<https://markets-portal-help.docs.public.aemo.com.au/Content/EMMSenergyFCAS/Bid_convexity_and_monotonically_increasing_validation.htm>

## Scope

This replaces the storage availability treatment in 0048. Offered energy bands still bound
dispatch in this change; their separate CVP1135 treatment is independent follow-up work.
No state-of-charge constraint is introduced into real-time dispatch. Existing FCAS constraints,
bid prices and net ramp rows remain in force, so violation priorities combine when several
constraints conflict.

## Validation

The full Simulations suite passed 3,021 assertions across 16 groups. The root suite
passed 1,624 assertions. A temporary checkout combining the storage and
total-offer changes passed 152 assertions across the energy-limit, storage-availability and
total-offer groups, plus 10 assertions checking cumulative storage penalties. A 60 MW target
with 30 MW availability and 40 MW offered bands stops at 40 MW under conformance weight 1160,
and reaches 60 MW under weight 1600, paying both violations.

Cached complete-input replays of 2 January 2026 02:00 and 1 January 2026 04:55 AEST retained
all four published Snowtown targets within 1e-8 MW. All four dispatch/pricing solver calls were
optimal and passed independent primal-residual and objective-consistency checks. The maximum
regional price error was 0.000518 dollars/MWh and maximum unit dispatch error was 0.003749 MW.
These two intervals do not establish full-day equivalence.

Reproducible result CSVs, audit scripts, environments, logs and source patches are archived at
`/run/media/simba/Store/aem_validation/stock_sim/elastic_dispatch_violations_20261018`.
