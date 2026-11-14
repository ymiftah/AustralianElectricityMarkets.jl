# 0102. Closed-loop replay through initial conditions and recomputed state inputs

## Status

Accepted. Builds on [0101](0101-aem-writes-aemsim-reads.md), which reserved `NEMClosedLoopDispatchProblem` and
the closed-loop branch of the two state accessors for this milestone.

## Context

An open-loop replay (`NEMDispatchProblem`) starts every dispatch interval from AEMO's observed state, as NEMDE
does: the unit's metered `INITIALMW` from `DISPATCHLOAD` and the MNSP's metered flow. A closed-loop replay
starts each interval after the first from the replay's own previous solve instead, so the replay evolves its
own trajectory. It answers counterfactual questions (what dispatch would follow from a changed offer or a
changed network) that an open-loop replay cannot, because the open loop snaps back to AEMO's state every five
minutes.

The starting output enters the model in two ways:

1. **Directly**, as the base of the unit ramp rows and of the MNSP ramp rows.
2. **Through derived inputs** that AEM writes from the observed state in `nem_system`: a battery's composite
   cross-zero ramp rates (AEMO Dispatch Procedure SO_OP_3705, Appendix C), the invocation of a fixed loading,
   the FCAS enablement and stranding rules (AEMO *FCAS Model in NEMDE* §5) inside each effective offer, and the
   regulation ramping limits `InitialMW ± capability` (§6.1, §6.4).

## Decision

### 1. The problem type is the only switch

`DecisionModel(NEMClosedLoopDispatchProblem, template, sys; ...)` builds the closed-loop model on the same
template and the same System as an open-loop one. The model records `ext["closed_loop"] = true`, which the
formulations read once per build step.

### 2. The raw state is a PowerSimulations initial condition

- `NEMInitialPower` holds each unit's starting output in system-base per-unit, net of charging for a battery.
- `NEMInitialFlow` holds each MNSP's starting flow in MW.

Both are created in the argument stage, seeded with the observed value at the build's initial time, so the
first interval of a closed-loop replay is the open-loop interval. In a closed-loop model they replace the
`InitialPowerTimeSeriesParameter` and the MNSP `initial_flow` operating parameter. The accessors
`_initial_mw_accessor` and `_mnsp_initial_flow_accessor` return the initial condition in place of the
parameter, so the ramp rows are unchanged.

PowerSimulations' `InterProblemChronology` updates them after each solve with methods of
`update_initial_conditions!` that read the simulation's system state: `ActivePowerVariable` (or
`ActivePowerOutVariable - ActivePowerInVariable` for a battery) and the interchange's `FlowActivePowerVariable`.
`requires_initialization` stays `false`, so no initialisation model is built.

### 3. Derived inputs are recomputed with AEM's own writer code

AEM's writers take the state as an optional argument (observed by default), and
`closed_loop_input(device, series_name, t, initial_mw, base)` runs a writer on one interval with the
closed-loop state. `is_state_dependent_input(series_name)` names the series it covers. A root test checks that
`closed_loop_input` with the observed starting output reproduces every series `nem_system` wrote, so no state
rule has a second implementation.

AEMSim's `update_parameter_values!` on `DecisionModel{NEMClosedLoopDispatchProblem}` runs PowerSimulations'
own time-series update, then replaces each state-dependent cell with `closed_loop_input` at the previous
interval's solved output, read from the system state (not from the initial conditions, which PowerSimulations
updates after the parameters). Coefficient and bound targets are re-applied after the overwrite. The update is
read-only on the System.

A parameter column belongs to a time series; if two devices shared one state-dependent series, their
closed-loop values could not differ, and the update throws rather than write one device's value for both.

### 4. What stays observed

- **Fast-start dispatch mode.** Fast-start inflexibility profiles are not modelled, so the dispatch mode in the
  closed-loop state is AEMO's observed mode at the interval.
- **AGC status, UIGF, telemetered limits and every bid.** These are exogenous inputs, not state.
- **The §5 checks run as in dispatch.** AEMO applies the stranded check in dispatch to the telemetered
  `InitialMW`. A closed-loop interval applies it to the previous solved target, as if telemetry followed the
  target; in AEMO's pre-dispatch, where later intervals also start from the model's own target, §5 skips the
  check after the first interval (see [0017](0017-fcas-market-formulation.md)). This is a modelling choice of the
  closed loop, not an AEMO rule.

## Consequences

- A closed-loop replay is a counterfactual tool. Its distance to NEMDE grows with the gap between the solved
  and the metered trajectory, and is not the replay's accuracy measure; the open-loop replay remains the NEMDE
  comparison.
- Each closed-loop step recomputes the state-dependent inputs of every affected device (one interval's window
  per device and series). The per-step cost is higher than the open loop's.
- Departure from [0101](0101-aem-writes-aemsim-reads.md) section 6: a closed-loop model defines per-step
  parameter updates in AEMSim. They are read-only on the System and use AEM's code, as that ADR's milestone 2
  planned.
- Milestone-2 work left: battery state of charge is not modelled (no energy limit carries across intervals),
  and fast-start profiles are not tracked.

## Market correctness

No bound, constraint or cost term changes. The closed loop changes which starting state feeds the existing
rules: the unit and MNSP ramp rows, the composite battery ramp (SO_OP_3705 Appendix C), the fixed-loading
invocation, the FCAS enablement and stranding pre-conditions (*FCAS Model in NEMDE* §5) and the regulation
ramping limits (§6.1, §6.4). The departure from AEMO is the starting state itself (the previous solve rather
than SCADA), section 4.

## Verification

- Toy simulations: a closed-loop step 1 equals the open-loop step 1; a unit whose observed start jumps between
  intervals ramps from its solved output instead (70 MW against 110 MW open loop); step 2's FCAS ramping limits
  equal `closed_loop_input` at the step-1 solve.
- Root test: `closed_loop_input` at the observed state equals the written series for ramp, fixed-load, FCAS
  offer and FCAS ramping series of the mock cache.
