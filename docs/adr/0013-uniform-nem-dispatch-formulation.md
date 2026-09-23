# 0013. One device formulation for every NEM dispatch participant

## Status

Accepted

## Context

`PowerSimulations.jl` (PSI) dispatches device constraints on the pair *(component type,
formulation)*. AEMSim's templates therefore assigned a different stock formulation per
`PowerSystems.jl` (PSY) type, and each stock formulation carries a US-market assumption NEMDE
does not make:

| PSY type | Stock formulation | Assumption imported |
| --- | --- | --- |
| `ThermalStandard` | `ThermalBasicDispatch` / `ThermalBasicUnitCommitment` | commitment binaries, start/stop costs |
| `RenewableDispatch` | `RenewableFullDispatch` | output is a forecast ceiling, not a bid stack |
| `HydroDispatch` | `HydroDispatchRunOfRiver` | energy budget / run-of-river inflow |

NEMDE makes none of these distinctions. Every scheduled resource is the same object: a ten-band
bid stack, a ramp limit measured from `INITIALMW`, and the `DISPATCHLOAD.AVAILABILITY` envelope.
Technology enters only through the numbers on those three things, never through the form of the
constraints.

An earlier revision of this work scoped the formulation to `ThermalStandard`, `HydroDispatch` and
`RenewableDispatch`. That reintroduced the very assumption the work exists to remove: NEMDE
dispatches on market participation, not on technology, so a participant's PSY type must not
decide the form of its constraints.

## Decision

### Written against `PSY.StaticInjection`, with no device-type gate

Every method is written against `PSY.StaticInjection` and the template decides which types it is
set for. `PSY.get_max_active_power` is generic over `StaticInjection`
(`PowerSystems/src/models/supplemental_accessors.jl:166`), so nothing forced a narrower bound.
A user bringing a `ThermalMultiStart` gets the same treatment; `EnergyReservoirStorage` resolves
every hook rather than `MethodError`ing, and `detect_ambiguities` is clean.

Participation is read from the data, not assumed: `nem_dispatch_participants` returns the types
whose components carry the `"ramp_up_rate"` series.

The scope limit that *is* real is narrower: one injection variable per device. A bidirectional
unit tracking state of charge needs more than that and layers SOC on as its own formulation - an
addition, not an exclusion. NEMDE itself carries no state of charge.

### An abstract supertype, not a type parameter

`PSI.requires_initialization` is called as `requires_initialization(get_formulation(model)())`,
on an *instance*, so the replay/lookahead mode must live in the type; a runtime field would be
invisible to that hook. That argues for two types and no more.

An earlier revision spent five exported names on the one boolean: `NEMDispatch{B <: RampBase}`
over an abstract `RampBase` with `MeteredRampBase`/`ChainedRampBase` singletons, plus two `const`
aliases. This was replaced with an abstract supertype and two concrete subtypes, which is also
the idiom PSI uses throughout (`AbstractThermalFormulation` -> `ThermalBasicDispatch`); PSI has
no parametric formulation anywhere.

The parametric form bought nothing - `where {D <: AbstractNEMDispatch}` captures the mode for
internal dispatch just as well as a type parameter - and cost two things. It forced a second
vocabulary (mechanism names alongside use names) for a single distinction. And it carried a
footgun: bare `NEMDispatch` satisfies `isa Type{<:PSI.AbstractDeviceFormulation}`, so
`set_device_model!` accepted it and the build then died on a bare `MethodError` from
`NEMDispatch()` deep inside `build!` - a late, unattributable failure, the opposite of the
fail-at-build-and-name-the-device policy the rest of the formulation follows.

The two names are chosen for their use, not their mechanism, because picking the wrong one
yields a plausible but wrong answer.

### Which series marks a participant

`nem_dispatch_participants` asks whether a component carries the series
`get_default_time_series_names(D, F)` registers. An earlier revision probed the single name
`"ramp_up_rate"`. Of the four series `set_nem_dispatch_limits!` writes, only three can serve as a
marker at all: `"max_active_power"` is also written by `set_renewable_pv!`/`set_renewable_wind!`/
`set_hydro_limits!` (`src/parser.jl:176`, `:208`), so a renewable carrying a UIGF ceiling but no
`DISPATCHLOAD` row would be falsely elected. Of the remaining three, the two ramp rates are
preferable to `"initial_mw"`, which only `NEMReplayDispatch` registers; between up and down the
choice is arbitrary. Deriving the set from `get_default_time_series_names` removes the choice and
keeps the probe in step with what the formulation actually reads.

