# 0069. Remove NEMLookaheadDispatch

## Status

Accepted. Narrows the dispatch family to the replay interface (build once, step per interval).

## Context

`NEMLookaheadDispatch` chained intervals: interval 1 measured its ramp against a `DevicePower`
initial condition from an initialisation sub-solve and later intervals against the previous
interval's variable. FCAS followed AEMO's pre-dispatch telemetry timing under it
(*FCAS Model in NEMDE*, Tables 1 to 3): telemetered inputs and AGC scaling on the first interval
only in 5-minute pre-dispatch, and no AGC ramp scaling in 30-minute pre-dispatch. That timing
overwrote the FCAS offer parameters at build, so `FCASMarket` rejected the formulation in a
recurrent build. The replay path, which is the package's only interface, never used it, and its
machinery spread through the dispatch, storage and FCAS formulations: a `:dispatch`/`:p5min`/
`:predispatch` process Symbol, a storage-side initial-condition type and a parameter overwrite.

## Decision

- `NEMLookaheadDispatch`, `StorageInputDevicePower`, the `DevicePower` initial-condition methods,
  the chained ramp bases, `_fcas_process`, `_fcas_agc_ramp_applies` and the FCAS parameter
  overwrite are removed.
- `NEMReplayDispatch` is the one `AbstractNEMDispatch` subtype. The abstract type stays as the
  dispatch point of the shared device methods.
- FCAS inputs are read over a `_FCASWindow` with no process: AGC scaling and telemetered inputs
  apply at every interval, as in AEMO's dispatch process.
- `get_initial_conditions_device_model` stays, as PSI requires it of every formulation.
- The root `get_fcas_offer`/`get_scaled_fcas_trapezium` keyword arguments for pre-dispatch timing
  stay; they are general accessor options.

## Consequences

- A pre-dispatch study needs a new formulation; the deleted code is in git history.
- FCAS pre-flight and build no longer depend on the device template's formulation.
