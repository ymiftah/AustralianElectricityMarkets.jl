# 0017. `FCASMarket`: direct bid reads, two-sided joint capacity, net storage energy, per-side BDU regulation, §5 gating

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
  `−InputActivePowerLimit.max ≤ EnablementMax` and `OutputActivePowerLimit.max ≥ EnablementMin`.
  §5 states only one of these two inequalities per regulation side (the other for contingency);
  `_fcas_energy_max_avail_ok` checks both regardless, on each side's own call, an accepted
  over-check rather than a per-side split of this particular pre-condition.
- the "stranded" pre-condition: `EnablementMin ≤ max(InitialMW, 0) ≤ EnablementMax` for a
  non-`Storage` device (`InitialMW` from `PSI.InitialPowerTimeSeriesParameter`); the combined
  both-sides form below for a `PSY.Storage` device bidding regulation on both sides; `EnablementMin
  ≤ InitialMW ≤ EnablementMax` (that side's own trapezium, raw `InitialMW`, no clamp) for any other
  `PSY.Storage` bid (`InitialMW` from [`get_storage_initial_mw`](@ref)). Skipped wherever the
  relevant `InitialMW` series isn't attached.
- for a regulation service, the AGC-status pre-condition: `agc_status != 0`
  ([`get_fcas_agc_status`](@ref)), skipped when not attached.

A disabled `(device, t)` gets its `FCASCapacityVariable` bounded to exactly zero and a vacuous
`0.0 ≤ 1.0` row in place of both real constraints — matching AEMO's own "no joint capacity
constraint is created" for an unenabled unit, while keeping the dense dual containers valid.

Not checked: the daily/profiled-energy pre-conditions (no data this package reads carries them).

### Collapsing the duplicate trapezium-slope arithmetic

`AustralianElectricityMarketsSimulations/src/replication/preprocessing.jl` carried its own
`EffectiveTrapezium` struct and `lower_slope_coeff`/`upper_slope_coeff` functions, duplicating
root's `FCASTrapezium`/`get_lower_slope_coeff`/`get_upper_slope_coeff`. `EffectiveTrapezium` held
the same five fields as `FCASTrapezium` (plus the two optional regulation ramp rates
`FCASTrapezium` already carries), so `scale_trapezium` now returns an `FCASTrapezium` directly and
the local slope functions are gone; callers use root's accessors.

### A `PSY.Storage` device bidding regulation on both sides: two capacity variables, per-side (§6.3 footnote 8, §6.4)

`_fcas_direction` throws whenever a non-`PSY.Storage` device carries both an incremental and a
decremental series for the same market. Real `BIDPEROFFER_D` data shows carrying both is the
*common* case for a battery's `RAISEREG`/`LOWERREG`: a `DIRECTION = GEN` row (generation-side bid)
and a `DIRECTION = LOAD` row (load-side bid), both against the net-MW axis (2026-06-04, e.g. DUID
`WANDB1`: `RAISEREG` GEN `EnablementMin/Max = 0/100`, `MaxAvail = 100`; `RAISEREG` LOAD
`EnablementMin/Max = -75/0`, `MaxAvail = 75`). Contingency FCAS from the same device is unaffected —
AEMO's *FCAS Model in NEMDE* v3.0 §2.4 (pp. 9-10, Figure 5) bids a BDU's contingency service as one
trapezium spanning the whole net-MW axis, submitted once (`DIRECTION = BIDIRECTIONAL`), so
`set_fcas_bids!` only ever attaches it as the incremental series; `_fcas_direction` returning
`:both` is only reachable for a regulation market.

An earlier revision of this ADR modelled both sides against one combined `FCASCapacityVariable`
and an amalgamated trapezium (upper form from the generation side, lower form from the load
side), citing §2.4's "amalgamated only for bid validation, the §5 initial-point precondition,
trapped/stranded, and availability" and §7.1's footnote that "the regulation FCAS trapeziums are
treated independently during the NEMDE optimisation but are amalgamated into one aggregate
trapezium for the availability calculations". Re-reading §6.3 footnote 8 and §6.4 together shows
that reading conflated "amalgamated for publication" with "amalgamated for optimisation": §6.3
footnote 8 states NEMDE creates *a pair of* energy-and-regulating-FCAS-capacity constraints "for
the generation side of the unit, the load side of the unit, or for both sides", each pair against
that side's *own* trapezium and that side's *own* regulating FCAS target — not one pair against an
amalgamated shape — and §6.4 names a *separate* target for each side ("Raise Regulation FCAS
Target"/"Lower Regulation FCAS Target" per side, capped individually and, for the unit as a whole,
jointly). `FCASMarket` now builds that directly:

- **Two capacity variables per `(device, t)`.** `FCASSideCapacityVariable`, one instance keyed
  `"<service>_gen"` and one keyed `"<service>_load"` (both keyed by device name, `both_names`:
  the devices bidding both sides of that service). Each is bounded above by its own side's scaled
  `MaxAvail` (`get_scaled_fcas_trapezium(...; decremental)`) and gated by its own side's §5
  pre-conditions via [`_fcas_enabled`](@ref) (`check_stranded = false` — see below).
- **Each side pairs with its own energy term.** The generation side's `FCASJointCapacityLHS`
  (`"<service>_gen_upper"`/`"_gen_lower"`) carries only `ActivePowerOutVariable`; the load side's
  (`"<service>_load_upper"`/`"_load_lower"`) carries only `-ActivePowerInVariable`
  ([`_fcas_side_energy_terms`](@ref)) — not the net `Out - In` the single-sided/contingency path
  uses. Each side's own slope term (`UpperSlopeCoeff`/`LowerSlopeCoeff` from that side's own
  trapezium) is added the same way the single-sided path already does.
