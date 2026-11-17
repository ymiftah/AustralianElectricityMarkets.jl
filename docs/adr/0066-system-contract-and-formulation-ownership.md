# 0066 Public system contract and raw readers

## Status

Accepted. Its `EnergyTieBreak` and CVP-factor placement now live in AEM; ownership of NEMDE inputs is in [0101](0101-aem-writes-aemsim-reads.md).

## What

- The helpers AEMSim needs to read an AEM-built `System` are public AEM API, not `_`-prefixed: `fcas_series_name`, `fcas_bid_direction`, `nem_dispatch_devices`, `is_non_scheduled_load` and `single_series`.
- AEM's built-in generic constraints (`source == "built-in"`) are priced by limit type through `constraint_cvp_factor` (`INTERCONNECTOR_ZERO_CVP_FACTOR`, item 1 of AEMO *Schedule of Constraint Violation Penalty Factors* v8.0); any other constraint uses its `GENCONDATA` weight. A built-in constraint of an unknown limit type throws.
- Readers return raw columns and do not load PowerSystems: `read_units` returns `CO2E_ENERGY_SOURCE` unmapped, and `read_bids` and `read_fcas_bids` return raw band arrays. `RegionModel` derives `TECHNOLOGY`/`FUELTYPE`, and the bid setters build the `PiecewiseStepData` curves.

## Why

- Layout knowledge of a `System` (series names, bid sides, the dispatch device set) is a cross-package contract and must be explicit.
- Readers stay free of PowerSystems so the Cache/Data/Readers layers keep their dependency direction.
