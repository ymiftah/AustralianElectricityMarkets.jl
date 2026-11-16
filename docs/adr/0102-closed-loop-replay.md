# 0102 Closed-loop replay through initial conditions and recomputed state inputs

## Status

Accepted. Builds on [0101](0101-aem-writes-aemsim-reads.md), which reserved `NEMClosedLoopDispatchProblem` and the closed-loop branch of the state accessors.

## What

- `DecisionModel(NEMClosedLoopDispatchProblem, template, sys; ...)` builds a closed-loop model on the same template and System as an open-loop one; the model records `ext["closed_loop"] = true`. Each interval after the first starts from the replay's own previous solve instead of AEMO's metered state, so it answers counterfactuals; the open-loop replay stays the NEMDE comparison.
- The raw state is a PSI initial condition: `NEMInitialPower` (system-base per-unit, net of charging for a battery) and `NEMInitialFlow` (MW, per MNSP). They replace `InitialPowerTimeSeriesParameter` and the MNSP `initial_flow` parameter, seeded with the observed value at the build's initial time. `requires_initialization` stays `false`.
- Derived inputs that depend on the starting output are recomputed each step: the battery composite cross-zero ramp rates (AEMO Dispatch Procedure SO_OP_3705 Appendix C), fixed-loading invocation and target, FCAS effective offers (enablement and stranding rules, *FCAS Model in NEMDE* s5) and regulation ramping limits `InitialMW +/- capability` (s6.1, s6.4).

## How

- `_initial_mw_accessor` and `_mnsp_initial_flow_accessor` return the initial condition, so the ramp rows are unchanged. PSI's `InterProblemChronology` updates the conditions after each solve from the system state (`ActivePowerVariable`, or `ActivePowerOutVariable - ActivePowerInVariable` for a battery, and the interchange `FlowActivePowerVariable`).
- `closed_loop_input(device, series_name, t, initial_mw, base)` runs AEM's own writer on one interval with the closed-loop state; `is_state_dependent_input(series_name)` names the covered series. A root test checks that it reproduces every series `nem_system` wrote at the observed state.
- AEMSim's `update_parameter_values!` on `DecisionModel{NEMClosedLoopDispatchProblem}` runs PSI's stock update, then overwrites each state-dependent cell with `closed_loop_input` at the previous interval's solved output (read from the system state), then re-applies coefficient and bound targets. It is read-only on the System. The model's first execution keeps the build-time observed series, since the system state is still NaN. It throws if two devices share one state-dependent series and their values differ.
- Ramp rates of non-storage devices stay stock: their ramp rows read the initial condition directly.

## Why

- No state rule has a second implementation: the closed loop calls the code that wrote the observed inputs.

## Market correctness

No bound, constraint or cost term changes; the closed loop changes which starting state feeds the existing rules (unit and MNSP ramp rows, SO_OP_3705 composite battery ramp, fixed-loading invocation, FCAS s5 preconditions, s6.1 and s6.4 ramping limits).

- Departure from AEMO: the starting state is the previous solve rather than SCADA. The s5 stranded check, which AEMO applies to telemetered `InitialMW` in dispatch, is applied to the previous solved target, as if telemetry followed the target.
- Fast-start dispatch mode and time in mode stay AEMO's observed values; AGC status, UIGF, telemetered limits and bids are exogenous.

## Known limits

- Battery state of charge is not carried across intervals, and fast-start mode is not tracked ([0106](0106-fast-start-two-run-dispatch.md)).
- Distance to NEMDE grows with the gap between the solved and metered trajectory, so it is not a replay accuracy measure.