- **A `FCASUnitRegulationTarget` expression is the unit's published total.** `Reg_gen + Reg_load`
  for a both-sided device, or the single `FCASCapacityVariable` for a one-sided device — built once
  per contributing device of a regulation service, keyed by the device's own name. §6.2's joint
  capacity constraint (the `[RaiseRegEnabled]×RaiseRegTarget` cross term on another service's own
  constraint) reads this expression via `_device_regulation_target`, replacing the earlier direct
  `FCASCapacityVariable` lookup — the "target" AEMO's constraint equations reference is always the
  unit's total, whether the unit bid one side or two.
- **§6.4's BDU SCADA ramping constraint bounds that same total.** `FCASBDURampingConstraint`,
  built only for both-sided devices on a regulation service, `Reg_gen + Reg_load ≤` the device's
  AGC ramping capability (`get_fcas_agc_ramp_capability`, the same `RAMPUPRATE`/`RAMPDOWNRATE ×
  interval` quantity §4.2 already scales each side's own `MaxAvail` by) — skipped (no constraint
  row) for a `(device, t)` carrying no ramp-capability series. AEMO's own text motivates this as
  preventing exactly the "double-counting" the combined-variable model above could not represent:
  each side's own `MaxAvail` is independently capped at the ramp capability by §4.2, but nothing
  stopped both sides reaching that cap *simultaneously* until this constraint sums them.
- **Offer cost is priced per side, against that side's own curve**, via two independent
  `_add_fcas_offer_cost!` calls (one per `FCASSideCapacityVariable`) rather than one call against
  a merged curve — `_merge_offer_curve` is removed, since a genuine price difference between the
  two sides' bids (real data shows one) is now respected without needing to pre-sort it into one
  curve.

**§5's combined stranded pre-condition, not two independent per-side checks.** The document's own
bullet for a both-sides regulation bid (p. 19) is a single combined inequality,
`EnablementMin_LOAD ≤ InitialMW ≤ EnablementMax_GEN` (raw net `InitialMW`, not `Max[InitialMW,
0]` — that clamp is only in the non-bidirectional bullet), gating *both* sides together: if it
fails, neither side is enabled, regardless of what each side's own sign/energy-max-avail
pre-conditions would otherwise allow. [`_fcas_both_sides_enabled`](@ref) evaluates each side's own
pre-conditions independently (`check_stranded = false` on each [`_fcas_enabled`](@ref) call) and
ANDs the result with this one combined check. `InitialMW` comes from
[`get_storage_initial_mw`](@ref) ([`set_storage_initial_mw!`](@ref) — `PSY.Storage` is not one of
the device types `set_nem_dispatch_limits!` covers, so it gets its own, narrower setter attaching
only `"initial_mw"`, reusing `read_dispatch_limits`); `nothing` (no series attached) skips the
check, as for the single-sided case.

**§5's AGC status pre-condition.** "In real time dispatch... the unit must be on AGC to be enabled
for regulating FCAS" (p. 18) applies to every regulation bid, one- or two-sided:
[`_fcas_enabled`](@ref) now takes `agc_status` (from [`get_fcas_agc_status`](@ref) /
`"fcas_agc_status"`, `DISPATCHLOAD.AGCSTATUS`) and returns `false` whenever `agc_status == 0` and
`is_regulation`. `nothing` (no series attached) does not gate — this package cannot distinguish
"known off AGC" from "AGC status not tracked for this `System`" without it. This closes the
`scale_fcas_trapezium` DUID-level AGC-enablement-window anomaly noted for `AGCSTATUS = 0`
intervals in ADR-0018: those intervals are now excluded from regulation enablement directly,
rather than relying only on that function's own defensive guard against an internally
inconsistent window.

