# 0066. Public system contract, formulation-owned penalties and raw readers

## Status

Accepted. Extends [0065](0065-replay-system-package-boundary.md).

## Context

After 0065, AEMSim no longer touched a database, but three leaks remained across the
AEM/AEMSim/Readers boundaries:

- AEMSim called five `_`-prefixed AEM helpers that encode how AEM lays data out on a `System`
  (FCAS series names and bid sides, the dispatch device set, the non-scheduled load flag, the
  `SingleTimeSeries` builder). The cross-package contract was implicit.
- Two CVP factors, Interconnector Zero (1160, item 1) and Energy Inflexible Offer (380, item 13)
  of AEMO's *Schedule of Constraint Violation Penalty Factors* v8.0, were baked into the weight
  of the generic constraints AEM synthesises, while every other CVP factor lives in AEMSim.
- `EnergyTieBreak`, a service that only the AEMSim tie-break formulation creates and models,
  lived in AEM. `IntervalInputs` had no producer left.
- `read_units` mapped `CO2E_ENERGY_SOURCE` to `PowerSystems` enums and `read_bids` built
  `PiecewiseStepData` curves, so Readers depended on PowerSystems.

## Decision

- The five helpers are public AEM API: `fcas_series_name`, `fcas_bid_direction`,
  `nem_dispatch_devices`, `is_non_scheduled_load`, `single_series`.
- AEM's built-in constraints (`source == "built-in"`) carry the constructor's default weight
  1.0. AEMSim's `constraint_cvp_factor` prices a built-in constraint by its limit type
  (`INTERCONNECTOR_ZERO_CVP_FACTOR`, `FIXED_LOADING_CVP_FACTOR`) and any other constraint by its
  `GENCONDATA` weight. A built-in constraint of an unknown limit type throws.
- `EnergyTieBreak` moves to AEMSim. AEMSim is a top-level package module, so
  `IS.get_module` still resolves it when a `System` is deserialized with AEMSim loaded.
- `IntervalInputs` is deleted.
- `read_units` returns raw columns. `RegionModel` adds `TECHNOLOGY`/`FUELTYPE` when it builds
  generator and battery frames. `read_bids` and `read_fcas_bids` return the raw band arrays and
  the bid setters build the curves. Readers no longer loads PowerSystems.

- `run_replication` is the one public build-and-execute path over `replication_simulation`, so
  repository scripts no longer copy the package's build, execute and failure-logging code. This
  narrows 0065's "callers use PSI's build and execute APIs": `replication_simulation` still returns
  an unbuilt simulation for callers that need PSI directly.

## Model behaviour

Ownership refactor only. Every slack is priced at the same factor as before; the Interconnector
Zero solve regression now takes its factor from AEMSim. The FCAS argument stage now creates each
offer group's capacity variables in turn (the generation-side variables of every bidirectional
storage device before its load-side ones), which changes JuMP variable order but not the model.
No new departure from AEMO.

## Consequences

A `System` holding an `EnergyTieBreak` needs AEMSim loaded to deserialize. Code that read
`TECHNOLOGY`/`FUELTYPE` from `read_units`, or `piecewise_step_data` from the bid readers, must
derive them from the raw columns.
