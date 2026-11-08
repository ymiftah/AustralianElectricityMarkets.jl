# 0096. Per-step state updates in PowerSimulations

## Status

Accepted. Implements Task 10 of the typed-system rebuild (the ADR number 0095 is reserved for the
typed-system decision).

## Context

A replay model's dispatch limits and fixed loading are read from the unit's state at the start of
each interval: the ramp floor and ceiling about the observed initial MW, and the fixed-loading
target from the bid's `FIXEDLOAD` and the fast-start dispatch mode. The state source
(`ObservedState`, later `SimulatedState`) is therefore a per-step input, alongside the parameters
PowerSimulations already refreshes from time series.

PowerSimulations offers two per-step hooks:

1. Initial-condition updates. `InterProblemChronology` loops over the model's existing initial
   conditions (`src/simulation/initial_condition_update_simulation.jl:2-11`) and
   `update_initial_conditions!` runs after `update_parameters!` whenever the model is updated
   (`src/operation/operation_model_simulation_interface.jl:1-11`). The replay formulations declare
   `PSI.requires_initialization(::NEMReplayDispatch) = false`
   (`AustralianElectricityMarketsSimulations/src/formulations/dispatch.jl:2`), so no initial
   conditions are built and the hook is a no-op. The state is observed data, not a value from a
   previous solution, and the same state feeds bounds and ramp limits as well as the objective, not
   only a variable's starting value.
2. Parameter updates. `update_parameters!` for a `DecisionModel`
   (`src/operation/operation_model_simulation_interface.jl:17-29`) first unsynchronises the
   objective (`src/core/optimization_container.jl:159-167`), then calls
   `update_parameter_values!(model, key, state)` for every parameter key, then rebuilds the
   objective and marks it synchronised. `update_parameter_values!` dispatches to
   `update_container_parameter_values!` (`src/parameters/update_parameters.jl:4-25`).

The update is skipped only on the very first solve of the whole simulation, `step == 1 && ix == 1`
(`src/simulation/simulation.jl:1044`), so that one solve uses whatever the build wrote. Every later
solve runs `update_model!`, including the first step of each later range, and each update rewrites
every step of the current horizon. A horizon starts at `get_current_timestamp(model)`, equal to
`initial_time + execution_count * interval` (`src/operation/operation_model_interface.jl:83`).

Two details of the pinned fork shape the parameter route:

- In a simulation the model is built for recurrent solves, so time-series parameter arrays hold
  `JuMP.VariableRef`, not `Float64` (`src/core/optimization_container.jl:1263-1271`). Every write
  must go through `_set_param_value_at!` (`src/core/parameters.jl:435-443`), which fixes the
  variable; assigning into the `DenseAxisArray` directly fails with
  `MethodError: convert(JuMP.VariableRef, 50.0)`.
- `_apply_cost_targets!` (`src/parameters/cost_parameters.jl:127-137`), which re-adds the energy and
  FCAS offer cost terms, is called only from the `TimeSeriesCostParameter` method of
  `update_container_parameter_values!` (`src/parameters/cost_parameters.jl:139-158`). The update
  loop must therefore cover every parameter key, not only the state-driven ones, or the offer cost
  terms disappear after the first update.

The pinned fork still carries the closed PR #12 machinery: `CostTarget`
(`src/core/parameters.jl:18`), `TimeSeriesCostParameter <: TimeSeriesParameter`
(`src/core/parameters.jl:557`), `add_cost_target!` (`src/parameters/cost_parameters.jl:22`) and
`_apply_cost_targets!` (`src/parameters/cost_parameters.jl:127-137`). AEMSim's energy and FCAS
offers already use it: `EnergyBandPriceParameter` and `FCASBandPriceParameter` subtype
`TimeSeriesCostParameter`, and `energy_offers.jl:204` and `fcas.jl:724` register a cost target per
offer band. The objective-coefficient route deliberately does not: an `ObjectiveFunctionParameter`
carries no per-band cost target, and its terms are re-added by our update method instead.

## Decision

State-driven values are updated through `update_container_parameter_values!` methods on the
parameter types, not through initial conditions, in
`AustralianElectricityMarketsSimulations/src/offers/state_updates.jl`:

- `InitialPowerTimeSeriesParameter` reads `unit_state(ObservedState(), device, stamp).initial_mw`.
- `FixedLoadTimeSeriesParameter` and `FixedLoadInvokedTimeSeriesParameter` recompute the target and
  the invoked flag from the device's energy bids and the dispatch mode at the step, rather than
  reading the derived fixed-load series.
- `stamp = get_current_timestamp(model) + (t - 1) * resolution`, so a multi-step horizon reads each
  of its own steps.

A state-dependent objective coefficient uses a stock `PSI.ObjectiveFunctionParameter` subtype
registered with the stock `add_parameters!`, whose `update_container_parameter_values!` method
writes the coefficient into the container and re-adds the term with
`add_to_objective_variant_expression!(container, coefficient, variable)`. The term is re-added
after `cost_function_unsynch` cleared the variant terms, so the coefficient of each step is
counted once.

Task 10 keeps every precomputed state-dependent series, and `PSI.get_default_time_series_names`
(`src/formulations/dispatch.jl:46-59`) still registers `"observed_initial_mw"` and
`"telemetry_uigf"` because PowerSimulations takes one name per device type. Since the per-step
update reads the initial MW through the device's state source, `_has_nem_dispatch_limits`
(`src/formulations/dispatch.jl:93-123`) no longer requires the initial MW series to carry the
registered name; the UIGF and derived-input names are still checked. A mis-keyed initial MW series
is therefore no longer a build-time error, and the per-step update is the only reader that decides
which series the value comes from. Task 11 removes the precomputed series; the build must then read
the state source for the simulation's first solve. Pre-flight now requires the keyed state series to
exist and the registered `"observed_initial_mw"` series to stay attached. The key's resolution and
alignment against the dispatch interval are not yet validated, and become the only remaining input
check once the build reads the state source.

