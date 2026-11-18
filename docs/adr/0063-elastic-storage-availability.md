# 0063 Storage availability violations priced per offer direction

## Status

Accepted. Extends [0062](0062-elastic-energy-limits.md) to `PSY.Storage`.

## What

- A storage device keeps non-negative generation (`ActivePowerOutVariable`) and consumption (`ActivePowerInVariable`) variables, each bounded by its own raw bid MAXAVAIL through a priced slack:
  - `generation - slack <= raw_generation_MAXAVAIL`;
  - `-consumption + slack >= -raw_consumption_MAXAVAIL`.
- Both slacks cost `ENERGY_MAX_AVAIL_CVP_FACTOR` (370) times the Market Price Cap, base power and interval hours. Static ratings and pre-raised dispatch ceilings do not bound dispatch.
- Sources: AEMO *Schedule of Constraint Violation Penalty Factors* v8.0 Table 1 item 14 (energy MaxAvail deficit/surplus at 370), items 2 and 3 (non-conformance 1160, unit ramp 1155); *Electricity Data Model Report* v5.7.0 BIDPEROFFER_D (MAXAVAIL is interval and direction specific); AEMO BDU final design workshop, 24 July 2023, pp. 40-41 (signed net dispatch).
- No state-of-charge constraint enters real-time dispatch.

## How

- `NEMUnitSlack` variants `energy_limit|max_avail_out` and `energy_limit|max_avail_in`; the limits are PSI's `ActivePowerOutTimeSeriesParameter` and `ActivePowerInTimeSeriesParameter` over the raw MAXAVAIL series. Violations report `up` for the generation bound and `down` for the consumption bound.
- Both raw series are required, finite and non-negative.

## Why

- The bounds sit on the directional offer axes, not on net dispatch. A net-only row would let a unit counterdispatch through unused crossed bands (for example generation MAXAVAIL zero with a raw generation price below the load price), and AEMO's bid convexity validation checks only effective bands limited by MAXAVAIL, so such offers are valid (AEMO *Bid convexity and monotonically increasing validation*, 30 May 2025). Directional costs prevent that unpriced circulation.
