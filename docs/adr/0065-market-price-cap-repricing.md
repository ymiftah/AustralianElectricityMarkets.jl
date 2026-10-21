# 0065. Re-price violation penalties at each step's Market Price Cap

## Status

Accepted.

## Context

Every violation penalty is a CVP factor times the Market Price Cap (MPC) of the interval it
prices (AEMO *Schedule of Constraint Violation Penalty Factors* v8.0). The MPC changes on 1 July.
A model built once and stepped through a range (0061) fixed each penalty at build, so
`replicate_range` rejected a chunk whose intervals sat under two caps. Only generic constraints
were re-priced per step, and only for their `invoked` mask.

## Decision

- Every penalty slack built through `_add_cvp_slack!`, `_add_fcas_slack!`, the energy-limit and
  total-offer `add_proportional_cost!` methods and the area-balance objective is priced by
  `_add_mpc_penalty!`. It adds the variant objective term for the build window and records
  `(slack, names, cvp_factor, rate)` in the model's settings `ext`, keyed by its JuMP model so a
  rebuilt model starts empty.
- `MarketPriceCapPenaltyParameter` is an objective-function parameter registered on the model's
  `PSY.Area` components by the area-balance objective. At each simulation step PSI calls its update,
  which re-adds every recorded penalty for the step's window, each interval at
  `_container_market_price_cap(container, timestamp)`: the settings `"market_price_cap"` override
  when set, else the dated cap. A penalty built with an explicit rate (the FCAS service model's
  `"market_price_cap"` attribute) keeps that rate.
- The generic-constraint slack parameter keeps its own update and now multiplies its per-MPC
  coefficient by the cap of each interval at build and at every step. A service-level override is
  recorded alongside the penalties.
- PSI 0.38.4 looks up a device model for the parameter's component type, and `PSY.Area` has none.
  `psi_compat.jl` overrides the private `_update_parameter_values!` for `PSY.Area` and this
  parameter only.
- `replicate_range` no longer rejects a chunk that crosses a Market Price Cap change. It still
  starts a new chunk at 00:05 on 1 July, because loss factors, and with them the price-tied band
  pairs, change with the financial year (0061).

## Consequences

- A standalone `DecisionModel` is unchanged: the recorded terms are part of its single objective.
- A simulation needs the area-balance objective to run, which every replication template has.
  A model without `AreaBalancePowerModel` and with more than one step would drop these penalties
  at the first update, so the penalty update must not be used with other network models.
- Each step re-adds every recorded penalty term, the same work as building them once.
- The cap is still looked up from `MARKET_PRICE_CAP_BY_FINANCIAL_YEAR`; supplying it as an attached
  time series would only change where `_container_market_price_cap` reads from.

## Verification

A two-step simulation across 1 July, where the intervals ending 00:00 and 00:05 sit under the
2024-25 and 2025-26 caps, equals two standalone solves objective for objective, and its second
objective exceeds the first. With the update disabled the second step's objective is zero.
