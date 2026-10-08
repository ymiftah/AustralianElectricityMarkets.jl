# Dispatch comparison: NEMDE, nempy and AEMSim

Living summary of how closely the replication model (AEMSim: `AustralianElectricityMarketsSimulations`)
reproduces AEMO's published dispatch (NEMDE), with stock nempy as the reference implementation.
Updated after each integration rerun. Latest update: 2026-10-08 (gate round 4, Float64 cache).

## Method

- **Sample:** 10 intervals from June 2026 (stratified, seed 1, `scripts/validation_sample_2026-06.csv`)
  plus the baseline interval 2026-06-04 00:00. One interval per stratum, so thin: read distributions,
  not single rows. The intervention stratum is empty.
- **NEMDE (oracle):** published `DISPATCHPRICE`, `DISPATCHLOAD`, `DISPATCHINTERCONNECTORRES`,
  `DISPATCHCONSTRAINT` from the MMSDM cache.
- **nempy (reference):** stock nempy v3.0.3 (commit 2d3cef0) run on AEMO's own NEMDE XML case files
  (`out_xml/`). An earlier MMS-table stand-in loader (`out/`) is superseded; fast start was the one
  approximation that mattered (about 1.0 on the ROP gap).
- **AEMSim:** `replicate_interval` per interval (two-interval window, independent replay seeded from
  published `INITIALMW`), HiGHS with `mip_rel_gap = 0`.
- **Metric:** absolute gap to the published value. ROP is the regional price at the reference node.
  "Non-TAS1" excludes Tasmania because neither nempy nor (until G9) AEMSim models Basslink offers.
- **Reproduce:** `AustralianElectricityMarketsSimulations/scripts/compare_dispatch.jl` runs all three
  sources and writes `comparison_long.csv` and `summary.md` with the metrics below. From the repository
  root, with `NEMPY_PYTHON` and `NEMPY_SRC` set as in `scripts/nempy/README.md` (without them the
  nempy column is left empty):

  ```bash
  # 100 random intervals drawn from 10 random market days of June 2026 (about 1.7 GB of NEMDE zips)
  julia --project=AustralianElectricityMarketsSimulations/test \
      AustralianElectricityMarketsSimulations/scripts/compare_dispatch.jl \
      --n 100 --seed 1 --days 10 --from 2026-06-01 --to 2026-06-30 --out DIR

  # every interval of 3 market days (about 288 x 3 intervals at about 1 minute each)
  julia --project=AustralianElectricityMarketsSimulations/test \
      AustralianElectricityMarketsSimulations/scripts/compare_dispatch.jl \
      --range 2026-06-01:2026-06-03 --out DIR
  ```

  `--dry-run` prints the selection, the download estimate and the commands; the same `--out` resumes.
- **Locations (Store disk):** `/run/media/simba/Store/aem_validation/` : `run10/` (baseline),
  `run10_gate1/`, `run10_gate2/`, `nempy/out_xml/`.

## Headline

