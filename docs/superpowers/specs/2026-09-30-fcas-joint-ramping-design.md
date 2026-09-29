# Phase 2.9: FCAS joint ramping (AEMO *FCAS Model in NEMDE* §6.1)

Status: reviewed 2026-09-30, ready to implement. Plan: `~/.claude/plans/nem-redesign-phase2.md` §2.8/2.9.
Base: `v0.2` at `5825831` (#149, #150, #151, #153 merged).

## Goal

Add §6.1 joint ramping to `FCASMarket`: a unit's energy target combined with its regulation target
must stay within the telemetered AGC ramp from `InitialMW`. It is the only unit FCAS constraint the
model is still missing. ADR 0017 records it as "Not modelled", and it is the main suspect for the
20/42 two-sided-battery mismatch against published `RAISEREGACTUALAVAILABILITY` on the 2026-06-04
real-data run.

Out of scope: elasticity (2.8 adds slack + CVP to these rows), scheduled loads (not modelled, ADR
0017), fast-start inflexibility (Phase 3).

## AEMO source

`nem-expert` references, `fcas-model-in-nemde/`: `06-joint-energy-and-fcas-constraints.md` §6.1
(pp. 21-22), §6.4, §6.5 Table 3 (p. 28); `07-fcas-availability.md` §7; `08-appendix-a-examples.md`
A.2; `02-structure-of-an-fcas-bid.md` §2.4; `data-model/DISPATCHLOAD.md`.

For scheduled and semi-scheduled generators, **scheduled bidirectional units** and WDR:

```text
Energy Dispatch Target + Raise Regulation FCAS Target ≤ Initial MW + SCADA Ramp Up Rate × Time Period
Energy Dispatch Target − Lower Regulation FCAS Target ≥ Initial MW − SCADA Ramp Down Rate × Time Period
```

- Applied "if a unit has an energy bid, is enabled for regulating services, and the AGC ramp up or
  down rate is greater than zero". One row per **unit** (no per-side footnote, unlike §6.3 fn 8;
  §6.4: "the SCADA ramp rate applies to the unit as a whole").
- `Time Period = 5 minutes`. Table 3: every interval in dispatch, first in 5-minute pre-dispatch,
  none in 30-minute pre-dispatch. Footnote 11 (fast-start modes 0-2) is not modelled.
- The scheduled-load form (raise/lower swapped) does not apply: no scheduled load is modelled.
- `INITIALMW` is signed for a BDU, negative when importing (`DISPATCHLOAD.md:45`); `TOTALCLEARED` is
  signed net (`:46`).
- NEMDE's rows carry surplus/deficit terms (§6.1 fn 2); ours are hard until 2.8.

Appendix A.2: `InitialMW = 450`, AGC up 3 MW/min, down 2 MW/min → `JointRampRaiseMax = 465`,
`JointRampLowerMin = 440`.

## nempy cross-check (`spot_market_backend/fcas_constraints.py`, `markets.py:1361`)

- Ramp source: `UnitData.get_scada_ramp_rates` reads `DISPATCHLOAD.RAMPUPRATE`/`RAMPDOWNRATE`
  (MW/h) and `INITIALMW`; RHS `initial_output ± ramp_rate × dispatch_interval / 60`.
- Generators: `energy + raise_reg ≤ RHS_up`, `energy − lower_reg ≥ RHS_down`.
- BDU (`joint_ramping_constraints_*_reg_bdu`, lines 6-43): one row per unit, but
  `variable_mapping_energy` is copied from `variable_mapping_reg`, so energy enters only for the
  dispatch types carrying a regulation bid. A two-sided BDU gets net energy; a **single-sided BDU
  gets its own side's energy**. **Departure from nempy:** we use net energy for every storage
  device, per AEMO's unit-level form (one signed InitialMW, one rate).
- nempy skips NaN rates but builds rows at a zero rate (forcing `energy + reg ≤ InitialMW`).
  **Departure from nempy:** we follow AEMO's "> 0" condition.

## Design

### Constraint type

`FCASJointRampingConstraint <: PSI.ConstraintType` in `…Simulations/src/constraint_formulations.jl`,
exported, with a docstring (the name plan 2.8 uses). Container key
`(FCASJointRampingConstraint, FCASService, meta = <service name>)`, axes `(device names,
time_steps)`, over **all** contributing devices of a regulation service (single- and two-sided).

### Where it is built

In `PSI.construct_service!(…, ::PSI.ModelConstructStage, model::ServiceModel{FCASService, FCASMarket}, …)`,
in its **own** `if is_regulation` block over all devices, after the joint capacity rows. (The §6.4
rows sit inside `if !isempty(both_names)`, so §6.1 cannot share that block.) One row per
`(device, t)` for the service being built:

