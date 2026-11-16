# 0015 `LinearFactorLimit` fills its LHS in the model stage

## Status

Accepted; container layout amended by [0103](0103-aggregated-generic-constraint-containers.md).

## What

- `LinearFactorLimit`'s `construct_service!` creates only dependency-free containers and parameter values in `ArgumentConstructStage`.
- Every term's `add_to_expression!`, the constraint rows, slacks and duals are built in `ModelConstructStage`.
- A formulation that sums only variables of devices it manages directly (`FCASMarket`) may fill its expression in the argument stage.

## How

- PSI builds device argument stages, then service, then branch argument stages, then device, network, branch and service model stages.
- An `AreaInterchange` flow variable exists only after the branch argument stage, which runs after the service argument stage. Terms may also reference another service's variables (an FCAS enablement), which exist only after that service's own stage.

## Why

- In the model stage every producer of a variable a term might sum has run, so the formulation never guesses what exists.
- Stage placement is per formulation, not a shared rule: derive it from the formulation's own variable dependencies.
