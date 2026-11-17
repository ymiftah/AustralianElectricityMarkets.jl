# 0069 Remove `NEMLookaheadDispatch`

## Status

Accepted. Narrows the dispatch family to the run interface (build once, step per interval).

## What

- `NEMDispatch` is the only concrete `AbstractNEMDispatch`; the abstract type stays as the dispatch point of the shared device methods.
- There is no pre-dispatch (5-minute or 30-minute) formulation, no chained ramp base inside one model and no formulation-dependent FCAS input timing.
- FCAS inputs follow AEMO's dispatch process at every interval: telemetered inputs and AGC scaling always apply (*FCAS Model in NEMDE*, Tables 1 to 3).

## Why

- Pre-dispatch FCAS timing (telemetry and AGC scaling on the first interval only, none of the AGC ramp scaling in 30-minute pre-dispatch) overwrote FCAS offer parameters at build, which cannot work in a recurrent build.
- The NEMDE path never used the lookahead machinery, which had spread across the dispatch, storage and FCAS formulations.
- A pre-dispatch study needs a new formulation; the deleted code is in git history.
