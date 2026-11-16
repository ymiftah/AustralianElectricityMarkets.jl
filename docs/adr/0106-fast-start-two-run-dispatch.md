# 0106. Fast-start units dispatched in two runs, as nempy implements NEMDE

## Status

Accepted. Replaces the earlier fixed-loading-only treatment of fast-start units: the inflexibility profile and the
commitment of fast-start units are modelled here.

## Context

The nempy benchmark (837 intervals of 2024 H2) puts 93% of the absolute energy price error in the 12% of intervals
where a fast-start unit is on its inflexibility profile and the replay dispatches it differently from NEMDE. Three
outliers were checked by fixing those units to AEMO's targets, and the published prices came back to the cent:

| Interval | Units NEMDE held on the profile | Price gap before |
| --- | --- | --- |
| 2024-12-09 14:55 | ROMA_7/8, MSTUART3, URANQ14 (mode 1, 0 MW); CG2/3, BRAEMAR3 (mode 2) | QLD -100 |
| 2024-12-13 07:35 | PUMP2 (mode 0 to 1, 0 MW, the replay dispatched 245 MW) | QLD +68 |
| 2024-12-15 16:30 | URANQ12/13/14 (mode 0 to 1, 0 MW, the replay dispatched 165 MW) | NSW +65, VIC -55 |

Solver tolerances were ruled out in all three. The gap is that the profile was not modelled and the replay read
`DISPATCHMODE` as a pre-solve input.

AEMO's *Fast Start Inflexibility Profile* (FSIP, June 2021) defines the profile of a unit with offered times `T1`
to `T4` and minimum loading `M` (`BIDDAYOFFER_D.MINIMUMLOAD`): mode 0 offline, mode 1 synchronising at 0 MW for
`T1`, mode 2 a linear rise to `M` over `T2`, mode 3 at least `M` for `T3`, mode 4 a linear decline from `M` over
`T4` as a lower bound (FSIP sections 2 and 3, pp. 5 to 8; section 5, pp. 10 to 11). NEMDE commits a unit from a
first solve without the profile and prices the dispatch of a second solve with it. The full NEMDE formulation is
restricted; nempy reproduces NEMDE's published prices with the two-run method below, so nempy is the oracle for
the rules.

## Decision

### 1. Two runs per interval, no MIP commitment

**Run 1 (commitment run).** The full dispatch without profile rows. A fast-start unit starting the interval in
mode 0, 1 or 2 has no energy ramp rows, and the regulation joint-ramping exemption applies (*FCAS Model in NEMDE*
Table 3 footnote, already modelled by `fcas_joint_ramping_exempt`).

**Commitment and end state** (nempy `historical_inputs/units.py::_update_modes`), from run 1's energy target:

- a unit starting in mode 0 with a run-1 target strictly above 0.0 MW enters mode 1 with 0 minutes in mode;
- the unit then advances through modes 1, 2 and 3 once each, in that order, by the 5 minutes of the interval. It
  leaves mode `k` when `T_k - time_in_mode < time_left` (strict, so a unit exactly at a segment end stays),
  carrying `time_left - (T_k - time_in_mode)` into mode `k + 1` with 0 minutes in it;
- `time_in_end_mode` is the time in the last mode plus the time left; it is 0 in end mode 0 and capped at `T4` in
  end mode 4. A unit never leaves mode 4 for mode 0;
- a unit that leaves mode 2 during the interval carries `time_since_end_of_mode_two`, the time left at that
  transition. It keeps it if it also leaves mode 3.

A zero-length segment is crossed at once, because `0 - 0 < time_left` whenever time is left. A unit therefore
never ends in mode 2 with `T2 = 0`. The kernel still guards the division in the mode 2 and mode 4 rows: with
`T2 = 0` the mode 2 target is `M`, and with `T4 = 0` the mode 4 bound is 0 (the decline is over).

**Run 2 (dispatch run).** The same dispatch with profile rows by end mode, elastic at the fast-start CVP, as
nempy builds them (`spot_market_backend/unit_constraints.py::fast_start_mode_*` and
`create_fast_start_profile_constraints`):

| End mode | Row |
| --- | --- |
| 0 or 1 | target <= 0 |
| 2 | target = `M x time_in_end_mode / T2` |
| 3 | target >= `M` |
| 4 | target >= `M x (1 - time_in_end_mode / T4)` |

