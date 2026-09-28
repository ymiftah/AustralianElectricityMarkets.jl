# 0017. `FCASMarket`: direct bid reads, two-sided joint capacity, storage energy terms, §5 gating

## Status

Accepted

## Context

PR 2.5 gives `FCASService` (Phase 1's `(REGIONID, BIDTYPE)` market anchor) a `PowerSimulations.jl`
formulation: a per-`(device, t)` capacity variable, the AEMO *FCAS Model in NEMDE* §6.2/§6.3
joint capacity constraint, and an offer cost. Three design points needed a decision before writing
it, and one duplication needed collapsing.

### Trapezium and offer-curve data bypass `PSI.TimeSeriesParameter`

`set_fcas_bids!` attaches a device's trapezium and offer curve as `Deterministic` time series,
genuinely varying per interval — unlike every other series `AustralianElectricityMarketsSimulations`
formulations read, which are `SingleTimeSeries` turned into `DeterministicSingleTimeSeries`
forecasts by `transform_single_time_series!`. Mixing the two `Forecast` families in one `System`
was flagged as an open risk going in: `PowerSystems.jl` requires every `Forecast`-derived series
in a `System` to share one `(initial_timestamp, resolution, count, horizon)`, and it was not known
whether a second family, added directly, would be accepted.

A spike (add a `Deterministic` series to a `PowerSystemCaseBuilder` toy system alongside a
transformed `SingleTimeSeries`) confirmed the invariant is checked on **horizon** (window length)
alone, not on which `Forecast` subtype is present or how many windows each series carries. A
`Deterministic` series with a horizon matching the system's established horizon is accepted
regardless of family; one with a different horizon is rejected with
`ConflictingInputsError`. Since `set_fcas_bids!` is always called over the same `date_range` as
every other series-writing setter, this holds automatically in ordinary use.

Given that, `FCASMarket` reads `get_fcas_trapezium`/`get_fcas_offer_curve` directly at both
construct stages, using `PSI.get_initial_time(container)` and `length(PSI.get_time_steps(container))`
as the window — the same way `_invoked_mask` reads a `GenericConstraint`'s `"invoked"` series.
No `PSI.TimeSeriesParameter` is registered for either series: they are read once at build time,
not re-read across a rolling-horizon rebuild. That is an accepted limitation, not an oversight —
FCAS bid values change from one solve to the next in the same way energy bids do, and a rolling
simulation harness would need to rebuild the model per interval regardless.

### Offer cost is band variables, not a stored epigraph

A `PSY.PiecewiseStepData` offer curve is a step function in price with non-decreasing bands, so
the accumulated cost of enabling `x` MW is convex piecewise-linear. Two ways to price it in a
minimisation LP are equivalent at the optimum: an epigraph variable bounded below by each linear
segment, or a bounded variable per band summing to the capacity variable with the band's own price
in the objective. The second was chosen: it needs no extra inequality per band beyond a bound and
one summing equality, and convexity plus non-decreasing prices guarantees the solver fills the
cheapest band first without any special ordering constraint. The band variables are plain `JuMP`
variables local to the cost-building function, not registered in `PSI`'s variable store — nothing
needs their value back (no per-band dispatch is reported), only their contribution to the
objective.

### Both forms of the joint capacity constraint apply to every service

AEMO's *FCAS Model in NEMDE* §6.2 states two constraint equations for **each** contingency
service, not one chosen by the service's own raise/lower direction:

```text
Energy + UpperSlopeCoeff×Contingency + [RaiseRegEnabled]×RaiseRegTarget ≤ EnablementMax
Energy − LowerSlopeCoeff×Contingency − [LowerRegEnabled]×LowerRegTarget ≥ EnablementMin
```

using that service's own trapezium in both, and the same `Contingency` variable in both. §6.3
states the regulation analogue — the same two forms, using the regulation trapezium's own slopes,
with no cross term (a regulation service never references another service's target on its own
constraint). An earlier draft of this formulation built only the form matching a service's own
direction (upper only for a raise service, lower only for a lower service); that is wrong per the
document and was caught by hand-deriving that a naive "maximise total FCAS" acceptance-test
objective would trade `RAISEREG` down to zero to grow `RAISE5MIN` beyond its published value,
which cannot happen once `RAISEREG`'s upper-form appearance in *every* raise service's constraint
is present alongside the lower-form's `LOWERREG` appearance in every lower service's constraint.

`FCASMarket` therefore builds two `FCASJointCapacityLHS` expressions and two
`FCASJointCapacityConstraint` rows per service (`"<name>_upper"`/`"<name>_lower"` in each
container's `meta`), covering every service the same way regardless of direction. A regulation
service's own two forms use only its own slope/target, matching §6.3's lack of a cross term.

`RAISEREG`'s own target is *not* determined by either form in real dispatch — AEMO's §6.1 joint
ramping constraint pins it, deferred to a later PR (see the Phase 2 plan, 2.9). The acceptance test
fixes it to the published value directly, matching the literate example's own framing of it as a
given input for this worked case, not a value this formulation derives.

### The joint LHS is an `ExpressionType`, not an ad hoc `JuMP` expression

Each side's left-hand side is registered as `FCASJointCapacityLHS`, filled incrementally like
`LinearFactorLimit`'s `NEMConstraintLHS`: `ArgumentConstructStage` adds the energy and own-slope
terms (safe there — they reference only the device's own energy variable and this service's own,
just-created capacity variable); `ModelConstructStage` adds the cross-service regulation term
(only safe once every service has passed `ArgumentConstructStage`) and turns the completed
expression into the `@constraint`. This gives a real, keyed per-`(device, t)` container that a
later PR (2.6's requirement terms, 2.8's elastic slack) can append to, rather than requiring it to
reconstruct the LHS from scratch.

### A `PSY.Storage` device's energy term: net on contingency, the bid side's own on regulation

Real `BIDPEROFFER_D` data (2026-06-04) shows battery contingency FCAS bid with
`DIRECTION = BIDIRECTIONAL`, against a trapezium on the **net** MW axis — `EnablementMin` runs
negative (observed to −460 MW) on the charging side. The contingency energy term is therefore the
net `ActivePowerOutVariable − ActivePowerInVariable`.

Regulation comes as separate `GEN` and `LOAD` rows, each a trapezium for one side of the unit
(§2.4 Figures 6/7, §6.3 footnote 8). Each side's joint capacity rows read that side's own energy:
`ActivePowerOutVariable` for a `GEN` (incremental) bid, `−ActivePowerInVariable` for a `LOAD`
(decremental) one — as nempy does (`energy_and_regulation_capacity_constraints` takes the energy
variable from the trapezium row's dispatch type; `variable_ids.py` gives load-side energy a −1
coefficient).

AEMO does not name the energy term for a BDU side outright, but §6.3 footnote 8 settles it: NEMDE
builds one energy-and-regulation constraint pair per side. If each side's pair read net energy, a
unit bidding both sides would face `net ≥ EnablementMin_GEN = 0` from the generation side and
`net ≤ EnablementMax_LOAD = 0` from the load side (§2.4's contiguity rule), pinning it at exactly
zero — so each pair reads its side's own energy, and a one-sided bid is the same pair built for one
side. Where AEMO does work on the net axis is §5: the "stranded" pre-condition compares the net
`InitialMW` against the side's trapezium, so a battery charging at the start of the interval is not
enabled for generation-side regulation at all. A reviewer argued for the net term on a one-sided
bid (it "traps" the unit within the trapezium, as §6.3 describes for generators); it was rejected
because it contradicts the both-sided case above, and because net energy with a `GEN`-side
trapezium on `[0, EnablementMax]` forbids charging outright even at `R = 0`.

### The sign-swapped §6.2 form is unreachable — no scheduled-load device type exists yet

§6.2 states a second, sign-swapped constraint pair (`+LowerReg`/`−RaiseReg`) for **scheduled
loads** specifically — a `PowerLoad`-like participant bidding FCAS while consuming, distinct from
a bidirectional unit. `set_fcas_bids!` never attaches a decremental series to anything but
`PSY.EnergyReservoirStorage`, so a decremental bid on a non-`Storage` device cannot occur from this
package's own data pipeline today. `_fcas_energy_terms` throws for that combination instead of
guessing at a sign convention with no real device to validate it against, and
`check_fcas_services` reports it as a pre-flight problem rather than a build-time throw. Modelling
a genuine scheduled load is future work, tracked in the Phase 2 plan rather than a swapped code
path nothing exercises.

### §5 enablement pre-conditions: the computable subset

A device NEMDE would not enable for a service (per §5) still had a live `FCASCapacityVariable` in
an earlier draft, capable of forcing an offline or out-of-range unit "on". `FCASMarket` now checks,
per `(device, t)`, the pre-conditions computable from data already in the `System`:

- `MaxAvail > 0`.
- at least one priced offer band with positive quantity.
- `EnablementMax ≥ EnablementMin`.
- the sign pre-condition: `EnablementMax ≥ 0` for a non-`Storage` device; for a `Storage` device,
  `EnablementMax ≥ 0` on a generation-side (incremental) regulation bid, `EnablementMin ≤ 0` on a
  load-side (decremental) one, and no sign requirement for a contingency bid.
- the energy-maximum-availability pre-condition: for a non-`Storage` device,
  `EnergyMaxAvail ≥ EnablementMin`, with `EnergyMaxAvail` the raw `DISPATCHLOAD.AVAILABILITY`
  (`set_nem_dispatch_limits!`'s `"availability"` series, read by `get_energy_availability`) — the
  bid `MAXAVAIL`, already the lower of `MAXAVAIL` and UIGF for a semi-scheduled unit, as §5 asks.
  The `"max_active_power"` series is not used: it raises `AVAILABILITY` to the ramp-down floor, so
  it would over-enable. For a `Storage` device, §5's per-side forms on each direction's energy bid `MAXAVAIL`
  (`BIDPEROFFER_D`, attached by `set_market_bids!`): load-side regulation requires
  `−EnergyMaxAvail_LOAD ≤ EnablementMax`, generation-side regulation requires
  `EnergyMaxAvail_GEN ≥ EnablementMin`, and contingency requires both. §5's "Energy Max
  Availability" is the bid availability, as nempy also reads it (`_get_unit_availability`,
  `get_unit_bid_availability`). `DISPATCHLOAD.AVAILABILITY`/`MIN_AVAILABILITY` carry the same values
  for a BDU, but `MIN_AVAILABILITY` is not in the cached `DISPATCHLOAD` column list. Without the bid
  series the device's static output/input ratings stand in, which only ever over-enables.
- the "stranded" pre-condition, with `InitialMW` from `set_nem_dispatch_limits!`'s `"initial_mw"`
  series (`get_initial_mw`): `EnablementMin ≤ max(InitialMW, 0) ≤ EnablementMax` for a
  non-`Storage` device and `EnablementMin ≤ InitialMW ≤ EnablementMax` on the raw net figure for a
  `Storage` device (§5's "all other types of FCAS bids from bidirectional units"). Under
  `NEMLookaheadDispatch` it is checked in the first interval only: later intervals start from the
  model's own dispatch, not a metered `INITIALMW`, and NEMDE's pre-dispatch likewise gates only its
  first interval on telemetry.

A disabled `(device, t)` gets its `FCASCapacityVariable` bounded to exactly zero and a vacuous
`0.0 ≤ 1.0` row in place of both real constraints — matching AEMO's own "no joint capacity
constraint is created" for an unenabled unit, while keeping the dense dual containers valid. The
enablement mask is recomputed from the same inputs at both construct stages (`_fcas_enabled_mask`)
rather than inferred from the variable's upper bound, which a later formulation may change.

Not checked: AGC status (no telemetry in MMSDM) and the daily/profiled-energy pre-conditions (no
data this package reads carries them).

### Malformed offered trapeziums are rejected on read, as AEMO rejects them on submission

AEMO validates an FCAS bid against the unit's registration (`BIDDUIDDETAILS`) when it is submitted
and rejects a malformed one, so it never reaches NEMDE or `BIDPEROFFER_D`. A scan of every cached
FCAS row (2025-01 to 2026-07, ~290M rows) found no row breaking
`EnablementMin ≤ LowBreakpoint ≤ HighBreakpoint ≤ EnablementMax` or `MaxAvail ≥ 0` (§2 Figure 1).
The same scan found 22 BDUs whose GEN regulation rows have `EnablementMin < 0` and LOAD rows
`EnablementMax > 0` (e.g. TEMPB1 at ±111 MW), so §2.4's "generation side non-negative, load side
non-positive" is not a submission rule; the §5 sign pre-condition handles those rows at dispatch.

`_extract_fcas_bid` (on parse) and `get_fcas_trapezium` (on every read, catching hand-attached
series) therefore throw on a broken ordering or a negative `MaxAvail`. Only the offered trapezium is
checked: §4 scaling can legitimately push `EnablementMax` below `EnablementMin`, which the §5
`EnablementMax ≥ EnablementMin` gate disables rather than rejects. The registration-envelope checks
(enablement levels and slope angles within `BIDDUIDDETAILS`) are not replicated: that table is not
cached.

### Collapsing the duplicate trapezium-slope arithmetic

`AustralianElectricityMarketsSimulations/src/replication/preprocessing.jl` carried its own
`EffectiveTrapezium` struct and `lower_slope_coeff`/`upper_slope_coeff` functions, duplicating
root's `FCASTrapezium`/`get_lower_slope_coeff`/`get_upper_slope_coeff`. `EffectiveTrapezium` held
the same five fields as `FCASTrapezium` (plus the two optional regulation ramp rates
`FCASTrapezium` already carries), so `scale_trapezium` now returns an `FCASTrapezium` directly and
the local slope functions are gone; callers use root's accessors.

## Decision

- `FCASMarket` reads FCAS trapezium/offer-curve data directly from the `System`'s `Deterministic`
  series at each construct stage, registering no `PSI.TimeSeriesParameter` for them.
- The offer cost is priced through bounded, per-band `JuMP` variables summing to the capacity
  variable, scaled by `PSI.get_base_power(container)` to bring the natural-`\$`/MW offer price back
  to real dollars against a per-unit capacity variable, not a stored `PSI`-registered epigraph.
- Both forms of the §6.2/§6.3 joint capacity constraint are built for every service, as two
  `FCASJointCapacityLHS` expressions and two `FCASJointCapacityConstraint` rows keyed
  `"<name>_upper"`/`"<name>_lower"`.
- A `PSY.Storage` device's energy term is its net `ActivePowerOutVariable −
  ActivePowerInVariable` on contingency and the bid side's own energy on regulation; a decremental
  bid on any other device type throws, since no scheduled-load device type exists in this package
  yet.
- The computable subset of §5's enablement pre-conditions gates each `(device, t)`'s
  `FCASCapacityVariable` to zero and its constraint rows to a vacuous `0.0 ≤ 1.0` pair.
- `scale_trapezium` returns an `FCASTrapezium`; `EffectiveTrapezium` and the local
  `lower_slope_coeff`/`upper_slope_coeff` are removed from `AustralianElectricityMarketsSimulations`.

## Consequences

- FCAS data does not participate in `PowerSimulations.jl`'s parameter-update path; a rolling
  simulation harness rebuilds the model each interval, same as it already must for the market-bid
  cost data `AbstractNEMDispatch` reads.
- Per-band FCAS dispatch is not retrievable from a solved model's results — only the aggregate
  `FCASCapacityVariable`. Retrievable per-band detail can be added later without changing the cost
  arithmetic, by registering a real `PSI.VariableType` for the bands.
- §6.1 joint ramping (regulation's own binding constraint in real dispatch) remains unimplemented;
  a `FCASMarket` build lets a regulation service's capacity rise as far as its own trapezium and
  `MAXAVAIL` allow, which a `System` with no ramping data will not correct.
- A device carrying both an incremental and a decremental series for the same market — a battery
  bidding regulation on both sides — throws at build; its per-side model (§6.3 footnote 8, §6.4)
  is a separate formulation step.
- `FCASMarket` throws when built for recurrent solves (a `Simulation`), since it reads FCAS data
  and the §5 gate once at build; records duals only for `FCASJointCapacityConstraint`, throwing on
  any other requested type; and throws when a device contributes to more than one `FCASService`
  of the same market, since each would carry its own `MaxAvail`-bounded capacity and only one
  regulation target could enter the §6.2 rows. `check_fcas_services` reports the same up front,
  scoped to the available services and devices the template models under `FCASMarket`.
- The AGC-on and daily/profiled-energy §5 pre-conditions are not enforced; a `System` that would
  fail one of those in real dispatch is not caught here.
