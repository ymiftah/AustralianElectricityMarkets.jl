# 0098. Observed state inputs are read from the prepared series

## Status

Accepted. Amends [0096](0096-per-step-state-updates.md): the custom per-step updates it describes now
run only for `SimulatedState`.

## Context

ADR 0096 refreshes 13 state-dependent parameters at every step through custom
`update_container_parameter_values!` methods: the initial power, the ramp-up and ramp-down rates,
the fixed loading and its invoked flag, the five FCAS parameters (offer limit, band width, upper and
lower slopes, ramping limit), and the MNSP initial flow and forward and reverse ramp rates. Each
method recomputed its value from the unit's state at every step of the horizon.

A replay of 10 intervals on 2026-06-04 spent a median 4.71 s per interval in these updates against
2.15 s in the MIP solve. Under `ObservedState`, every value is a function of the interval stamp only,
and `prepare_replay!` already attaches a series holding exactly that value for each parameter
(`initial_mw_seed`, `ramp_up_rate`, `ramp_down_rate`, `fixed_load_seed`, `fixed_load_invoked_seed`,
`fcas_effective_<BIDTYPE>[_decremental]`, `fcas_ramping_limits_<BIDTYPE>`, `initial_flow`,
`link_forward_ramp_rate`, `link_reverse_ramp_rate`). The custom updates were recomputing values the
system already held.

## Decision

- Under `ObservedState` the 13 parameters are refreshed by PowerSimulations' stock update, which reads
  the window of the registered series at each step. The FCAS slopes use the stock
  `ConstraintCoefficientParameter` update, which also rewrites the constraint coefficients. No new
  series is written.
- The custom computation stays for `SimulatedState`, whose state comes from the previous solve. It
  computes each unit's FCAS derivation once per step and shares it across the five FCAS parameters.
- Under `ObservedState` the per-step inputs are fixed by the first `prepare_replay!` call. A later
  change to a unit's observed state is not read, and calling `prepare_replay!` again does not
  refresh the prepared series.
- The contract between the two paths is the `state_update_equivalence` test: under `ObservedState`,
  the stock path and the custom path (forced by a test switch) write the same values within
  `1e-12` for all 13 parameters.

## Consequences

- Updates drop to a window read per parameter; the solve is now the largest part of a step.
- Both paths throw on a non-finite value; the stock message names the series rather than the device and stamp.
- The custom path is exercised only under the test switch until `SimulatedState` is implemented. On
  that path the energy and MNSP helpers still read a unit's `NEMUnitData` several times per step.

## Verification

Recorded on 2026-11-11.

- Results: the 2026-06-04 04:05-06:00 replay (24 intervals) is bit-identical to the same replay
  before the change (maximum difference 0.0 on dispatch, prices, interconnectors and FCAS prices).
- Timing, 10 intervals from 2026-06-04 04:05 with the batch runner (`--start 2026-06-04T04:05:00
  --intervals 10 --time-series-in-memory true`), with the package cache built by the precompile
  workload:

  | Per interval (median) | Before | After |
  | --- | --- | --- |
  | Parameter updates | 4.71 s | 0.24 s |
  | MIP solve | 2.15 s | 2.14 s |
  | Pricing | 0.90 s | 0.98 s |
  | Solve and write, remainder | 0.28 s | 0.29 s |

  Updates over the 10 intervals took 2.7 s instead of 44.0 s, and execution took 41.3 s instead of
  82.0 s. System and model build are unchanged (10.1 s and 20.9 s).