## Glue required by the stock objective-coefficient route

Measured on the pinned fork (`PowerSimulations` 0.38.5, revision 81c0259, in
`~/.julia/packages/PowerSimulations/9Yq02`).

| Interface | Status | Needed |
| --- | --- | --- |
| `PSI.ObjectiveFunctionParameter` subtype | public | yes |
| `_param_to_vars(::T, ::Formulation)` | private, no generic method | must be defined |
| `PSI.get_multiplier_value(::T, ::Device, ::Formulation)` | public, no generic method | must be defined |
| `_get_time_series_name(::T, device, model)` | default `get_time_series_names(model)[T]` (`src/parameters/add_parameters.jl:574-575`) | the parameter type needs an entry in the `DeviceModel`'s `time_series_names` |
| `calc_additional_axes` | default `()` (`src/parameters/add_parameters.jl:690-699`) | no |
| `_get_expected_time_series_eltype` | default `Float64` (`src/parameters/add_parameters.jl:635`) | no, and the array stays `Float64` in a simulation |
| `set_has_variant_contributors!` | set by container creation (`src/core/optimization_container.jl:1394-1421`) and again by `add_to_objective_variant_expression!` (`src/core/optimization_container.jl:1921-1933`) | no |

Nothing was blocked and PR #12 is not needed. The only private names an AEMSim objective parameter
would extend are `_param_to_vars` and, for writing a parameter array itself, `_set_param_value_at!`.
A custom update method must also mirror the stock resynchronisation
(`set_synchronized_status!(objective, true)`); without it the next `cost_function_unsynch` leaves
the previous step's terms in place and the coefficients accumulate.

Both private names are fork internals to re-check on every fork update. `_param_to_vars` has no
generic method, so a production objective parameter must define its own, and
`_set_param_value_at!` is the only correct write path for a `JuMP.VariableRef` parameter array.

## The toy test

`AustralianElectricityMarketsSimulations/test/state.jl` runs two 5-minute steps:

- ramp base: the state source's series gives the step-2 observed initial MW (10 MW) and the ramp-up
  rate (1 MW/min), putting one unit's ceiling at 15 MW, while the parameter's registered series
  holds a stale 50 MW. Without the state-source update the step-2 base stays 50 MW and the ceiling
  55 MW; the update is the only path to 10 MW, and the step-2 parameter column reading 10.0 is the
  discriminator.
- fixed loading: the derived series is deliberately held at 40 MW for both steps while the bid and
  the dispatch mode say the loading stops at step 2. A unit that still read the series would be
  held at 40 MW in step 2; it solves at 0 MW instead. A second case keeps the loading invoked in
  both steps and checks the parameter column is 40 / base_power with the unit dispatched at 40 MW.
- objective coefficient: a test-only `ObjectiveFunctionParameter` reads 12 then 60 $/MWh from a
  series. Objectives are `(20 + 12) * 100 / 12` and `(20 + 60) * 100 / 12`, and the step-2
  coefficient on active power is `60 * 100 / 12`.
- cross-check: the build's `"fixed_load"` series, written from the same `FIXEDLOAD` rows, is
  compared to `_fixed_load_step` for a unit and for a storage device, so the two implementations of
  the netting and invocation rules cannot drift apart.

All of these pass, together with the group's existing tests.

## Rejected: `rebuild_model = true`

`PSI.Settings(...; rebuild_model = true)` is not a viable alternative for a replay. The model
cannot be built at all: `EnergyBandPriceParameter` (the energy offer price) raises
`EnergyBandPriceParameter does not support models built with rebuild_model = true` from
`add_cost_target!` (`src/parameters/cost_parameters.jl:32`), reached from
`AustralianElectricityMarketsSimulations/src/formulations/energy_offers.jl:204`.

For a measurement, the energy and FCAS offer series were removed from the same two-unit toy, so the
offer-removed rows are a modified toy and only the persistent-with-offers row runs the real one.
The cells are warm timings (the model is built and solved once before the timed steps), one or two
runs per cell, every timing shown, step wall time including the HiGHS solve, single thread:

| Route | Variables | Step 1 | Step 2 |
| --- | --- | --- | --- |
| Persistent model, with offers | 16 | 8.4, 8.7 ms | 0.78, 0.83 ms |
| Persistent model, offers removed | 10 | 6.8 ms | 0.95 ms |
| Rebuilt model, offers removed | 10 | 11.4, 12.5 ms | 5.53, 5.55 ms |

The 10 to 16 variable toy measures fixed overheads, not the cost on a real replay: both routes
include the HiGHS solve (about 0.1 ms here), and the rebuild's cost grows with model size. The
decisive point is not the ratio but that the rebuild route cannot carry the offer cost terms at
all.

## Consequences

- One writer per parameter per step. The build writes the values of the simulation's first solve,
  which PowerSimulations does not update; the update methods write every step of the horizon on
  every later solve.
- The update must stay idempotent: values are overwritten and objective terms are re-added after a
  reset, never accumulated.
- The update loop must keep covering every parameter key, because the offer cost terms are re-added
  only from the `TimeSeriesCostParameter` method.
- A formulation that prices the state in the objective must add the term at build as well as in its
  update method, from the same source at the model's initial time, or the simulation's first solve
  runs without it.
- A value that is not finite throws, naming the parameter, the device and the stamp, as the stock
  time-series update does; a silent NaN would reach the solver as an opaque failure.
