# 0106 Fast-start units dispatched in two runs, as nempy implements NEMDE

## Status

Accepted. Extends [0034](0034-mms-tables-for-mnsp-and-fast-start.md); closed-loop interplay in [0102](0102-closed-loop-problem.md).

## What

AEMO *Fast Start Inflexibility Profile* (June 2021, s2 to 3, s5): offered times `T1` to `T4` and minimum loading `M`; mode 0 offline, 1 at 0 MW for `T1`, 2 linear rise to `M` over `T2`, 3 at least `M` for `T3`, 4 linear decline from `M` over `T4` as a lower bound. NEMDE commits from a solve without the profile and prices a second solve with it; nempy reproduces this and is the oracle.

- Run 1 (commitment): full dispatch with no energy ramp rows for a fast-start unit starting in mode 0, 1 or 2, plus the regulation joint-ramping exemption (*FCAS Model in NEMDE* s6.5 Table 3 footnote, `fcas_joint_ramping_exempt`).
- `fast_start_end_state`: a unit starting in mode 0 with a run-1 target above 0.0 MW enters mode 1; it advances through modes 1 to 3 once each over the 5 minutes, leaving mode `k` when `T_k - time_in_mode < time_left` (strict); mode 4 is never left; a unit leaving mode 2 carries `time_since_end_of_mode_two`.
- Run 2 (dispatch), `fast_start_envelope`: rows by end mode, elastic at CVP factor 1130 (*Schedule of Constraint Violation Penalty Factors* v8.0, Table 1 item 10): mode 0 or 1 target <= 0; mode 2 target = `M t / T2`; mode 3 target >= `M`; mode 4 target >= `M (1 - t / T4)`, a `>=` row only. Prices are run 2's duals.
- Run 2 ramp rows: none for end mode 0 to 2; a unit with `time_since_end_of_mode_two` gets `target <= M + rate x time_since_end_of_mode_two` (rate the lesser of bid and SCADA, per minute) and its usual down row; others keep their usual rows about initial MW.

## How

- Starting mode and time in mode are the previous interval's `DISPATCHMODE` and `min(DISPATCHMODETIME, T_mode)`; fast-start is decided per interval from a positive `T1` to `T4`.
- Profile and `M` come from the offer version in force: `read_offers` takes the latest `BIDDAYOFFER.OFFERDATE <= BIDPEROFFER_D.LASTCHANGED` (`ASOF` join), falling back to `BIDDAYOFFER_D` when `BIDDAYOFFER` is not cached. `BIDDAYOFFER` is a required table of `NEMDEConfiguration`.
- `nem_dispatch_sequence` builds two `DecisionModel`s per interval (`fast_start_run = :commitment | :dispatch`) when an available non-battery fast-start unit exists. Run 2 reads run 1's `ActivePowerVariable` through a `FixValueFeedforward` into `FastStartCommitmentTargetParameter`; it throws if the feedforward is missing (`ext["fast_start_feedforward"]`).
- Fast-start units keep standard ramp rows; each step `FastStartModeTimeSeriesParameter` resets their right-hand sides and the run-2 `fast_start|lower`, `|upper` and `|ramp_up` rows via AEM's kernels. Batteries are excluded.

## Why

- Unmodelled profiles made the run dispatch such units differently from NEMDE; per-day `BIDDAYOFFER_D` also loses intraday rebids of the profile.

## Known departures

- From NEMDE, kept from nempy: pre-processing resets of units in mode 4 or 1 to mode 0 are not modelled; a unit leaving the profile ramps from its initial MW (NEMDE appears to use its previous target); commitment uses any run-1 target above 0.0 MW.
- From nempy: run 2 keeps run 1's starting-mode regulation joint-ramping exemption; nempy's second run drops those rows only for units ending in mode 0 to 2 and bounds a unit that left mode 2. They differ for units starting in mode 0 to 2, ending in mode 3 or 4 and offering regulation.

## Known limits

- A closed loop keeps AEMO's observed starting mode; it does not carry run 2's end state forward.
- Run fixed loadings are dropped by the starting mode (modes 1 and 2); the profile at CVP 1130 governs. `_set_nem_fixed_loads!` and `read_fixed_loads`' `IN_PROFILE` flag are not on the NEMDE path.