| Service | Row |
| --- | --- |
| `RAISEREG` | `E[d,t] + FCASUnitRegulationTarget[d,t] ≤ InitialMW[d,t] + RampUp[d,t]` |
| `LOWERREG` | `E[d,t] − FCASUnitRegulationTarget[d,t] ≥ InitialMW[d,t] − RampDown[d,t]` |

- **`E[d,t]`**: `PSI.ActivePowerVariable` for a non-`Storage` device; **net**
  `ActivePowerOutVariable − ActivePowerInVariable` for any `PSY.Storage` device, single- or
  two-sided. New helper `_fcas_net_energy_terms(device)`, refactored out of the contingency branch
  of `_fcas_energy_terms` so both share it. Not `_fcas_energy_terms(device, true, decremental)`
  (the bid side's own energy, correct for the per-side §6.3 rows).
- **`FCASUnitRegulationTarget[d,t]`**: existing expression (capacity variable single-sided,
  `gen + load` two-sided), built for single-sided devices too (`fcas_market.jl` ~584-600).
- **`InitialMW[d,t]`**: `get_initial_mw(device, initial_time, horizon)`, net for a battery,
  system-base per-unit.
- **`RampUp`/`RampDown`**: `get_fcas_agc_ramp_capability(device, BidType.RAISEREG|LOWERREG, …;
  resolution)`, the `"fcas_agc_ramp_rate_*"` series (from `DISPATCHLOAD.RAMPUPRATE`/`RAMPDOWNRATE`,
  per-unit/h) × resolution in hours. Same accessor as §4.2 and §6.4. **Supersedes the plan text**
  naming the 2.12 `"ramp_up_rate"`/`"ramp_down_rate"` parameters: same column and intervention
  filter (`read_dispatch_limits`/`read_fcas_scaling_inputs`), differing only in units (pu/min vs
  pu/h) and bad-data handling (dispatch series throws/warns, FCAS series stores NaN); batteries use
  the plain DISPATCHLOAD rate in both (ADR 0020). One ramp source across §4.2/§6.4/§6.1, and the
  service reads no device-model parameters.
  Generalise `_fcas_bdu_ramp_caps` into `_fcas_agc_ramp_caps(container, devices_template, device,
  bid_type)` (any device); §6.4 calls it.

### Row gating (placeholder `0 ≤ 1` otherwise, as existing rows do)

Build the row at `t` only when all hold:

1. `_fcas_agc_ramp_applies(_fcas_process(…), t)` (Table 3).
2. Ramp capability at `t` present, not NaN, `> 0` (up for `RAISEREG`, down for `LOWERREG`).
3. `InitialMW[t]` present and not NaN.
4. Device enabled for this service at `t`: `_fcas_enabled_mask` single-sided;
   `gen_enabled[t] || load_enabled[t]` from `_fcas_both_sides_enabled_mask` two-sided (unit-level
   enablement; a disabled side's variable is bounded at 0).
5. Energy bid: every `AbstractNEMDispatch` device has one; a device with no energy variable still
   throws in `_add_fcas_variable_terms!`.

Compute per-device vectors over `time_steps` once, not per `t`.

### Pre-flight check

Extend `check_fcas_services` in `…Simulations/src/check/fcas.jl`: report regulation contributors
that carry a positive `"fcas_agc_ramp_rate_*"` series but no `"initial_mw"` series. Build-time skip
(gate 3) stays for per-interval NaN gaps. Rationale: a silent skip drops a hard AEMO constraint, and
`NEMLookaheadDispatch` does not enforce `initial_mw` coverage (`NEMReplayDispatch` does,
`nem_dispatch.jl:330-339`). Follow the existing check's report style.

### Duals

Allow `FCASJointRampingConstraint` in `PSI.get_duals(model)` (allowlist + its error message,
`fcas_market.jl` ~282-285) and register its dual container. No `psi_compat` shim needed.

### Interaction with existing rows

- **Device ramp** (`AbstractNEMDispatch`) bounds `E` alone; §6.1 bites through the regulation
  target. Under `NEMReplayDispatch`, `target = 0` is always feasible: same column, same
  `"initial_mw"`, ceiling already raised to the ramp floor (`dispatch_limits.jl:61-72, 173`). Under
  `NEMLookaheadDispatch` at `t = 1` the device ramp base is the `DevicePower` initial condition
  (`nem_dispatch.jl:342-352`), not `"initial_mw"`; if they differ, §6.1 at `target = 0` can conflict
  with device ramp plus availability. Accept (lookahead is beyond the replay objective), document in
  ADR 0017.
- **§6.4** (two-sided storage): `target ≤ ramp·Δt`; §6.1 is tighter whenever energy moves in the
  service's direction. Both kept.
- **§4.2** caps a generator's plateau at `ramp·Δt`; §6.1 adds the energy-movement term.

## Known departures (ADR 0017, §6.1 subsection)

- Ramp rate: `DISPATCHLOAD.RAMPUPRATE` is "lesser of bid or telemetered rate" (`DISPATCHLOAD.md:47-48`);
  AEMO §6.1 uses the telemetered SCADA rate, which MMSDM does not publish. Our row can be tighter
  than NEMDE's when the bid rate of change is below the telemetered rate. §4.2 and §6.4 share it.
- Hard rows until 2.8 (NEMDE has surplus/deficit terms).
- Table 3 fn 11 fast-start exclusion not modelled.
- `NEMLookaheadDispatch` IC vs `"initial_mw"` (above); ADR 0020's flat battery ramp gap.
- Net energy for single-sided BDUs: departs from nempy, follows AEMO.

## Tests

First: **audit existing `fcas_market` fixtures** that fix energy away from `initial_mw` while an
`fcas_agc_ramp_rate_*` series is attached (e.g. `_build_bdu_regulation`, net `initial_mw = 0`,
`test/fcas_market.jl` ~133-170); adjust any that now bind unintentionally. Run the whole
`fcas_market` group.

`fcas_market` group, toy fixture:

1. **A.2 numbers**: generator, `InitialMW = 450`, up 180 MW/h, down 120 MW/h, 5-min. RHS 465 /
   440 MW (per-unit), coefficients `E` +1, target +1 / −1.
2. **RAISEREG binding**: pin energy at 460 MW with `fix_energy!`; raise target ≤ 5 MW. Assert the
   §4.2 plateau (15) and the trapezium upper slope do not bind at 460, so §6.1 is the binding row.
3. **A.2 end-to-end**: energy 465 → RaiseReg target 0.
4. **LOWERREG binding**: energy pinned at 445 → lower target ≤ 5.
5. **BDU net energy**: two-sided battery row has `Out` +1, `In` −1, `gen` +1, `load` +1
   (RAISEREG), RHS from net `InitialMW`. Binding from charging: `InitialMW = −20`, cap 12 MW,
   so `net + gen + load ≤ −8`.
6. **Single-sided storage**: net energy, not the side's own.
7. **Gating**: placeholder for ramp 0, ramp NaN, not enabled at `t`, `NEMLookaheadDispatch` p5min at
   `t = 2`, predispatch (30-min) at every `t`, and `InitialMW` NaN at one interval (build under
   lookahead or a series gap; replay throws without coverage).
8. **Duals**: requesting `FCASJointRampingConstraint` duals builds and populates the container.
9. **Pre-flight**: the new `check_fcas_services` case reports a regulation contributor with a ramp
   series but no `"initial_mw"`.

Real-data suite (`test/real_data/runtests.jl`, local only):

<!-- markdownlint-disable-next-line MD029 -->
10. **Rewrite the RAISEREG report-only diagnostic** to AEMO §7: availability = max(0, min of terms
    (1)-(5)) at the **published** signed `TOTALCLEARED`, on the **combined** two-sided trapezium for a
    BDU (§2.4 last bullet), with term (4) from published contingency targets and term (5)
    `JointRampRaiseMax − TOTALCLEARED`. Report match rate (was 20/42).
<!-- markdownlint-disable-next-line MD029 -->
11. **§6.1 fidelity check**: evaluate every built §6.1 row at NEMDE's published solution
    (`TOTALCLEARED`, published `RAISEREG`/`LOWERREG` targets) and count violations above a tolerance
    (e.g. 1 MW). Report, and assert the count is small (expect ≈ 0; pick the threshold after seeing the
    number, and record it).
<!-- markdownlint-disable-next-line MD029 -->
12. Assert the model still builds and solves.

## Files

- `…Simulations/src/constraint_formulations.jl`: new type + docstring; `FCASUnitRegulationTarget`
  docstring gains §6.1.
- `…Simulations/src/fcas_market.jl`: `_fcas_net_energy_terms`, `_fcas_agc_ramp_caps`
  (§6.4 uses it), the §6.1 block, duals allowlist + message; `_fcas_agc_ramp_applies` docstring gains §6.1.
- `…Simulations/src/check/fcas.jl`: the pre-flight case.
- `…Simulations/src/AustralianElectricityMarketsSimulations.jl`: export.
- `…Simulations/test/fcas_market.jl`, `test/real_data/runtests.jl`.
- `docs/adr/0017-fcas-market-formulation.md`: rewrite lines ~78-80 (RAISEREG "pinned by §6.1,
  deferred") and ~316-318 ("Not modelled") into the design + departures above.
- `docs/src/roadmap.md` (~line 14): mark §6.1 done.
- `CHANGELOG.md` `[Unreleased]`.

## Resolved questions

1. Ramp source: FCAS `"fcas_agc_ramp_rate_*"` series (see Design).
2. Net energy in §6.1 vs own-side energy in §6.3: the asymmetry matches AEMO (§6.1 unit-level;
   §6.3 fn 8 per side; net in §6.3 would pin a two-sided unit, ADR 0017 ~108-112).
3. Two-sided enablement: `gen || load`.
4. Missing `InitialMW`: per-interval skip at build **and** a pre-flight check.
