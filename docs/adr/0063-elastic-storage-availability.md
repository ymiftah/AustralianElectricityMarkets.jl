# 0063. Price storage availability violations on the directional offer axes

## Status

Accepted.

## Problem

Storage dispatch used hard directional limits derived from bid MAXAVAIL. Replay raised these
limits to the metered ramp envelope in advance, allowing some availability exceedances without
their violation cost. Other conflicts, including non-conformance, could not exceed the ceiling.

## Sources

- AEMO, Schedule of Constraint Violation Penalty Factors v8.0, effective 2 December 2025,
  Table 1 item 14, pp. 13-17: energy MaxAvail uses deficit/surplus capacity variables at CVP370.
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

## PSI interface

Generation and charging have distinct constraint and surplus types. Variables are allocated
through `PSI.add_variables!` in the argument stage; the model stage uses `PSI.add_constraints!`.
The shared typed `PSI.add_proportional_cost!` applies CVP370 to each direction. A typed row
method preserves the charging row's negative net-dispatch orientation.

## Verification

Generated-system regressions cover both directions, ramp conflicts and their objective costs,
lower-priority instructions, forward/reverse recurrent updates, missing inputs and unused
crossed bid bands. The original 40 MW versus 60 MW storage conformance error was reproduced
before the port. Historical production replay evidence remains on PR #198; this port does
not claim a new real-data validation result.
