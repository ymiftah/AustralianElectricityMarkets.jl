# NEMDE formulation documentation audit

Reviewed 12 October 2026 on `docs-intro-to-psi-nem`. This records documentation gaps; it does not
change the formulation or certify dispatch fidelity.

## Scope and revisions

- Current branch: `e3244e77fcad17696a2f084b4e3764d47322c5bd`.
- [PR #183](https://github.com/ymiftah/AustralianElectricityMarkets.jl/pull/183):
  `1b963328d546295b14d98227ccc79a50c1924cc1`, based on `v0.2`.
- [PR #184](https://github.com/ymiftah/AustralianElectricityMarkets.jl/pull/184):
  `ad87a912d046d373ca10c7b3f8f777eafcf5fe95`, based on #183.

The audit compares source constraints, objective terms, preprocessing and both PR diffs with
`docs/literate/nemde_model.jl`, and checks adjacent tutorial pages. PR #184's latest diff includes
automatic commitment and final dispatch solves, despite its description still listing that work
as pending. Its public documentation and full validation remain unfinished. The inherited battery
formulation on that revision was inspected separately: its directional bounds include the #182 fix.

## Overall finding

The page explains energy bands, ordinary ramps, regulated interconnector losses, generic
constraints, an isolated FCAS trapezium and UIGF. It is a useful introduction, but does not yet
support its promise that a reader will know every family of dispatch equations. Several omissions
change the feasible set, objective or interpretation of prices.

Equations below describe the inspected implementation in physical units. They are the equations
the documentation needs to explain, rather than a claim to have recovered the restricted NEMDE
solver. Let `h = 5/60` hours, `a` be an upper trapezium slope and `b` a lower slope.

## Gaps in the current formulation

### 1. Reference-node prices and consumption bids

**Page:** Bids and the objective, lines 69 onward.
**Code:** `src/setters/bids.jl`, `_refer_bid_prices`; NEM dispatch market-bid objectives.

The objective omits loss-factor referral and the negative value of cleared consumption bids:

```math
\widehat\pi^{d}_{u,j}=\operatorname{round}_{0.01}(\pi^{d}_{u,j}/\mathrm{LF}^{d}_u),
\qquad
C_E=h\left(\sum_{u,j}\widehat\pi^{GEN}_{u,j}q^{GEN}_{u,j}
-\sum_{u,j}\widehat\pi^{LOAD}_{u,j}q^{LOAD}_{u,j}\right).
```

Document the direction-specific BDU loss factors, unchanged MW quantities and unscaled FCAS
prices. The raw bid price comparison with regional price also needs this convention. The current
generation-only objective does not describe scheduled-load or battery charging bids.

### 2. Battery energy variables and net ramping

**Page:** Notation, objective, unit envelope and whole problem.
**Code:** `AustralianElectricityMarketsSimulations/src/nem_dispatch_storage.jl`.

```math
p_u=p^{out}_u-p^{in}_u,\quad
0\le p^{out}_u\le A^{GEN}_u,\quad 0\le p^{in}_u\le A^{LOAD}_u,
```

```math
p_u-p^0_u-s^{up}_u\le R^{up}_u h,\qquad
p^0_u-p_u-s^{down}_u\le R^{down}_u h.
```

Explain the replay adjustments that raise directional ceilings to the net ramp envelope.
The current branch can retain a lower static variable bound when a submitted ceiling exceeds the
rating; the inherited #182 fix in the PR stack makes the finite directional ceiling the variable
bound as well. Neither version imposes charge/discharge exclusivity or a storage-energy balance.
Those are implementation limitations, not a universal statement that NEMDE never considers stored
energy: AEMO's FCAS preconditions include daily/profiled energy tests that this package omits.

### 3. Scheduled loads and FCAS-only loads

**Page:** Regional balance, generic constraints and FCAS capability.
**Code:** `nem_dispatch.jl`, `nem_constraints.jl`, `fcas_market.jl`, dispatch-limit setters.

Write the balance using signed injections: generation minus dispatched consumption, plus net
battery injection. Unit energy terms in generic constraints use that sign convention too.
Explain that non-scheduled FCAS-only loads have zero modelled energy because their consumption is
already in demand. For scheduled loads, increasing consumption provides lower response and
decreasing consumption provides raise response, so regulation terms swap sides of the joint rows.

### 4. Contingency and regulation FCAS share capability

**Page:** FCAS constraints on units, lines 326 onward.
**Code:** `fcas_market.jl`, contingency model-stage joint capacity expressions.

For a generator or BDU contingency service `k`, the implemented rows include regulation:

```math
p_u+a_{u,k}f_{u,k}+f_{u,RaiseReg}\le E^{max}_{u,k},\qquad
p_u-b_{u,k}f_{u,k}-f_{u,LowerReg}\ge E^{min}_{u,k}.
```

The page's two-dimensional trapezium omits these terms. It describes an isolated service and the
energy/regulation capacity rows, but cannot describe concurrent contingency and regulation offers.
Show the load variant and applicable slack terms.

### 5. FCAS joint ramping and BDU regulation sides

**Page:** No corresponding equations.
**Code:** `fcas_market.jl`, `_add_fcas_joint_ramping_constraints!` and BDU side constraints.

```math
p_u+f_{u,RaiseReg}\le p^0_u+R^{AGC,up}_u h,\qquad
p_u-f_{u,LowerReg}\ge p^0_u-R^{AGC,down}_u h.
```

Distinguish AGC rates from ordinary energy rates. BDU contingency uses net energy; two-sided
regulation uses separate generation/load offers and side capacity rows. Its total regulation
target is `f_GEN + f_LOAD`, with a shared SCADA capability row preventing double counting.
Explain the signed load-side axis, combined enablement range and price contribution of both offers.

### 6. FCAS scaling and enablement gates

**Page:** UIGF explains only one scaling input.
**Code:** `src/fcas/scaling.jl`; `_fcas_enabled` and `_fcas_both_sides_enabled` in `fcas_market.jl`.

The implemented effective trapezium also uses AGC enablement limits and regulation ramp capability:

```math
L'=E^{min\prime}+b F^{max\prime},\qquad
H'=E^{max\prime}-a F^{max\prime}.
```

Document selection of the effective limits and maximum availability, missing/zero-input conventions,
and crossed breakpoints. Enablement is gated by offered quantity, sign/range tests, initial MW,
energy availability and AGC status. Failed gates pin FCAS to zero and suppress capacity rows;
merely requiring a point inside a trapezium does not describe that behavior. State the incomplete
daily/profiled energy checks and load scaling inputs.

### 7. Explicit piecewise-loss segment order

**Page:** Interconnector losses says a convex curve fills in order.
**Code:** `devices/interconnector_losses.jl`.

```math
x_i=B_{i,0}+\sum_j z_{i,j},\qquad
L_i=V_{i,0}+\sum_j m_{i,j}z_{i,j},\qquad 0\le z_{i,j}\le W_{i,j},
```

```math
z_{i,j+1}\le W_{i,j+1}y_{i,j},\qquad
z_{i,j}\ge W_{i,j}y_{i,j},\qquad y_{i,j}\in\{0,1\}.
```

These binaries force contiguous segment filling even at negative prices. Convexity alone does
not guarantee the correct loss equality in this objective. The breakpoint span remains a hard
modelling range even when flow limits are elastic. Distinguish the package's MILP representation
and subsequent pricing solve from the documented NEMDE problem.

### 8. Directional MNSP offers and terminal factors

**Page:** Describes only a free signed interconnector and static loss sharing.
**Code:** `devices/mnsp_links.jl`.

```math
x_i=q_i^{forward}-q_i^{reverse},\quad
q_i^d=\sum_j q_{i,j}^d,\quad
0\le q_{i,j}^d\le Q_{i,j}^d,\quad q_i^d\le A_i^d,
```

```math
q_i^{forward}\le U_i^{forward}y_i,\qquad
q_i^{reverse}\le U_i^{reverse}(1-y_i),\qquad y_i\in\{0,1\}.
```

Add directional band costs and terminal loss factors in regional balances. Their prices use the
link-offer convention, rather than unit price referral. The unconditional direction binary makes
zero net flow mean zero flow on both links. Current MNSP availability/band bounds remain hard;
ramp, fixed-load and elastic-offer behavior are incomplete.

### 9. Elastic rows, hard limits and the complete penalty objective

**Page:** Elastic constraints gives only a generic `<=` example and a partial factor table.
**Code:** `nem_constraints.jl`, `fcas_market.jl`, unit/flow rows and replication template.

Add the `>=` form with positive deficit slack and equality with both signs. Write regional balance
with deficit and surplus, and include penalties for FCAS MaxAvail and BDU ramping. State which
slacks are unconditional and which require `use_slacks=true`.

The current implementation raises energy availability to the ramp floor; it does not implement
a separately priced UIGF violation row at factor 385. Consequently the page's claim that its
forecast cap is implemented as a soft constraint is inaccurate for AEMSim. Keep AEMO's penalty
schedule separate from the list of rows actually built. #184 changes thermal availability only.

### 10. Energy tie-breaking

**Page:** No corresponding constraint or objective term.
**Code:** `nem_tie_break.jl`, `add_tie_break_constraints!`.

```math
\frac{q_a Q_b-q_b Q_a}{Q_{ref}}+s^+_{ab}-s^-_{ab}=0,\qquad
C_{tie}=h\,10^{-6}\sum_{ab}(s^+_{ab}+s^-_{ab}).
```

Explain grouping by region, direction and interval using referred prices, tolerance `10^-6`,
different-unit pairs and positive-width bands. This is a soft proportional allocation preference;
FCAS bands are excluded. The implementation uses a dollar coefficient of `10^-6`, without MPC.

### 11. Price normalization and multiple FCAS requirements

**Page:** Says the dual of the requirement is the FCAS price.
**Code:** `nem_constraints.jl`, `compute_fcas_prices`; replay price comparison.

For raw per-unit, per-interval duals, document
`energy_price = balance_dual / (system_base * h)` and
`FCAS_price[r,k] = sum(requirement_duals[g]) / (system_base * h)` over the relevant mapped
constraints. Several regional/global requirement constraints can contribute. Explain solver signs,
fixed-integer pricing and the distinction between unadjusted `ROP` and administered `RRP`.
The existing single-constraint statement is a useful special case only.

## Additional gaps introduced by the pending PRs

### PR #183: loss normalization and directional loss allocation

The new `docs/src/interconnector-losses.md` already explains inputs, annual applicability and
assumptions. Link it from the model page and add the actual optimization equations there.

1. **Analytic versus dispatch loss curve.** The analytic integral remains unchanged. If a chord
   brackets zero, dispatch vertices become `V_j = L_analytic(B_j) - L_chord(0)`, preserving slopes
   while ensuring the interpolated dispatch curve passes through zero. Replace the suggestion
   that the solver simply uses unshifted analytic losses at every breakpoint.
2. **Directional losses.** With signed vertex bounds `L_min <= 0 <= L_max`, the new split uses
   `ell_forward + ell_reverse = L`,
   `L_min*y <= ell_forward <= L_max*y` and
   `L_min*(1-y) <= ell_reverse <= L_max*(1-y)`.
   The active sender contributes `-TLF_from*(q + ell)` and the receiver `+TLF_to*q`.
   The fixed-share balance and marginal-price equation apply to the static-share case only.
3. **Demand coefficients.** Explain use of loss-equation regional demand inputs, independent
   effective-date/version selection and the narrowly gated FY2025-26 V-SA NSW term correction.
   Keep the annual coefficient table and provenance details in the dedicated loss page.

### PR #184: fast-start algebra, pass selection and offer violations

The current fast-start section has a sketch and mode description but no profile equations or
commitment algorithm. The latest PR adds:

```math
\phi(n,t)=\begin{cases}
0 & n\in\{0,1\},\\
Mt/T_2 & n=2,\\
M & n=3,\\
M\max(0,1-t/T_4) & n=4.
\end{cases}
```

Document fixed targets for modes 0-2, lower bounds for modes 3-4 and profile deficit/surplus
penalties. The two passes use flexible candidate dispatch, a `0.005 MW` commitment threshold,
profile advancement and final dispatch/pricing. Include initial-state preprocessing, zero-duration
segments and exact endpoint conventions. T4 completion alone does not force shutdown.

The final-pass energy ramp uses the actual meter over five minutes for initial modes 3-4.
When startup crosses T2, it uses minimum load and only the remaining time:
`p <= M + R_up*(5 - time_to_minimum_load)/60`, with the corresponding down row and ramp slacks.
This transition algebra is explicitly a project derivation, rather than a published complete
NEMDE equation. Ordinary ramp rows are omitted in the specified inflexible cases. FCAS joint
ramping exemptions depend on initial modes 0-2 in both passes, rather than target mode.

Thermal replay also changes bid accounting and availability:

```math
p_u=\sum_j q_{u,j}+s^{offer}_u,\qquad
p_u-s^{avail}_u\le A_u.
```

Band quantities retain their submitted bounds and costs. Offer excess has its own violation cost,
without an invented last-band price. Add factors 1135 (offer), 1130 (profile) and 370 (availability)
alongside 1155 (energy ramp); simultaneous violations contribute additive costs. Update the
whole-problem summary and distinguish thermal replay from lookahead and other unit types.

## Adjacent documentation requiring changes

- `nemde_aem.jl` lines 516-517 says fast-start profiles are not enforced. After #184 that claim
  must be replaced with the supported thermal replay scope and remaining limitations.
- Its hand-built thermal toy and formulation/container tables need checking against #184's new
  required `availability` parameter and elastic offer rows.
- `nemde_jump.jl` implements a reduced teaching model. Label its omissions explicitly so its
  isolated FCAS trapezium is not read as the complete AEMSim formulation.
- Replace the model page's mostly unlinked references with official AEMO URLs, versions and
  sections. Its FCAS PDF link goes through a third-party mirror.
- `docs/adr/` contains much of the implementation rationale, but does not substitute for public
  model documentation. Public pages should explain assumptions directly, without citing ADRs.

## Source checks and recommended order

Official sources checked include [FCAS Model in NEMDE v3.0](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/dispatch/policy_and_process/fcas-model-in-nemde.pdf),
sections 2, 4-6, pp. 6-28, and [Fast Start Inflexibility Profile, June 2021](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/dispatch/policy_and_process/fast-start-unit-inflexibility-profile.pdf),
sections 2-3 and 5, pp. 5-11. The NEM expert reference extracts were used to route these checks.
The [CVP schedule v8.0](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/congestion-information/2025/schedule-of-constraint-violation-penalty-factors.pdf)
was checked through the local AEMO extracts; the live PDF endpoint failed during this audit.
The annual loss report citations and reconstruction assumptions were inspected in #183's new
public loss page. The loss referral source is AEMO's *Treatment of Loss Factors*, section 12;
its older timing provisions should not be used for current dispatch timing.

First complete the FCAS equations, signed energy/bid conventions and actual elastic-row inventory.
Then add exact loss/MNSP equations and #183 cross-links, followed by #184's two-pass/profile model.
Finally replace the whole-problem shorthand with a summary matching those sections and update the
adjacent tutorials. Keep implementation limitations visible alongside the affected equations.

## Documentation coverage after implementation

The formulation is now split into an overview and five detailed Literate chapters. The original
FCAS introduction and historical walkthrough are consolidated into the FCAS chapter; the old page
retains landing links for its section anchors. Pending behavior is explicitly labelled rather than
merged into the optimisation implementation.

| Audited gap | Documentation |
| --- | --- |
| Energy price referral and consumption objective | [Energy bids and participants](../literate/nemde_energy.jl) |
| Battery directional availability and net ramping | [Energy bids and participants](../literate/nemde_energy.jl) |
| FCAS offer costs and maximum availability | [FCAS capability and co-optimisation](../literate/nemde_fcas.jl) |
| Participant coordinates and load directions | [FCAS capability and co-optimisation](../literate/nemde_fcas.jl) |
| Scaling, eligibility and timing | [FCAS capability and co-optimisation](../literate/nemde_fcas.jl) |
| Contingency/regulation capacity coupling | [FCAS capability and co-optimisation](../literate/nemde_fcas.jl) |
| Joint ramping and battery regulation sides | [FCAS capability and co-optimisation](../literate/nemde_fcas.jl) |
| Ordered losses and MNSP offers | [Interconnectors and losses](../literate/nemde_interconnectors.jl) |
| Slack signs and CVP inventory | [Violations, tie-breaking and prices](../literate/nemde_prices.jl) |
| Equal-price energy tie-breaking | [Violations, tie-breaking and prices](../literate/nemde_prices.jl) |
| Price normalisation and multiple requirements | [Violations, tie-breaking and prices](../literate/nemde_prices.jl) |
| Pending #183 anchoring, allocation and provenance | [Interconnectors and losses](../literate/nemde_interconnectors.jl), [loss input reference](../src/interconnector-losses.md) |
| Pending #184 profiles, two passes and distinct thermal violations | [Fast-start dispatch](../literate/nemde_fast_start.jl) |

The pending descriptions were checked against #183 head
`1b963328d546295b14d98227ccc79a50c1924cc1` and #184 head
`ad87a912d046d373ca10c7b3f8f777eafcf5fe95`. Recheck the labelled sections if those implementations change.

The remaining limitations are implementation limitations, now documented: battery energy state and
exclusivity, complete FCAS post-dispatch availability, some eligibility inputs and load telemetry
attachment, MNSP ramps/fixed load/elastic offers, Basslink converter/no-go behavior, and the full
price adjustment pipeline. The remaining-time fast-start ramp equation is identified as a project
derivation because AEMO does not expose the complete transition equation.

For local review, `docs/render_formulation_review.jl` executes the figures and generates linked
CommonMark pages under `docs-review/formulation/`. This review directory is ignored by git.

Verification completed through Kaimon: all six Literate chapters rendered with eight CairoMakie
figures, and a focused Documenter HTML build resolved their math, chapter references and legacy
FCAS landing links. Runic and Markdown lint passed. The local build uses Julia 1.13.1; the complete
site and its historical-data tutorials were not rebuilt or deployed.
