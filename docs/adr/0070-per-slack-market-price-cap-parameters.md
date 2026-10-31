# 0070. One Market Price Cap parameter per penalty slack

## Status

Superseded by [0085](0085-build-time-market-price-cap.md): penalties are priced at build from the
initial interval's cap, not re-priced at each step. It had replaced the mechanism of
[0065](0065-market-price-cap-repricing.md).

## Context

0065 recorded every priced slack `(slack, names, cvp_factor, rate)` in the model's settings `ext`,
keyed by JuMP model identity, and registered one placeholder `MarketPriceCapPenaltyParameter` on
`PSY.Area`, whose attributes named the balance slacks and whose values were all zero. Overriding
PSI's private `_update_parameter_values!` for that key re-added every recorded penalty at each step.
A review against PSI's patterns flagged this as model state held outside the
`OptimizationContainer`, one parameter standing for unrelated slacks, and a private-PSI override.
The generic-constraint service rate override sat in the same `ext` record.

## Decision

- `_add_mpc_penalty!(container, V, T, names, cvp_factor; meta, rate)` prices the slack container
  keyed `(V, T, meta)`. Without `rate` it adds a `MarketPriceCapPenaltyParameter` keyed by `T`, with
  meta `"<V>"` or `"<V>_<meta>"`, `V` as its cost attribute's variable type, the interval caps as
  values and `cvp_factor` times base power times interval hours as multiplier.
- A per-key `update_container_parameter_values!` method (for components and for services, to avoid
  ambiguity with PSI's service method) re-writes the caps for the step's window and re-adds the costs
  to the variant objective, as the FCAS and MNSP band prices already do.
- A penalty with a fixed `rate` (an FCAS service model's `"market_price_cap"`) is constant across
  steps, so it is priced as an invariant objective term with no parameter.
- The generic-constraint slack cost update moves from PSI's `handle_variable_cost_parameter` service
  hook to the same per-key `update_container_parameter_values!` layer, reading the service model's
  `"market_price_cap"` attribute from the model's template. Every AEMSim objective parameter now
  updates through that one public method.
- `handle_variable_cost_parameter` is not used: PSI's device path calls it with the component's
  `operation_cost`, which `PSY.Area` and `PSY.AreaInterchange` do not have.

## Consequences

- No AEMSim model state lives in the settings `ext`; only the user's `"market_price_cap"` override
  is read from it.
- The private `_update_parameter_values!` override is gone.
- Every non-area-balance network model is re-priced too, since each penalty registers its own
  parameter rather than relying on the first one registering the trigger.
- Parameter results gain one `MarketPriceCapPenaltyParameter` container per priced slack.