| Metric (10 sample intervals) | Baseline | Gate 1 | Gate 2 | Gate 3 | Gate 4 | Stock nempy |
| Gate 4 | Float64 cache (#179), 1-second FCAS (#178), zero-flow constraints (#177), NEMDE's own loss demand (#165), loss factors on bids (#170), tie-break (#172), elastic rows (#173), harness (#163) | Beats stock nempy on every table. 1-second FCAS pulls TAS1 ROP onto published (06-13 from -84.2 to +0.9); V-S-MNSP1 is 0 on 06-09/10/12/13 and the V-SA +81 is gone; loss mean 1.51; dispatch within 1 MW 99.1%. Tie-break regressed numerically and Basslink flow now undershoots (below) |
| --- | --- | --- | --- | --- | --- | --- |
| Intervals solved | 8 of 10 | 10 | 10 | 10 | 10 | 10 |
| Regional ROP, mean / median gap ($/MWh) | 22.7 / 3.3 | 24.1 / 4.9 | 12.9 / 0.67 | 3.92 / 0.02 | **1.87 / 0.00** | 11.2 / 0.36 |
| Non-TAS1 ROP, mean gap | 19.8 | 18.6 | 3.31 | 1.20 | **0.67** | 2.90 |
| TAS1 ROP, mean gap | 34.2 | 46.1 | 51.0 | 14.8 | **6.7** | 44.5 |
| ROP rows within $1 (of 50) | 10 (of 40) | 12 | 27 | 36 | **37** | 28 |
| FCAS ROP, mean gap (10 services incl. 1-second from gate 4) | 133.6 | 107.8 | 108.1 | 0.39 | **0.28** | 0.68 |
| FCAS ROP excluding TAS1, max gap | 2.43 | 4.1 | 0.35 | 0.27 | **0.07** | 1.0 |
| Interconnector flow, mean / median / max (MW) | 81.4 / 30.7 / 687 | 104.6 / 49.3 / 739 | 29.2 / 8.7 / 254 | 19.6 / 0.14 / 160 | **8.8 / 0.0 / 116** | 20.1 / 0.06 / 242 |
| Flow rows within 5 MW (of 60) | 13 (of 48) | 13 | 24 | 35 | **46** | 36 |
| Interconnector loss, mean / max (MW) | 39.0 / 873 | 10.0 / 165 | 3.15 / 28.3 | 2.68 / 28.3 | **1.51 / 28.3** | 2.25 / 22.0 |
| Dispatch rows off by more than 1 MW | 169 | 216 | 104 | 66 | **51** | 89 |
| Dispatch sum of gaps (MW) | 7464 | 9527 | 2765 | 1477 | **1038** | 3384 |
| Dispatch within 1 MW, all published rows | 96.1% | 96.0% | 98.2% | 98.8% | **99.1%** | 98.4% |
| Dispatch missing share | 22.5% | 22.5% | 16.5% | 6.1% | 6.1% | 10.7% |
| Skipped generic constraints per interval | 178 to 207 | 178 to 207 | 53 to 65 | 42 to 54 | 42 to 54 | n/a |

Gate 4 uses the Float64 cache (all tables re-populated; PR #179), so its figures are not comparable to the earlier columns to the last digits.

Baseline interval 2026-06-04 at gate 4: TAS1 ROP gap +3.2 (was -46.9); T-V-MNSP1 flow -190.3 vs published -312.7 (+122.4, was -118.8); loss mean 1.24.

ROP (-46.9) and T-V-MNSP1 flow (-118.8), both identical in nempy.

## What each round changed

| Round | Merged / included | Effect |
| --- | --- | --- |
| Baseline | Phase 2 (#160 to #162), harness #163 | 8 of 10 solve; losses blow up (NSW1-QLD1 875 vs 1.5 MW) |
| Gate 1 | G0, G1/G2, G3, G7, G10a (HUMENSW ramp row elastic) | 10 of 10 solve; losses fixed; prices and flows not better |
| Gate 2 | G4/G5 loads and partial constraints, G6 loss factors on bids, G10b, G13 tie-break, MMS tables | Non-TAS1 ROP 18.6 to 3.31, flow 164 to 22, DUNDWF1/2/3 match 84/23/61 exactly |
| Gate 3 | G9 Basslink offers (#175), G8 loads offering FCAS (#176), #168 WDR constraint fix, G13 all-pairs tie-break | AEMSim now beats stock nempy on ROP, FCAS and dispatch; flows match nempy; TAS1 FCAS spikes gone (06-21 RAISE6SEC +19755 to -1.4); T-V-MNSP1 flows off by more than 5 MW in 3 intervals (was 9); `unknown_duid` skips 121 to 0 |

## Per-source status of the remaining differences (after gate 4)

| Source | Evidence | AEMSim vs nempy | Status |
| --- | --- | --- | --- |
| Tie-break lost numerically | DUNDWF1/2/3 equal published 84/23/61 only on 06-03T15; 06-09 gives 53.1/33.9/81.0 and 06-12 32.4/43.1/92.5 (gate 3 had 84/23/61 on all three). No tied band in the sample is ramp- or availability-bound. A tighter `dual_feasibility_tolerance` (1e-10) does not restore it. The slack price (about 8e-8 per unit fill fraction) is swamped by objective magnitudes of about 1e6 at the -1000 floor bids. Also YENDWF1 06-09 (17 vs 108), GORDON, TUNGATIN | worse than nempy | fix: scale the slack price against the objective, make ties hard rows with a violation slack, or a lexicographic second stage (PR #172 follow-up) |
| Basslink (T-V-MNSP1) flow | now undershoots: 06-04 -190.3 vs -312.7, 06-09 -314.0 vs -400.0, 06-13 -100.0 vs -151.9; 06-03 +60.5 unchanged (with N-Q-MNSP1 -61 and NSW1-QLD1 +116). TAS1 ROP is on published (+3.2, +2.3, +0.9) | flow differs from NEMDE; nempy ignores offers | offers, bands or loss share to check; the 1-second FCAS was not the cause |
| 2026-06-06 (no binding constraint) | ROP 3 to 5 below AEMO in every mainland region; nempy 3 to 7 below | shared with nempy | cause not isolated |
| TAS1 FCAS tail | LOWERREG +16.1 on 06-22; 06-21 RAISEREG -54.9 (nempy -9) and RAISE60SEC -54.6 | partly worse | small |
| Constraints with no public definition | 67 distinct (`N_NIL_TE_B`, `N_MBTE1_B`); small effect | same as nempy | not fixable |
| SA1 ROP | -2 to -4 on 06-10, 06-21, 06-30 | shared with nempy | unknown |
| V-SA loss equation | matches no demand definition (residual about 0.011 to 0.018, not constant): probably a term missing from the cached `LOSSFACTORMODEL` | n/a | follow-up in ADR 0027 |
| Fast start | 2 of 41 ours-only dispatch gaps (38 MW) at gate 2 | nempy models it | G12 not started |

Fixed since gate 3: V-S-MNSP1 and V-SA (zero-flow constraints, #177); 1-second FCAS (#178); interconnector loss demand (#165); `unknown_duid` skips.

## Verified checks

- **Load FCAS (G8, gate 3):** TAS1 RAISE6SEC 06-21 gap -1.4 (was +19755), RAISE60SEC -54.6 (was -20289.6);
  06-12, 06-09, 06-29, 06-30 and 06-10 are 0.0. `F_T_AUFLS2_R6`, `F_T_NIL_MAXS_*` and `F_V+NIL_APD01_*`
  are no longer skipped.

- **Tie-break (G13):** DUNDWF1/2/3 equal the published 84/23/61 on 2026-06-03 15:00, 06-09 15:00 and
  06-12 23:55 (without it: 100/0/68, 149/0/19, 131/0/37). Regional ROP moved by at most 4e-6.
- **Loss factors (G6):** QLD1 ROP on 2026-06-21 18:00 became exact (121.11); NSW1, VIC1 and SA1 remain
  off. Stock nempy confirms XML price = MMS price / loss factor, with SECONDARY_TLF x DLF for the
  generator side of bidirectional units.
- **Interconnector losses (G7):** NSW1-QLD1 06-03 875 to 7.2 MW (published 1.5); V-SA 06-09 285 to
  66.9 (60.8); V-S-MNSP1 06-09 209 to 7.6 (published 0; equals nempy).
- **Elastic rows:** only HUMENSW (0.3 to 0.4 MW, ramp) is violated among physical rows.

## Caveats

- Gate 3 beats stock nempy on ROP, FCAS and dispatch partly because nempy ignores Basslink offers and
  our model has more inputs for the zero-flow cases; read the per-source table, not only the means.
- Ten intervals, one per stratum: large gaps at one interval can dominate a mean (use the medians).
- Skipped constraints are judged against AEMO's binding list only; AEMSim's own per-constraint duals are
  not yet compared.
- nempy takes AEMO's solved constraint RHS and `DISPATCHLOAD` UIGF/`INITIALMW` as inputs, as AEMSim
  does, so its agreement with NEMDE carries an input advantage.
- The complementary-slackness metric on the published solution is too crude to use as an acceptance
  metric yet (ignores minimum load, FCAS co-optimisation, storage load offers).

## Update log

- 2026-10-07: created; baseline, gate 1, gate 2 and stock nempy recorded.
- 2026-10-07: Basslink diagnosis: the forced import is caused by always-violated 1-second FCAS rows (see per-source table); the earlier 'no price effect' note on 1-second FCAS was wrong.
- 2026-10-08: gate 4 recorded (clean rerun on the Float64 cache, `run10_gate4_final/`; Simulations 1153/1153 on the merge). Found a bug in v0.2: #177's antijoin throws on an invoked constraint with a NULL `GENCONID_EFFECTIVEDATE` (`$CPP_3` from 06-09); fix is `matchmissing = :notequal`.
- 2026-10-07: gate 3 recorded (integration of #163 to #165, #168, #170, #172, #173, #175, #176; 1051/1051
  Simulations group tests pass on the merge).