### Partial coverage is opt-in, not silent

The probe elects *types*, and PSI hands a device model every component of its type, so a
component the setters skipped reaches the constructor. By default that component fails the build
by name, which is right when it indicates a mistake - a device added after the setters ran, or a
series removed by hand.

It is wrong for the case `set_nem_dispatch_limits!(...; allow_missing_ramp_rates = true)` exists
to serve: there the caller has already been warned and has chosen to proceed with the buildable
subset, and the sim layer would then refuse to build at all. `set_nem_dispatch_models!` therefore
takes `skip_uncovered`, mirroring that flag: it installs PSI's `"filter_function"` device-model
attribute (read by `get_available_components`) to exclude uncovered components, and warns naming
them. Excluding a device is never silent and never the default.

### `INITIALMW` as a time series, not a scalar

NEMDE takes `INITIALMW` from metering at the start of every interval; it is not the previous
interval's target. A scalar rewritten per interval would make the formulation structurally
single-interval, and a replay loop that forgot to advance it would still solve, quietly wrong.

### Parameters read by UUID

A PSI time-series parameter array is keyed by time-series UUID, not device name. Values are read
through `get_parameter_column_refs(param_container, name)[t] * multiplier[name, t]`, matching
`PowerSimulations/src/devices_models/devices/electric_loads.jl:126`. Indexing the raw array by
device name compiles and then `KeyError`s at build.

The `"max_active_power"` series is normalised by the device's static rating, so its parameter
carries that rating as its multiplier. The three dispatch-limit series are stored as absolute
system-base per-unit, so theirs is `1.0`.

### Failing at build rather than at the solver

The root package's setters throw when `DISPATCHLOAD` has no usable value, so a device missing a
series at this point means the setter was never run for it. Every such device is named up front,
before the constraint loop, rather than letting the parameter lookup fail mid-loop on an internal
key.

A ramp-down floor above the availability ceiling is infeasible. With rates, `INITIALMW` and
`AVAILABILITY` all taken from the same `DISPATCHLOAD` row this cannot arise, so it signals
inconsistent inputs and is reported at build rather than surfacing as a solver `INFEASIBLE` with
no cause. The check applies only to the replay mode: the lookahead floor is the previous
interval's dispatch, which is a variable.

### The market-bid hooks in `psi_compat.jl`

The formulation builds the market-bid path with no `OnVariable`, which is what PSI 0.38.4's
`_include_min_gen_power_in_constraint` / `_include_constant_min_gen_power_in_constraint`
(`devices/common/objective_function/market_bid.jl`) exist for. PSI defines no
`(::Any, ::ActivePowerVariable, ...)` fallback - only `Generator` and `RenewableDispatch` - so a
non-`Generator` participant would `MethodError`. PSI's competing methods are keyed on the device
type with a bare `AbstractDeviceFormulation`, so a single `PSY.StaticInjection` method would be
ambiguous for a `PSY.Generator`; two narrower methods break that tie without narrowing the
formulation itself.

## Consequences

- A `System` must have had `set_nem_dispatch_limits!` run over the model's date range before a
  template can be built, or every participant fails the coverage check by name.
- `set_market_bids!` writes a `Deterministic` while the dispatch-limit setters write
  `SingleTimeSeries`. A consumer must transform with a horizon and interval that produce the same
  single forecast window the bid series already has, or `DecisionModel` rejects the mixed
  intervals.
- The model builds as a pure LP: zero binary and zero integer variables, and no `OnVariable`
  container.
- The market-bid hooks are private PSI API. They are version-pinned in `psi_compat.jl` and must
  be re-checked on every PSI upgrade.
- Fast-start inflexibility profiles (`DISPATCHMODE=2`, T1-T4), FCAS co-optimisation, and MLF are
  not covered. The formulation only guarantees the `ActivePowerRangeExpression` LB/UB terms that
  FCAS co-optimisation will need exist whenever a service model is attached.