A non-`PSY.Storage` device carrying both directions of any market, or a `PSY.Storage` device
carrying both directions of a *contingency* market, still throws: `_fcas_direction` only returns
`:both` for a `PSY.Storage` device on a regulation market; `check_fcas_services` reports the same
restriction as a pre-flight problem instead of a build-time throw.

**Not modelled: §6.1 joint ramping.** The unit's regulation target is still not bound by the
telemetered AGC ramp rate against its *energy* dispatch (as opposed to §6.4's bound against the
*other side's* regulation target) — tracked in the Phase 2 plan, unchanged by this revision.

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
- A `PSY.Storage` device bidding a regulation market on both sides gets two
  `FCASSideCapacityVariable`s per `(device, t)` (`"<service>_gen"`/`"<service>_load"`), each
  bounded above by that side's own scaled `MaxAvail`, each constrained by its own §6.3 joint
  capacity pair against its own trapezium and its own energy term (`Out` for the generation side,
  `-In` for the load side), and priced against its own offer curve. `FCASUnitRegulationTarget`
  (`Reg_gen + Reg_load`, or the single `FCASCapacityVariable` for a one-sided device) is the unit
  total §6.2's cross term and §6.4's ramping cap read. `FCASBDURampingConstraint` bounds that total
  against the device's AGC ramping capability for both-sided devices, skipped where no
  ramping-capability series is attached. Both directions of a contingency market, or of any market
  on a non-`PSY.Storage` device, still throw.
- The computable subset of §5's enablement pre-conditions gates each `(device, t)`'s capacity
  variable(s) to zero and its constraint rows to a vacuous `0.0 ≤ 1.0` pair; for a both-sides
  regulation bid, each side's own pre-conditions gate that side independently, ANDed with one
  combined stranded pre-condition gating both sides together. The AGC-status pre-condition gates
  every regulation bid, one- or two-sided.
- `set_storage_initial_mw!`/`get_storage_initial_mw` (root) attach/read a `PSY.Storage` device's
  net `"initial_mw"`, mirroring `set_nem_dispatch_limits!`'s `"initial_mw"` for the device types it
  covers; `get_fcas_agc_status` (root) reads `"fcas_agc_status"`
  ([`set_fcas_scaling_inputs!`](@ref)).
- `scale_trapezium` returns an `FCASTrapezium`; `EffectiveTrapezium` and the local
  `lower_slope_coeff`/`upper_slope_coeff` are removed from `AustralianElectricityMarketsSimulations`.
- Cross-checked against nempy (UNSW-CEEM/nempy, commit `2d3cef0`). The per-side model matches its
  `energy_and_regulation_capacity_constraints`, and its load-side energy sign flip
  (`spot_market_backend/variable_ids.py:160-172`). One difference: nempy's
  `joint_capacity_constraints` gives the load side's `lower_reg` coefficient `+1.0` in the lower
  form (`spot_market_backend/fcas_constraints.py:298-301`). Here the lower form subtracts the whole
  unit `LowerRegTarget`, as §6.2 states.

## Consequences

- FCAS data does not participate in `PowerSimulations.jl`'s parameter-update path; a rolling
  simulation harness rebuilds the model each interval, same as it already must for the market-bid
  cost data `AbstractNEMDispatch` reads.
- Per-band FCAS dispatch is not retrievable from a solved model's results — only the aggregate
  `FCASCapacityVariable`. Retrievable per-band detail can be added later without changing the cost
  arithmetic, by registering a real `PSI.VariableType` for the bands.
- §6.1 joint ramping (regulation's own binding constraint against a unit's *energy* dispatch in
  real dispatch) remains unimplemented; a `FCASMarket` build lets a regulation service's per-side
  capacity rise as far as that side's own trapezium, `MAXAVAIL` and (for a both-sided device)
  §6.4's ramping cap allow, which a `System` with no §6.1 ramping data will not further correct.
- The daily/profiled-energy §5 pre-conditions are not enforced; a `System` that would fail one of
  those in real dispatch is not caught here.
- A `PSY.Storage` device's per-side pre-conditions (sign, energy-maximum-availability) are
  evaluated per side, but the energy-maximum-availability check itself still checks both of §5's
  inequalities rather than only the one the bid side calls for (documented above) - an accepted,
  narrower remaining approximation than the one this revision replaces.
