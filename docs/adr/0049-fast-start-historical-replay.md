# Fast-start historical replay

Date: 2026-10-12
Status: implementation in progress

## Decision

Historical scheduled-thermal replay solves one five-minute commitment pass, advances fast-start states, then solves dispatch and prices with the profile. Luna implements source/test changes on `codex/fast-start-replay`, based on rebased PR #183 (`1b96332`). Assume clean cached rows and use small private helpers, existing PSI attributes and existing CVP cost machinery.

## Inputs and states

Use current daily offer `MINIMUMLOAD`/T1–T4 and period `MAXAVAIL`. Use current metered `INITIALMW` and effective energy ramp rates; the exact preceding dispatch mode/time provides the historical starting state. Previous target MW is used only for the documented real-time preprocessing resets. Current target MW, target mode/time and prices are comparison outputs.

Sources: [AEMO Electricity Data Model v5.7.0](https://visualisations.aemo.com.au/aemo/nemweb/MMSDataModelReport/), `BIDDAYOFFER_D` pp. 58–60, `BIDPEROFFER_D` pp. 65–67 and `DISPATCHLOAD` pp. 271–276; [Fast Start Inflexibility Profile, June 2021](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/dispatch/policy_and_process/fast-start-unit-inflexibility-profile.pdf), §§2–3, pp. 5–8.

All-zero/null timing offers are slow-start. Apply the §3 slow-start-to-fast-start and unavailable-rebid resets before choosing constraints. A previously offline unit is committed when its first-pass target exceeds 0.005 MW. Already committed units continue the profile. Completion of T4 alone does not force shutdown.

## Profile and ramp rows

With minimum load `M`, target mode `n` and target elapsed time `b`, the profile is zero in modes 0–1, `M*b/T2` in mode 2, `M` in mode 3, and `M*max(0, 1-b/T4)` in mode 4. Zero-duration segments are skipped. Modes 0–2 have a fixed profile target; modes 3–4 have a lower bound. Profile deficit/surplus is penalized separately from energy ramp violations.

The commitment pass omits profiles and energy ramps for starting modes 0–2. In the dispatch pass, target modes 0–2 omit ordinary energy ramps. Initial modes 3–4 use the actual meter and a full five minutes, including crossings of T3/T4.

For startup crossing T2, use minimum load as the energy ramp anchor and the remaining time after completing T2. This is a derivation from profile continuity and ordinary post-start ramping, corroborated by the MORTLK11 observation; public AEMO material does not expose the complete transition equation. Do not reset the ramp clock when T3 is crossed and do not substitute an invented `max(INITIALMW, M)` anchor. Independent real dispatch comparisons must establish the coverage of this derivation.

Example: starting mode 1/time 10, profile 10/2/40/7 minutes and minimum 20 MW leaves three minutes after T2. At 780 MW/h, the derived upper bound is `20 + 780/60*3 = 59 MW`; the previous ordinary-meter calculation gave `17 + 780/60*5 = 82 MW`. This arithmetic is supporting evidence, not proof of every transition case.

Sources: FSIP §5, pp. 10–11; [Guide to Scheduled Loads, final 2019 appendix](https://aemo.com.au/-/media/files/stakeholder_consultation/consultations/nem-consultations/2019/5ms-dispatch-non-rules-procedures/final/guide-to-scheduled-loads-clean.pdf?hash=D3323458E5AA7152ED9EDA7ADED7F3BC&la=en), energy ramp applicability and profile equations, pp. 16–17. The older appendix supplies structural equations, not current timing or CVP values. Full [NEMDE formulation distribution is restricted](https://www.aemo.com.au/energy-systems/market-it-systems/electricity-system-guides/nemde-queue-service).

## Offer accounting and penalties

Preserve existing priced band quantities and capacities. Relax the generator's band balance with nonnegative excess: `P = sum(q) + excess`. Excess pays its offer-violation penalty; it does not receive an invented final-band price. Use the existing PSI incremental-offer equality and modify its slack coefficient after PSI builds the bid cost. Do not copy the PSI PWL implementation.

The public scheduled-load appendix §4.5.3 (p. 13) includes an offer-violation term in band accounting, and its objective separates priced band quantities from violations. Applying that structure to the positive generator balance is the supported minimal relaxation; it is not a claim to reproduce every signed load/BDU equation in the restricted formulation.

Use factors 1155 for energy ramps, 1135 for total offered MW, 1130 for fast-start profiles and 370 for maximum availability. These are weighted penalties and simultaneous violations add. Thermal availability limits must not survive as duplicate hard caps when represented by elastic rows. Audit variable, time-series and band equality caps together.

Source: [Schedule of Constraint Violation Penalty Factors v8.0, effective 2 December 2025](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/congestion-information/2025/schedule-of-constraint-violation-penalty-factors.pdf), Table 1 items 3, 8, 10 and 14, pp. 7, 11, 12 and 14. Existing objective scaling multiplies per-unit slacks by system base and interval hours; this uniformly rescales the dispatch objective and preserves marginal $/MWh conversion.

## FCAS and PSI integration

Omit FCAS joint ramping in both passes for units initially in modes 0–2. Keep joint capacity and energy/regulation capacity constraints and existing FCAS enablement/scaling. Use the starting state, never the calculated target mode, for the exemption. Effective energy rates and SCADA/AGC capabilities remain separate inputs.

Source: [FCAS Model in NEMDE v3.0, effective 3 June 2024](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/dispatch/policy_and_process/fcas-model-in-nemde.pdf), §6.5 Table 3 footnote 19, p. 28. The local nem-expert extract renumbers this footnote as 11.

Use PSI device-model attributes for the private pass context. The pinned fork remains `93e1fb1469307d6bd78a90c8c4ad14f927bd4a90`. `solve_toy` already builds a five-minute model from a ten-minute transformed forecast, so replay can solve one row while retaining existing forecast storage. No future published state or new commitment binaries are necessary.

## Validation and limits

Test profile transitions, zero durations, boundary times, meter-based ordinary ramps, pass-specific energy/FCAS applicability, offer/profile/availability conflicts, objective units and final-pass pricing. Compare the named MORTLK11/QPS5 cases and the original 100 timestamps against a fresh baseline from the same base. Preserve the frozen results.

Future lookahead, other participant types and intervention What-If reconstruction need separate verified state semantics. This change adds no public switch selecting the previous fast-start approximation. The remaining transition derivation uncertainty is documented above and must be assessed against real outcomes rather than hidden behind a configurable formulation.
