# 0013 One device formulation for every NEM dispatch participant

## Status

Accepted; the lookahead mode was removed by [0069](0069-remove-lookahead-dispatch.md), and limits and state now come from AEM ([0101](0101-aem-writes-aemsim-reads.md)).

## What

- Every scheduled resource is the same object to NEMDE: a ten-band bid stack, a ramp limit from `INITIALMW`, and an availability envelope. Technology enters through the numbers, never the form of the constraints.
- One formulation family, `AbstractNEMDispatch`, with one concrete subtype `NEMReplayDispatch`, replaces the stock per-type formulations (`ThermalBasicDispatch`, `RenewableFullDispatch`, `HydroDispatchRunOfRiver`), which import US-market assumptions (commitment, forecast ceilings, energy budgets).
- Methods are written against `PSY.StaticInjection` with no device-type gate; the template picks the types.

## How

- `nem_dispatch_participants(sys)` returns the types with at least one component carrying the dispatch-limit series (`_has_nem_dispatch_limits`). It checks the whole registered series set, not one arbitrary name: `"max_active_power"` is also written for renewables with a UIGF ceiling and would elect them falsely.
- `set_nem_dispatch_models!(template, sys)` sets `NEMReplayDispatch` for those types. A participant missing a series fails the build, naming the device.
- Time-series parameters are read by UUID: `get_parameter_column_refs(param, name)[t] * multiplier[name, t]`. Indexing the array by device name compiles and then `KeyError`s.
- Ramp series are per-unit per minute; `DISPATCHLOAD` publishes `RAMPUPRATE`/`RAMPDOWNRATE` in MW per hour, so AEM divides by 60 and by the base.
- `INITIALMW` is a time series (metered at the start of each interval), never a scalar rewritten per step.

## Why

- NEMDE dispatches on market participation, not technology. Gating on `ThermalStandard`/`HydroDispatch`/`RenewableDispatch` reintroduced the assumption this removes.
- The mode lives in the formulation type because `PSI.requires_initialization` is called on a formulation instance, so a runtime field would be invisible. A subtype is PSI's own idiom; a parametric `NEMDispatch{B}` let bare `NEMDispatch` pass `set_device_model!` and then die with an unattributable `MethodError` deep in `build!`.
- The scope limit that is real is one injection variable per device; a unit needing state of charge layers it as a separate formulation. NEMDE carries none.