nempy's `fast_start_mode_four_constraints` computes a target as both `min` and `max`, but
`create_fast_start_profile_constraints` builds only the `>=` row from it (its doctest prints one `>=` row for the
mode 4 unit), which matches FSIP's lower bound. The rule is the built row.

Ramp rows in run 2 (nempy `spot_market_backend/ramp_rate_processing.py`, `_remove_fast_start_units_ending_in_mode_0_1_2`
and `_adjust_ramp_rates_of_units_ending_in_mode_three_and_four`): none for a unit ending in mode 0, 1 or 2. A unit
with a `time_since_end_of_mode_two` has the up row `target <= M + rate x time_since_end_of_mode_two` and its usual
down row; `rate` is the effective ramp-up rate, the lesser of the bid and SCADA rate, per minute (nempy applies the
SCADA minimum before the fast-start adjustment). Every other unit keeps its usual rows about its initial MW.
Prices are run 2's duals.

The fast-start CVP factor is 1130: AEMO *Schedule of Constraint Violation Penalty Factors* v8.0, Table 1 item 10.
nempy reads NEMDE's `FastStartPrice`, 19,775,000 in its 2024-07-10 doctest, which is 1130 times the 17,500
`VoLL` of the same case file.

### 2. Inputs from the MMS tables

nempy reads the starting mode and time in mode from NEMDE's case files (`CurrentMode`, `CurrentModeTime`). From the
MMS tables they are the previous interval's `DISPATCHLOAD.DISPATCHMODE` and `min(DISPATCHMODETIME, T_mode)`, with
time 0 in mode 0. This reproduced `CurrentMode` and `CurrentModeTime` on 21,283 of the 21,287 fast-start rows of
2024-12-13 (all 74 fast-start units, 288 case files). The others are NEMDE's own pre-processing resets (a unit in
mode 4 or 1 returned to mode 0), which nempy does not model either.

