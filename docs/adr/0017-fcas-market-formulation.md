# 0017. `FCASMarket`: direct bid reads, two-sided joint capacity, net storage energy, §5 gating

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

### A `PSY.Storage` device's energy term is its net (out − in) dispatch, always

Real `BIDPEROFFER_D` data (2026-06-04) shows battery contingency FCAS bid with
`DIRECTION = BIDIRECTIONAL`, against a trapezium on the **net** MW axis — `EnablementMin` runs
negative (observed to −460 MW) on the charging side. `set_fcas_bids!` stores `GEN`/`BIDIRECTIONAL`
rows as the incremental series and `LOAD` rows as decremental, but the *energy* term the joint
capacity constraint reads is not "whichever direction the series came from" — it is always the net
`ActivePowerOutVariable − ActivePowerInVariable`, for every FCAS market a `PSY.Storage` device
provides, contingency or regulation. `_fcas_direction`'s incremental/decremental result still
selects which trapezium/offer-curve series to read; it no longer selects which variable enters the
constraint for a storage device.

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
  `EnergyMaxAvail ≥ EnablementMin` (`EnergyMaxAvail` read from `PSI.ActivePowerTimeSeriesParameter`
  when the device carries it — this already folds in the semi-scheduled UIGF ceiling, since
  `set_nem_dispatch_limits!`'s own `"max_active_power"` series is the lower of bid `MAXAVAIL` and
  UIGF); for a `Storage` device, both static ratings must leave the trapezium reachable:
  `−InputActivePowerLimit.max ≤ EnablementMax` and `OutputActivePowerLimit.max ≥ EnablementMin`
  (applied the same for a contingency or a regulation bid — §5 only states the single-sided form
  per regulation direction, but this package does not yet distinguish a storage device's two
  regulation-side trapeziums enough to apply just one side correctly).
- the "stranded" pre-condition (`EnablementMin ≤ max(InitialMW, 0) ≤ EnablementMax`), checked only
  for a non-`Storage` device carrying `InitialPowerTimeSeriesParameter` (an `AbstractNEMDispatch`
  generator). No net initial-MW figure is available for a `PSY.Storage` device today, so this
  pre-condition is skipped for one rather than approximated.

A disabled `(device, t)` gets its `FCASCapacityVariable` bounded to exactly zero and a vacuous
`0.0 ≤ 1.0` row in place of both real constraints — matching AEMO's own "no joint capacity
constraint is created" for an unenabled unit, while keeping the dense dual containers valid.

Not checked: AGC status (no telemetry in MMSDM) and the daily/profiled-energy pre-conditions (no
data this package reads carries them).

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
- A `PSY.Storage` device's energy term is always its net `ActivePowerOutVariable −
  ActivePowerInVariable`; a decremental bid on any other device type throws, since no scheduled-load
  device type exists in this package yet.
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
- A bidirectional unit with separate generation-side and load-side regulation trapeziums is priced
  and constrained with the same net-energy term on both sides; the two sides' individually correct
  §5 energy-maximum-availability single-sided forms are not distinguished (see above). A device
  bidding both directions of the *same* market (rather than separate regulation sides) still
  throws, per the existing bidirectional-capacity limitation.
- The AGC-on and daily/profiled-energy §5 pre-conditions are not enforced; a `System` that would
  fail one of those in real dispatch is not caught here.
