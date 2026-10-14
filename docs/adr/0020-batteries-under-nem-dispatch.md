# 0020. Batteries under `AbstractNEMDispatch`

## Status

Accepted

## Context

AEMO calls a battery a bidirectional unit (BDU): one `DUID` with a `DUDETAILSUMMARY.DISPATCHTYPE`
of `BIDIRECTIONAL`, one `DISPATCHLOAD` row carrying `INITIALMW`/`TOTALCLEARED` as net MW (negative
when charging), and two `BIDPEROFFER_D` rows per trading interval - `DIRECTION = GEN` and
`DIRECTION = LOAD` - each with its own `MAXAVAIL`. Checked directly against 2026-06-04 real data:
a BDU's 5-minute net move never exceeded `DISPATCHLOAD.RAMPUPRATE`/`RAMPDOWNRATE` ("the lesser of
bid or telemetered"), including 439 zero crossings (charging to discharging or back within one
interval).

`AbstractNEMDispatch` ([`0013`](0013-uniform-nem-dispatch-formulation.md)) already gives every
generator the same treatment: a bid stack, a ramp limit measured from `INITIALMW`, and the
`DISPATCHLOAD.AVAILABILITY` envelope, on one active power variable. A battery does not fit that
shape directly - it has two directions, each with its own offer and its own availability - so it
had been left on `StorageSystemsSimulations.jl`'s formulation instead, which tracks state of
charge. NEMDE carries no state of charge: it clears one interval at a time against `INITIALMW` and
the submitted bid stacks, the same as every other participant. Reusing a formulation built around a
storage level pulls in a constraint NEMDE does not have and a variable (`EnergyLevelVariable`,
tied to a numeric `storage_capacity`) with no `DISPATCHLOAD` field behind it.

Python nempy (`spot_market_backend/variable_ids.py`, `ramp_rate_processing.py`) is the blueprint
already used to cross-check this package's NEMDE formulations. It represents a bidirectional unit
as two rows - a generator side and a load side - each carrying its own ramp rate and offer, and
computes a *composite* ramp rate from both before constraining the net (`_calculate_composite_ramp_rates`,
`_bidirectional_ramp_constraints`), following AEMO's SO_OP_3705 Dispatch Procedure Appendix C: the
up/down ramp rate applied to a unit that starts on one side of zero and may cross to the other is
a blend of the generation-side and load-side bid rates, weighted by how much of the dispatch
period is spent on each side.

## Decision

### Two variables, one formulation, no new type

A battery gets `PSI.ActivePowerOutVariable`/`PSI.ActivePowerInVariable`, both `>= 0`, through
methods of the *existing* `AbstractNEMDispatch` specialised on `T <: PSY.Storage` - not a new
formulation type, and not a device-type list added to `nem_dispatch_participants`. This mirrors
[`0013`](0013-uniform-nem-dispatch-formulation.md)'s own reasoning: NEMDE dispatches on market
participation, not on technology, so the formulation stays written against a PSY abstract type and
the template decides which components it applies to. A battery becomes a participant exactly the
way a generator does - by carrying the series the formulation reads - which is why
`get_default_time_series_names` is overridden for `PSY.Storage` to drop `"max_active_power"`: a
battery's availability is not one ceiling but two, read separately.

### Per-direction availability, read at build

`Out[t] <= gen[t]` and `In[t] <= load[t]` come from `get_storage_energy_max_avail`, which reads
the `"energy_max_avail"`/`"energy_max_avail_decremental"` `Deterministic` series `set_market_bids!`
now attaches from each direction's `BIDPEROFFER_D.MAXAVAIL` - the same per-direction bid data
FCASMarket already reads (`get_fcas_trapezium`/`get_fcas_offer_curve`), not
`DISPATCHLOAD.AVAILABILITY`, which is a single number and does not exist for the two sides
separately. Like the FCAS series, this is read directly at build over the model's own window
rather than through `PowerSimulations.jl`'s `TimeSeriesParameter`/`add_parameters!` machinery:
that machinery expects the container's own time-series type (`SingleTimeSeries`, matching the
dispatch-limit series), while `set_market_bids!` writes `Deterministic` bid-window series, same as
the FCAS trapezium/offer-curve data.

### Ramp on net `Out - In`, the DISPATCHLOAD rate, not the composite formula

`NEMReplayDispatch` bounds `Out - In` by `INITIALMW ∓ rate · interval`, reading
`DISPATCHLOAD.RAMPUPRATE`/`RAMPDOWNRATE` exactly as a generator's single rate - the real-data check
above confirms this rate is already the resolved bound NEMDE actually enforced for that interval,
composite or not. `NEMLookaheadDispatch` chains the same net quantity from the previous interval,
with a new `StorageInputDevicePower` initial-condition type paired with `PSI.DevicePower` (mapped
to `Out`) so the initial-conditions sub-model - which already re-runs this same `construct_device!`
under `NEMReplayDispatch` - hands both directions' solved values to the parent model.

What this does not do: compute AEMO's Appendix C composite ramp rate from the gen-side and
load-side *bid* rates for an interval NEMDE has not yet dispatched. `NEMReplayDispatch` never
needs it, since `DISPATCHLOAD` already carries the resolved rate for every interval it replays.
`NEMLookaheadDispatch` does need it for a genuinely forward interval that might cross zero, and
does not have it: it chains the same flat `RAMPUPRATE`/`RAMPDOWNRATE` series forward instead. This
is a real gap in the lookahead mode's fidelity for a battery that crosses zero mid-lookahead,
left out of scope here.

### No exclusivity, no state of charge

Nothing stops `Out` and `In` from being simultaneously nonzero in the same interval - the plain LP
nempy's bidirectional-unit model also is has no such constraint, and NEMDE's own formulation is a
single LP with no binary variables. Adding one would be inventing a constraint neither blueprint
has. `storage_capacity`/`storage_level_limits` on the `EnergyReservoirStorage` component go
unused by this formulation; nothing here reads or writes state of charge.

### Why not `StorageSystemsSimulations.jl`

Its formulation is built around an energy-level state variable balanced interval-to-interval by
charge/discharge, which is precisely the state NEMDE does not carry. Bending it to a NEMDE battery
would mean either a fake unconstrained storage capacity standing in for "no state of charge" or a
second, parallel bookkeeping path alongside the `INITIALMW`/bid-stack path every other participant
already uses. The uniform-formulation decision this ADR extends exists specifically to remove that
kind of technology-shaped branch.

## Consequences

- A `System`'s batteries need `set_market_bids!` (for the per-direction bid stack and MAXAVAIL) and
  `set_nem_dispatch_limits!`/`set_nem_initial_conditions!` (for ramp/initial series) run before a
  template can be built, exactly like a generator - `nem_dispatch_participants` excludes any
  battery missing the ramp/initial series the same way it excludes an unset generator.
- `StorageSystemsSimulations.jl` is no longer used anywhere in this package - not in package code,
  tests, or the real-data suite - and does not appear in any `Project.toml`.
- A battery's dispatch can show `Out` and `In` both positive in the same interval. This is an
  accepted limitation of the plain-LP formulation, not a bug; a later formulation could add
  exclusivity if evidence from real dispatch outcomes shows it matters.
- `NEMLookaheadDispatch` on a battery whose lookahead window would cross zero uses the flat
  `DISPATCHLOAD` rate rather than AEMO's composite ramp rate for those forward intervals. This
  under- or over-states the true ramp bound for exactly that case; closing it needs the gen-side/
  load-side bid ramp rates (not just `DISPATCHLOAD`'s resolved number) and the Appendix C formula,
  neither of which this change reads or implements.
