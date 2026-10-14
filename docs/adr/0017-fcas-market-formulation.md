# 0017. `FCASMarket`: direct bid reads, two-sided joint capacity, storage energy terms, per-side BDU regulation, §5 gating

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

`RAISEREG`'s own target is not determined by either form alone in real dispatch: AEMO's §6.1
joint ramping constraint (below) also binds it. The acceptance test's fixture carries no AGC ramp
rate series, so §6.1 builds a placeholder row there; the test fixes the target to the published
value directly, matching the literate example's own framing of it as a given input for this worked
case, not a value this formulation derives.

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

Superseded by ADR 0038: loads are `InterruptiblePowerLoad` devices and offer FCAS in the swapped form.

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
  non-`Storage` device; `EnablementMin ≤ InitialMW ≤ EnablementMax` on the raw net figure for a
  one-sided `Storage` bid (§5's "all other types of FCAS bids from bidirectional units"); and the
  combined both-sides form below for a `PSY.Storage` device bidding regulation on both sides.
  Skipped wherever `"initial_mw"` isn't attached.
- for a regulation service, the AGC-status pre-condition: `agc_status != 0`
  ([`get_fcas_agc_status`](@ref)), skipped when not attached.

Under `NEMLookaheadDispatch`, `InitialMW` and AGC status are telemetry for the first interval only:
later intervals start from the model's own dispatch. §5 restricts the AGC-status check to the first
interval of both pre-dispatch processes. It states no such restriction for the stranded check, but
a later interval's `InitialMW` is the model's own previous dispatch target, a decision variable,
so the check cannot be a build-time gate there. Both checks are skipped after the first interval.

AEMO applies the telemetry-based steps over different intervals in each process (§4.4 Table 1,
§6.5 Table 3). `_fcas_process` reads the process off the device formulation and the model's
resolution: `NEMReplayDispatch` is dispatch; `NEMLookaheadDispatch` is 5-minute pre-dispatch at a
5-minute resolution and 30-minute pre-dispatch at a longer one. Dispatch replay is the target; the
pre-dispatch mapping follows AEMO's tables but is not validated against published pre-dispatch
outcomes.

| Step | Dispatch | 5-minute pre-dispatch | 30-minute pre-dispatch |
| --- | --- | --- | --- |
| §4.1 AGC enablement scaling | all | first | first |
| §4.2 AGC ramp scaling | all | first | none |
| §6.4 BDU SCADA ramping | all | first | none |
| §5 AGC status, stranded | all | first | first |

A disabled `(device, t)` gets its `FCASCapacityVariable` bounded to exactly zero and a vacuous
`0.0 ≤ 1.0` row in place of both real constraints — matching AEMO's own "no joint capacity
constraint is created" for an unenabled unit, while keeping the dense dual containers valid. The
enablement mask is recomputed from the same inputs at both construct stages (`_fcas_enabled_mask`)
rather than inferred from the variable's upper bound, which a later formulation may change.

Not checked: the daily/profiled-energy pre-conditions (no data this package reads carries them).

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
  ([`_fcas_side_energy_terms`](@ref)) — the same per-side term a one-sided regulation bid uses;
  only contingency reads the net `Out - In`. Each side's own slope term (`UpperSlopeCoeff`/`LowerSlopeCoeff` from that side's own
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
pre-conditions independently (`check_stranded = false` on each [`_fcas_enabled`](@ref) call), and
applies the combined check only when both sides pass them: a side that fails its own
pre-conditions (say `MaxAvail = 0`) is not really offered, so the unit is not "offering regulation
FCAS on both sides" and the side still enabled is checked against its own trapezium, as for a
one-sided bid. nempy does the same (it drops the unavailable side's row before the combined check).
`InitialMW` comes from [`get_initial_mw`](@ref) (`set_nem_dispatch_limits!`'s net `"initial_mw"`);
`nothing` (no series attached) skips the check.

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

**Per-side energy terms assume a battery does not charge and discharge at once.** NEMDE dispatches
a battery to one signed net target. Here the generation side's rows read `ActivePowerOutVariable`
and the load side's read `ActivePowerInVariable`, and ADR 0020 lets both be positive in the same
interval. Raising both by the same amount leaves net output unchanged but moves each side along its
own trapezium slope, so a solve that circulates energy can enable regulation NEMDE would not. The
real-data suite asserts that no battery charges and discharges in the same interval.

**§6.1 joint ramping** now bounds a unit's net energy dispatch combined with its
`FCASUnitRegulationTarget` against `InitialMW` plus or minus its AGC ramp (§6.4 bounds a
both-sided device's combined regulation target alone, with no energy term). It reads
`DISPATCHLOAD.RAMPUPRATE`/`RAMPDOWNRATE` (the "lesser of bid or telemetered rate"), not the
telemetered SCADA rate itself, which MMSDM does not publish - the row can be tighter than
NEMDE's when the bid rate of change is below the telemetered rate. It is hard until a later PR
adds the §6.1 surplus/deficit terms (NEMDE's own rows are soft), and Table 3's fast-start
exclusion (footnote 11) is not modelled. Under `NEMLookaheadDispatch` its own device ramp measures
against the `DevicePower` initial condition at `t = 1`, not `"initial_mw"`; where they differ,
§6.1 at a zero regulation target can conflict with the device's own ramp plus availability outside
the replay objective this package targets.

§6.1 departs from nempy twice, following AEMO. nempy's BDU row adds energy only for the dispatch
types carrying a regulation bid (`fcas_constraints.py:6-43`), so a single-sided BDU gets its own
side's energy; we use net energy for every `PSY.Storage` device, per §6.1's unit-level form (one
signed `INITIALMW`, one rate). nempy also builds rows at a zero ramp rate; we follow AEMO's "rate
greater than zero" condition.

Real-data evidence (2026-06-04, 1 hour, 1520 built §6.1 rows over both regulation services),
evaluated at NEMDE's published solution (`TOTALCLEARED`, published regulation targets, `INITIALMW`):

- 10 rows are violated, all `LYA2` `LOWERREG` in consecutive intervals. In each, `TOTALCLEARED`
  sits exactly at `INITIALMW − RAMPDOWNRATE·Δt` yet NEMDE enabled 5-10 MW of `LOWERREG`. This is
  the ramp-rate departure above: NEMDE's energy ramp uses the bid-capped rate, its §6.1 row the
  looser telemetered one. No battery zero-crossing and no AGC-off unit shows a violation. The
  real-data suite asserts that every violation carries this signature.
- Two-sided battery `RAISEREGACTUALAVAILABILITY` at `t = 1`, from §7's formula at the published
  `TOTALCLEARED`: 31/42 match with the §6.1 term (5), 33/42 without it (the earlier bound-only
  proxy matched 20/42). The two mismatches term (5) adds are not yet diagnosed; the ramp-rate
  departure is the likely cause. `LOWERREG` matches 15/42
  with or without term (5); its combined-trapezium mirroring is a rougher approximation.

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
- A `PSY.Storage` device bidding a regulation market on both sides gets two
  `FCASSideCapacityVariable`s per `(device, t)` (`"<service>_gen"`/`"<service>_load"`), each
  bounded above by that side's own scaled `MaxAvail`, each constrained by its own §6.3 joint
  capacity pair against its own trapezium and its own energy term (`Out` for the generation side,
  `-In` for the load side), and priced against its own offer curve. `FCASUnitRegulationTarget`
  (`Reg_gen + Reg_load`, or the single `FCASCapacityVariable` for a one-sided device) is the unit
  total §6.2's cross term and §6.4's ramping cap read. `FCASBDURampingConstraint` bounds that total
  against the device's AGC ramping capability over the model's resolution for both-sided devices,
  skipped where no ramping-capability series is attached or the SCADA ramp rate is zero (§4.2's
  "zero or absent" reading), and applied over the intervals §6.5 Table 3 gives for the modelled
  process. Both directions of a contingency market, or of any market
  on a non-`PSY.Storage` device, still throw.
- The computable subset of §5's enablement pre-conditions gates each `(device, t)`'s capacity
  variable(s) to zero and its constraint rows to a vacuous `0.0 ≤ 1.0` pair; for a both-sides
  regulation bid, each side's own pre-conditions gate that side independently, and when both pass,
  one combined stranded pre-condition gates both sides together. The AGC-status pre-condition gates
  every regulation bid, one- or two-sided.
- `get_fcas_agc_status` (root) reads `"fcas_agc_status"` ([`set_fcas_scaling_inputs!`](@ref)).
- `scale_trapezium` returns an `FCASTrapezium`; `EffectiveTrapezium` and the local
  `lower_slope_coeff`/`upper_slope_coeff` are removed from `AustralianElectricityMarketsSimulations`.
- `FCASJointRampingConstraint` is built in its own `if is_regulation` block over every
  contributing device (single- and both-sided), after the §6.2/§6.4 blocks: net energy
  (`_fcas_net_energy_terms`, unit-level even for a single-sided `PSY.Storage` device, per AEMO's
  unit-level form) plus `FCASUnitRegulationTarget` against `InitialMW` plus or minus the AGC ramp
  capability (`_fcas_agc_ramp_caps`, generalised from the BDU-only `_fcas_bdu_ramp_caps` §6.4 also
  now calls), gated to a vacuous row wherever the ramp capability is zero/absent, `InitialMW` is
  unknown at that interval, or the device isn't enabled for the service at that interval.
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
- §6.1's joint ramping row is built for every contributing device of a regulation service, not
  just a both-sided `PSY.Storage` device; a `System` with no `"fcas_agc_ramp_rate_*"` series
  attached for a device builds a vacuous row there instead, leaving that device's regulation
  capacity bounded only by its trapezium, `MAXAVAIL` and (for a both-sided device) §6.4's ramping
  cap, same as before this row existed.
- `FCASMarket` throws when built for recurrent solves (a `Simulation`), since it reads FCAS data
  and the §5 gate once at build; records duals only for `FCASJointCapacityConstraint` and
  `FCASJointRampingConstraint`, throwing on any other requested type; and throws when a device
  contributes to more than one `FCASService`
  of the same market, since each would carry its own `MaxAvail`-bounded capacity and only one
  regulation target could enter the §6.2 rows. `check_fcas_services` reports the same up front,
  scoped to the available services and devices the template models under `FCASMarket`.
- The daily/profiled-energy §5 pre-conditions are not enforced; a `System` that would fail one of
  those in real dispatch is not caught here.