The fast-start set is the units with a fast-start profile in their energy offer (NEMDE's `FastStart="1"`): an
energy bid whose `T1` to `T4` has a positive value at the interval. The profile and `M` are read from the bid of
the interval.

NEMDE reads `T1` to `T4`, `MinLoadingMW` and the `FastStart` flag from the energy offer version in force at the
interval, and intraday rebids change them. `BIDDAYOFFER_D` holds one row per trading day, so those rebids are lost
there. `BIDPEROFFER_D.LASTCHANGED` equals NEMDE's `Offer_EffectiveDate`, and MMSDM `BIDDAYOFFER` holds every
version with its `OFFERDATE`. Joining the two on `(DUID, SETTLEMENTDATE, BIDTYPE = 'ENERGY', DIRECTION)` and
`OFFERDATE = LASTCHANGED` reproduced NEMDE's flag, `T1` to `T4` and `MinLoadingMW` on all 63,878 fast-start rows
of 2024-12-09, 2024-12-13 and 2024-12-15, with no mismatch. So:

- the cache holds `BIDDAYOFFER` (every version, `ENERGY` rows only, a `row_filter` at populate time: about 0.7
  million rows and 3 MB a month in 2024 H2, 1.3 million and 5.5 MB in 2026-06);
- `read_offers` takes `MINIMUMLOAD` and `T1` to `T4` of each energy row from the latest version with
  `OFFERDATE <= LASTCHANGED` (an `ASOF` join, so the exact match when it exists), keeps `BIDDAYOFFER_D` where no
  version matches, and keeps the price bands from `BIDDAYOFFER_D`;
- `BIDDAYOFFER` is a required table of `NEMDEConfiguration`, so a replay never silently runs on the per-day
  values. `read_offers` still falls back to `BIDDAYOFFER_D` when it is not cached, for regional systems and
  `set_market_bids!`, which do not require it;
- a unit is fast-start per interval: `has_fast_start_profile` holds when the profile is fast-start at some
  interval, and the per-interval flag (`NEM_FAST_START_SERIES.flag`, the `fast_start` field of
  `fast_start_unit_inputs`) is false where the version in force has a zero profile. Run 2 then relaxes the unit's
  profile rows and keeps its standard ramp rows there; the time-in-mode cap and the FCAS joint-ramping exemption
  read the same per-interval profile.

AEM reads `DISPATCHMODETIME` with the unit conditions and holds the previous interval's value in the observed
state. The derived state (starting mode, capped time in mode) is written per interval by the replay input stage,
and the kernel (`fast_start_end_state`, `fast_start_envelope`) is a pure function of it, run 1's target and the
profile. The envelope depends on run 1's solve, so it is not precomputed.

### 3. PowerSimulations mapping

Two `DecisionModel`s per interval in one `SimulationSequence`, with equal horizon and interval so both run at the
same timestamp in order `[1, 2]`. Run 1 uses the replay template with the fast-start units' starting-mode ramp
exemption and writes its `ActivePowerVariable` to the simulation state. Run 2 reads it through a
`FixValueFeedforward` into a commitment-target parameter. Run 2's parameter update turns that target and the unit's
starting state into the envelope by calling AEM's kernel, so no rule is implemented twice and the System is only
read, as the closed-loop update does ([0102](0102-closed-loop-replay.md)). Results, gates and checks read run 2.
PSI's thermal unit-commitment formulations and `SemiContinuousFeedforward` are not used.

As built (`nem_dispatch_sequence`, AEMSim `formulations/fast_start.jl`):

- **One template, a model-level switch.** Both runs build the same template; `DecisionModel{M}(...;
  fast_start_run = :commitment | :dispatch)` records the run in the model's `"fast_start_run"` setting, read once per
  build as `"closed_loop"` is. New device formulations would have doubled every `AbstractNEMDispatch` method and
  the template for a difference of a few rows.
- **Rows reset per step, not rebuilt.** A simulation builds each model once, and the starting mode, the run-1
  target and so the envelope change every step. The fast-start units keep their standard ramp rows; each step sets
  their right-hand sides to the built value or relaxes them, and sets the dispatch run's `fast_start|lower`,
  `fast_start|upper` and `fast_start|ramp_up` rows. The per-step hook is the update of a
  `FastStartModeTimeSeriesParameter` (the starting-mode series of the fast-start units), added in both runs. A
  relaxed row takes `FCAS_INACTIVE_LIMIT_MW`, not `Inf`: PSI's model export cannot write `Inf`.
- **Feedforward.** Run 2's `FixValueFeedforward` from run 1's `ActivePowerVariable` has the tag
  `FastStartCommitmentTargetParameter` as its affected value (PSI refuses an empty list). The `FixValueParameter`
  it adds carries the targets and fixes nothing: AEMSim overrides its update (PSI's asserts a fixed variable) and
  `add_feedforward_constraints!` for the tag. A standalone run-2 model without the feedforward reads targets of 0.
- **Batteries** are left out of the fast-start rows; a battery offer with a profile keeps its usual rows.

### 4. Closed loop

A closed-loop replay keeps AEMO's observed starting mode and time in mode, as [0102](0102-closed-loop-replay.md)
does for the mode. The next interval's starting state is the previous interval's end state, so
`fast_start_end_state` of run 2's target is the value a closed loop would carry; carrying it is follow-up work.

### 5. Fixed loadings

`read_fixed_loads` flags `IN_PROFILE` from `DISPATCHMODE` at the interval, while the fixed-loading series
`nem_system` writes drop a loading from the starting mode (the previous interval's mode). The flag feeds only
`_set_nem_fixed_loads!`, which is dead in production ([0096](0096-per-step-state-updates.md)), so the two do not
meet in a replay. The starting mode is the pre-solve input, which is what NEMDE has before its first run. With the
profile in run 2 at CVP 1130 above the fixed loading's 380 (Energy Inflexible Offer, Table 1 item 13), the
profile governs a unit on it, and dropping the fixed loading in modes 1 and 2 can be revisited when run 2 lands.

## Known departures from NEMDE, kept from nempy

- **Pre-processing resets.** NEMDE returns some units in mode 4 or 1 to mode 0 before its first run (5 of the
  21,287 rows of 2024-12-13). nempy does not model them and neither does the replay.
- **Ramp base of a unit leaving the profile.** BRAEMAR2 at 2024-12-09 14:55 started in mode 3 and was dispatched
  at 143 MW, its previous target 88 MW plus its 55 MW ramp, with a metered 67.5 MW. NEMDE appears to ramp such a
  unit from its previous target; nempy ramps from the initial MW, and so does the replay.
- **Commitment threshold.** A unit is committed on any run-1 target above 0.0 MW, as nempy does. An earlier draft
  used 0.005 MW; nempy has no threshold.

## Departure from nempy

- **Regulation joint ramping in run 2.** nempy's `set_joint_ramping_constraints_reg` with
  `run_type="fast_start_second_run"` drops the rows of units ending in mode 0, 1 or 2 and gives a unit that left
  mode 2 the raise row `target + raise_reg <= M + rate x time_since_end_of_mode_two`. The replay keeps the
  starting-mode exemption of run 1 (`fcas_joint_ramping_exempt`, precomputed in the regulation ramping limits) in
  both runs. They differ only for a unit starting in mode 0, 1 or 2 and ending in mode 3 or 4 that offers
  regulation in that interval. Follow-up work.

## Verification (2026-11-15, benchmark mode)

| Interval | Published ROP | Replay before | Both runs, per-day offer | Both runs, offer version in force |
| --- | --- | --- | --- | --- |
| 2024-12-13 07:35 | QLD 77.73, NSW 74.74 | QLD +68 | to the cent in every region | to the cent in every region |
| 2024-12-15 16:30 | QLD 214.48, NSW 223.34 | NSW +65, VIC -55 | QLD +11.27, NSW +11.74, others to the cent | to the cent in every region |
| 2024-12-09 14:55 | QLD 200.00, NSW 171.45 | QLD -100 | QLD -46.17, NSW -41.12, VIC/SA -0.6 | to the cent except SA +1.16 |

The two residuals of the per-day offer were inputs, not rules: the offer versions in force explain both.

- 2024-12-15 16:30: W/HOE#1 started in mode 0, run 1 dispatched it at 205 MW and run 2 held it at its mode-2
  target of 20 MW, while NEMDE published 26.31 MW in `DISPATCHMODE` 0. Its rebid at 16:04 set `T1` to `T4` and
  `MINIMUMLOAD` to 0, so NEMDE did not treat it as fast-start at 16:30. The per-day `BIDDAYOFFER_D` row kept a
  non-zero profile.
- 2024-12-09 14:55: CG2 and CG3 had been rebid to `T1 = 14` and URANQ14 to `T1 = 21`, against the per-day `T1 = 10`
  and `T1 = 6`, so they stay in mode 1 as NEMDE has them. BRAEMAR2 (143 MW) and BRAEMAR3 (33 MW) match, so the
  BRAEMAR2 ramp-base departure above is explained by the ramp from minimum loading: 110 MW plus 11 MW/min over
  the 3 minutes since mode 2.
- The SA gap at 2024-12-09 14:55 (solved -42.50, published -43.66) was there before the fast-start work and is
  unrelated to it.

## Consequences

- Two builds and solves per interval, roughly twice the runtime.
- `NEMObservedState` gains `dispatch_mode_time` and `NEMUnitState` gains `time_in_mode`; both default to 0, so
  existing constructors keep working.
- Fixed loadings of fast-start units are dropped in modes 1 and 2 (section 5) until run 2's profile rows govern them.

## Sources

- nempy: `historical_inputs/units.py` (`UnitData._update_modes`, `get_fast_start_profiles_for_dispatch`),
  `spot_market_backend/unit_constraints.py` (`fast_start_mode_one_constraints` to
  `fast_start_mode_four_constraints`, `create_fast_start_profile_constraints`),
  `spot_market_backend/ramp_rate_processing.py` (`_adjust_ramp_rates_for_fast_start_profiles` and its helpers),
  `markets.py` (`SpotMarket.set_fast_start_constraints` doctest, `set_unit_ramp_rate_constraints`),
  `benchmarking/bidirectional_units.py` (the two-run sequence), `historical_inputs/xml_cache.py`
  (`get_unit_fast_start_parameters`, `get_constraint_violation_prices`).
- AEMO, [Fast Start Inflexibility Profile, June 2021](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/dispatch/policy_and_process/fast-start-unit-inflexibility-profile.pdf),
  sections 2 and 3 (pp. 5 to 8) and section 5 (pp. 10 to 11).
- AEMO, [Schedule of Constraint Violation Penalty Factors v8.0](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/congestion-information/2025/schedule-of-constraint-violation-penalty-factors.pdf),
  Table 1 items 3 (unit ramp rate, 1155), 10 (fast-start profile, 1130) and 13 (energy inflexible offer, 380).
- AEMO, [FCAS Model in NEMDE v3.0](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/dispatch/policy_and_process/fcas-model-in-nemde.pdf),
  section 6.5 Table 3 footnote (joint ramping exemption of fast-start units in modes 0 to 2).
- AEMO, Electricity Data Model v5.7.0: `DISPATCHLOAD.DISPATCHMODE` and `DISPATCHMODETIME`, `BIDDAYOFFER_D.T1` to
  `T4` and `MINIMUMLOAD`, `BIDDAYOFFER.OFFERDATE` (every offer version) and `BIDPEROFFER_D.LASTCHANGED`.
