# 0020 Batteries under `AbstractNEMDispatch`

## Status

Accepted; the composite ramp rate is now computed by AEM (see [0102](0102-closed-loop-replay.md)) and the lookahead part was removed by [0069](0069-remove-lookahead-dispatch.md).

## What

- A battery (bidirectional unit, `DISPATCHTYPE = BIDIRECTIONAL`) is dispatched by `AbstractNEMDispatch` methods specialised on `T <: PSY.Storage`: `PSI.ActivePowerOutVariable` and `PSI.ActivePowerInVariable`, both `≥ 0`, with multipliers `+1` and `-1`. No new formulation type and no device-type list.
- NEMDE carries no state of charge, so `storage_capacity` and level limits go unused.
- `Out` and `In` may both be positive in one interval; there is no exclusivity constraint (NEMDE is a single LP with no binaries).
- `StorageSystemsSimulations.jl` is not used.

## How

- Availability is per direction: `Out ≤ gen MAXAVAIL`, `In ≤ load MAXAVAIL`, read from the `GEN` and `LOAD` `BIDPEROFFER_D` bid series, because `DISPATCHLOAD.AVAILABILITY` is a single number. `get_default_time_series_names` for `PSY.Storage` registers these two and no `"max_active_power"`.
- The ramp row bounds the net `Out − In` about `INITIALMW` by the per-minute rates, with elastic slack ([0037](0037-elastic-rows-remaining-families.md)). A unit that can cross zero takes AEMO's composite ramp rate (SO_OP_3705 Appendix C), computed by AEM from both sides' bid rates.
- A battery is a participant the way a generator is: by carrying the series the formulation reads.

## Why

- NEMDE dispatches on market participation, not technology ([0013](0013-uniform-nem-dispatch-formulation.md)).
- The stock storage formulation is built around an energy-level variable with no `DISPATCHLOAD` field behind it; bending it would need a fake capacity or a parallel `INITIALMW` path.
- Simultaneous `Out` and `In` is an accepted limitation; add exclusivity only if real dispatch shows it matters. The per-side FCAS rows assume it does not occur ([0017](0017-fcas-market-formulation.md)).
