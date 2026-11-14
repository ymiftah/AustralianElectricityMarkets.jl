# FCAS price tie at 2026-06-04 04:15, SA1 RAISE6SEC / RAISE60SEC

Read-only investigation. Scripts: `/home/simba/.claude/jobs/568bf863/tmp/fcas-tie/` (a2, b1, b2, c1, d1, d2, e1, e2, f1, g1).
Outputs: `/run/media/simba/Store/aem_validation/2026-11-14_compare_psi-split-fcas-tie/` (`lp_snapshot.jls`, `face_vertices.jls`).
Method: FCAS price recomputed from each snapshot as the sum of `NEMConstraintLimit` duals of the generic constraints that carry
`FCASRequirement`s, divided by `base_power * 5/60`, compared with `read_published_interval`. Then the 04:15 LP of HEAD (d03cd48) was rebuilt
(3-step simulation), the integers fixed, the LP re-solved, and the optimal dual face computed by LP (complementary slackness with the
solved primal).

## 1. Where the 0.3516 gap is

One interval and two cells, identical in all three candidates (task18, task15 columns, task15 free rows):

| Interval | Region | Service | NEMDE ROP | baseline | task18 / task15 / task15e |
| --- | --- | --- | --- | --- | --- |
| 04:15 | SA1 | RAISE60SEC | 4.5484 | 4.5484 (gap 2.3e-6) | 4.9000 (+0.3516) |
| 04:15 | SA1 | RAISE6SEC | 4.9000 | 4.9000 (gap -9e-16) | 4.5484 (-0.3516) |

The two prices are swapped. Their sum is unchanged (9.4484), which is why the bias in `comparison_summary.csv` does not move while MAE and
max gap do. Every other FCAS cell of all 4 runs (600 cells each) is within 1.64e-4 of NEMDE.
Underlying dual values (price units): the requirement duals of `F_S++TBTU_R6@2024-12-03#1` and `F_S++TBTU_R60@2024-12-03#1` are
(4.89, 4.5384) in the baseline and (4.5384, 4.89) in the candidates; the extra 0.01 of the published price is another small generic constraint.

## 2. Which duals differ at 04:15 and are both solutions optimal

Differing duals at 04:15 (any candidate vs baseline): 11 `NEMConstraintLimit` and 39 `FCASJointCapacityConstraint` cells. Over all 12
intervals baseline vs task18: 61 NEMConstraintLimit cells (26 are FCAS-requirement constraints, 27 are one-term `rhs = 0` unit-energy
constraints, 8 other) and 293 FCASJointCapacityConstraint cells (17 to 41 per interval).
The FCAS-price-relevant ones:

- `F_S++TBTU_R6` and `F_S++TBTU_R60`: the two requirement rows swap (above).
- `SA1_RAISE6SEC_lower` and `SA1_RAISE60SEC_lower` for TORRB2: 4.083 / 6.202 (baseline) against 3.149 / 6.682 (candidates).
- offer-band and MaxAvail rows of every SA1 unit cleared in R6 and R60 (CBWWBA1, HVWWBA1, ADPBA1, HPR1, DRSHVS02, ASRMGE04, ASSENC1,
  DRGBND02, TIB1, BLYTHB1, DRVIOT01, MANNUMB1): each moves by exactly the same 2.93 raw (0.3516 price units) in opposite directions
  for R6 and R60.

