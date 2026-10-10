# 0048. Storage variable bounds follow directional energy offers

## Status

Accepted

## Context

The storage model has separate non-negative `ActivePowerOutVariable` and
`ActivePowerInVariable` variables. Its existing interval availability rows read the generation-side
and load-side energy `MAXAVAIL` values, but the variables are created earlier with static
`PSY.Storage` output and input limits. A tighter static bound therefore remains active even when
the interval's accepted energy offer allows a larger dispatch.

This distinction appears in the public MMSDM inputs. AEMO describes `DUDETAIL.MAXCAPACITY` as the
maximum capacity used for bid validation, while `BIDPEROFFER_D` publishes interval and direction
specific `MAXAVAIL` for energy offers. In the 24 June 2026 15:15 AEST replay evidence, LIMBESS1's
static input limit was 50 MW, its LOAD energy offer had `MAXAVAIL = 100 MW`, and NEMDE published a
64.3102 MW charge target. This supports the input distinction; it does not establish that this
storage bound alone explains the observed regional price difference.

## Decision

For every `AbstractNEMDispatch` formulation, each storage power variable with a finite directional
ceiling from `_storage_dispatch_ceilings` also receives that ceiling as its JuMP upper bound. The
generation variable uses `gen`; the charging variable uses `load`. These are separate values. The
helper raises a directional ceiling when the replay net ramp floor requires it, retaining the
existing ramp-floor priority in the variable bound as well as the availability row. Lookahead keeps
its chained optimized-power ramp rows; it does not use the replay metered-floor calculation.

When no energy `MAXAVAIL` series covers a storage device, its static variable bounds remain and no
availability rows are added. A non-finite direction ceiling retains that direction's static bound,
subject to the existing ramp-floor exception. The change adds no new dispatch constraint or cost
term.

## Consequences

- Replay and lookahead dispatch may exceed a storage component's static directional limit when a
  finite direction-specific energy offer permits it.
- A finite offer ceiling continues to bound dispatch even when it is below the static limit.
- The change follows the MMSDM distinction between registered bid-validation capacity and
  interval energy offer availability. Dispatch still depends on all other active model constraints
  and costs; this decision alone makes no claim about a price outcome.

## Sources

- AEMO, [*Electricity Data Model Report*, `DUDETAIL`](https://visualisations.aemo.com.au/aemo/nemweb/MMSDataModelReport/MMS_247.htm)
  v5.7.0, effective 23 April 2026, pp. 504-508: `MAXCAPACITY` is the maximum capacity used for
  bid validation.
- AEMO, [*Electricity Data Model Report*, `BIDPEROFFER_D`](https://visualisations.aemo.com.au/aemo/nemweb/MMSDataModelReport/MMS_23.htm)
  v5.7.0, effective 23 April 2026, pp. 65-67: the public dispatch offer summary is keyed by
  `DIRECTION` and `INTERVAL_DATETIME`, and `MAXAVAIL` is the maximum availability for that bid type
  and period.
