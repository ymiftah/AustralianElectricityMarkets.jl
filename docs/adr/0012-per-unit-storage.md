# 0012 Units: MW in the `System`, per-unit at the formulation boundary

## Status

Accepted; supersedes its original decision that `GenericConstraint` and FCAS values are stored per-unit (the NEMDE inputs of [0101](0101-aem-writes-aemsim-reads.md) store raw MW).

## What

- `GenericConstraint` RHS, bids and FCAS series are stored in MW (natural units). AEMSim divides by the system base power when it builds rows.
- `InterconnectorLossModel` is the exception: an attached model is per-unit of the system base; one returned by `interconnector_loss_models` is MW.
- Never scaled: dimensionless fields (`loss_constant`, `from_region_loss_share`, `ConstraintTerm.factor`, the `"invoked"` mask, `constraint_weight`) and `$/MWh` or `$/MW` prices.

## How

- `attach_interconnector_losses!` converts once via `_to_pu`: `breakpoints` divide by the base; `loss_flow_coefficient` and `demand_coefficients` (1/MW) multiply by it.
- `loss_factor`, `interconnector_losses` and `loss_segments` are unit-agnostic: pass `flow` and `demand` in the model's own convention.
- FCAS offer-curve readers (`_get_fcas_offer_curve`) divide the stored MW by the system base on read. FCAS values are system-base, so reading under `DEVICE_BASE` throws.
- Formulations divide MW series by `PSI.get_base_power(container)` (for example the generic-constraint RHS and the interconnector limits).

## Why

- A `SupplementalAttribute` is never stamped with `units_info`, so PSY cannot convert it on read; converting once at attach is the only option.
- Keeping series in MW makes them comparable with AEMO's published numbers; the conversion has one home per consumer.
- A dual recovered from a per-unit row is a price per per-unit, larger than AEMO's `$/MW` marginal value by the base power. Scale one side before comparing.