Primal rows: the two requirement rows are both binding (ax = 0, rhs side). All cleared units are identical in R6 and R60
(TIB1 0.50, TB2B1 0.19, LBB1 0.13, CBWWBA1 0.01, HVWWBA1 0.02, BLYTHB1 0.38, ADPBA1 0.03, HPR1 0.85, DRSHVS02 0.05, DRVIOT01 0.11,
ASRMGE04 0.04, ASSENC1 0.01, DRGBND02 0.02 pu). TORRB2 sits at energy 0.4 pu with R6 and R60 capacity 0: the lower slope rows
`e - s*cap >= EnablementMin` are binding at cap = 0 (the trapezium's lower corner), so it is on the slope at its first point, not
on the flat top; its capacity band variables are basic at 0.

Optimality of both vertices: the LP at HEAD was rebuilt and re-solved from the same primal. HiGHS returned the baseline-like vertex
(R6 raw 40.75 = 4.89, R60 37.82 = 4.5384), while the simulation run had returned the other end; the objective is identical
(-589543.0928456 MIP, -589543.0928456 fixed LP). The optimal dual face computed by LP (sign restrictions from complementary
slackness at that primal, stationarity `c = A'y + z`) is feasible and gives **R6 raw in [37.82, 40.75] and R60 raw in [37.82, 40.75]
with R6 + R60 = 78.57**, i.e. prices [4.5384, 4.89] each and a constant sum. Baseline and candidates are the two end points. The
nearest dual vertex to the solver's one with R6 at the other end differs only in the R6/R60 offer-band, MaxAvail, TORRB2 joint-lower,
TORRB2 energy offer_band and the two requirement rows (51 rows, all in SA1 R6/R60), and reproduces the candidate numbers (TORRB2
joint-lower 3.149 and 6.682). So both dual solutions are dual feasible and optimal against the shared primal; neither is wrong.

## 3. Structural causes

Checked and ruled out: **no parallel rows**. Over all 37,755 rows of the 04:15 LP, zero groups of two or more rows have the same columns
with proportional coefficients; there is no duplicate joint-capacity / trapezium / generic row. The structural facts found:

1. **Twin requirement constraints.** `F_S++TBTU_R6` and `F_S++TBTU_R60` have identical RHS (-114.78), identical energy terms (LBB1,
   LKBONNY1..3, LADBROK1/2, SNUG1, CNUNDAWF, TB2SF1, TB2B1, TBSF1) and identical V-SA flow term; they differ only in the service
   (LBB1, LADBROK1/2, TB2B1 FCAS terms and the SA1 region aggregate). Both bind and every provider offers the same quantity to both
   services. Only the sum p6 + p60 (the marginal value of the shared energy/flow part) is identified by the primal; the split is a
   free parameter of the face.
2. **Bounds of the face.** Each price is capped at 4.89 to 4.90: HPR1's fourth R6 and R60 band is 4.89 and MANNUMB1's fourth R6 and
   R60 band is 4.90 (equal for both services, quantity 0 at the margin, `MANNUMB1` capacity is basic at 0). NEMDE's published
   R6 = 4.90 is the upper end of the face; R60 = 4.5484 is the remainder. These coincidences are read from band prices, not proved to be the
   active bounds.
3. **Primal degeneracy at the trapezium corner.** TORRB2 is at EnablementMin with zero capacity for both services, so its R6 and R60
   joint-lower rows bind with a basic-at-zero capacity: their duals (and TORRB2's energy offer_band dual) take any value consistent
   with stationarity.
4. **Generic degeneracy.** At the 04:15 optimum 28,590 rows are binding but 23,343 of them carry a zero dual, and 32,424 columns sit at
   a bound with zero reduced cost against 3,051 strictly interior columns; zero-width and unavailable bands, MPC-priced slack columns
   and one-term `rhs = 0` generic constraints (`V_*_ISL_0` / `FLT_0`: unit energy <= 0 on a column already bounded at 0) give the other
   ~50 moving duals (their duals jump between 0 and about -1009.77 raw/8.33, i.e. between the constraint and the column bound).
   They are parallel to a variable bound, not to another row, and none touches an FCAS price.

Zero-width MNSP columns, GC relaxation columns and GC free rows each perturb the LP (column order, presolve, basis path) and so
choose a different vertex of the same face. This is the mechanism of ADR 0094 (many tied optima, HiGHS path decides), here at the
dual level with the primal unchanged.

## 4. How NEMDE resolves it

There is no documented FCAS tie-break rule, so NEMDE's value is the outcome of its own solver path.

- AEMO, *Schedule of Constraint Violation Penalty Factors* v8.0, Item 53 (Tie-Break constraint): "In the NEM market, tie-breaking
  model is by default enforced only for energy bids and offers, not for the FCAS offers. Please note that FCAS price-tied offers will be
  dispatched randomly over dispatch intervals based on how the LP optimization process in NEMDE approached that solution."
  (`~/.agents/skills/nem-expert/references/constraint-violation-penalty-factors/06-items-36-53.md`, Item 53.)
- AEMO, *Constraint Frequently Asked Questions* v3, Q3.19: tie-breaking constraints "only apply to energy bids and not FCAS".
- AEMO, *FCAS Model in NEMDE* (sections 2 to 7): defines trapezium scaling, joint energy/FCAS rows and availability; it states no rule
  for choosing the price among co-binding requirement constraints.
The model already has the only documented tie-break (energy, `TieBreakMarket`, parameter `TieBreakScaleParameter`).

## 5. Recommendation

This is pure dual degeneracy (an optimal face of width 0.3516 $/MW in each of two services with constant sum), not a modelling error:
no duplicate rows, no missing documented AEMO rule. No formulation change can make the split unique "independent of LP structure":
any such change would be an invented rule calibrated to one NEMDE sample (NEMDE took the high end for R6 here, but its own
choice is solver-path dependent per the AEMO text above). Options:

1. Proceed with the structural refactors (MNSP all-10-bands, GC free rows) and treat this cell as an accepted, documented
   dual-degenerate cell. In the comparison gate compare the invariant quantities: primal variables, objective, energy prices, and
   the **sum of tied FCAS prices** (here 9.4484, unchanged); flag FCAS price deltas only when the sum over the tied services differs (only the one SA1 04:15 pair differs in these runs).
2. If a deterministic FCAS price is wanted for reporting, add a post-solve step on the fixed-integer LP that selects a dual
   vertex of the optimal face by a rule (for example the face LP of `d1.jl` with a fixed lexicographic preference). That is a
   model change needing its own ADR and a check against several days of NEMDE, which would confirm or refute the "high end for
   the faster service" pattern; fidelity is unmeasured today (this is ADR 0094 option 4 at the dual level).
3. Do not try to fix it by removing the new columns: the baseline vertex is a path accident of the old LP (the re-solve of the
   candidate LP also returned it).

Caveats: the face was computed for the HEAD LP (task18 structure) at 04:15 with 3-interval rolling state; the baseline, task15 and
task15e LPs were not rebuilt (their duals are read from snapshots and lie at the same two end points). The identification of
HPR1 and MANNUMB1 band prices as the face bounds is by coincidence of values.
