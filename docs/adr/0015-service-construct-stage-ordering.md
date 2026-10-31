# 0015. `LinearFactorLimit` assembles its LHS in the Model stage, not the Argument stage

## Status

Accepted

## Context

`PowerSimulations.jl` builds a `DecisionModel` in a fixed order (`core/optimization_container.jl`,
`build_impl!`): devices' `ArgumentConstructStage`, then services' `ArgumentConstructStage`, then
branches' `ArgumentConstructStage`, then devices' `ModelConstructStage`, then the network model,
then branches' `ModelConstructStage`, then services' `ModelConstructStage`. A device or branch
variable is only guaranteed to exist in the `OptimizationContainer` once that component kind's own
`ArgumentConstructStage` has run.

[`LinearFactorLimit`](@ref)'s [`NEMConstraintLHS`](@ref) expression sums, per
[`ConstraintTerm`](@ref), a device's `ActivePowerVariable` (or
`ActivePowerOutVariable`/`ActivePowerInVariable` for storage) or an `AreaInterchange`'s
`FlowActivePowerVariable`. The interconnector case is the binding constraint: `AreaInterchange`
is a branch, so its `FlowActivePowerVariable` exists only after branches' `ArgumentConstructStage`
has run — which happens *after* services' `ArgumentConstructStage` in PSI's build order. A
`GenericConstraint` can also reference another service's variables through a future formulation
(e.g. an FCAS enablement variable owned by an `FCASMarket` service); those aren't guaranteed to
exist until that service's own stage has run either.

## Decision

`LinearFactorLimit`'s `PSI.construct_service!` splits across both stages:

- `ArgumentConstructStage` only allocates containers it can build with no dependency on another
  component kind: the `NEMConstraintLHS` expression (empty, one cell per time step) and the
  `NEMConstraintRHSParameter`.
- `ModelConstructStage` is where every term's `add_to_expression!` actually runs, along with
  `add_constraints!` and dual registration. By this point devices, branches, and every other
  service registered ahead of `GenericConstraint` in the template have all completed both of
  their stages, so every variable a term might reference is guaranteed to exist.

A future FCAS market formulation (`FCASMarket`) that only sums variables owned by devices it
manages directly — never a branch's or another service's variable — has no such ordering
constraint and may assemble its expression in the `ArgumentConstructStage` instead.

## Consequences

- `LinearFactorLimit` never needs to guess whether a referenced variable exists yet; it always
  runs after every producer of a variable it might sum.
- The trade-off is stage placement is decided per formulation, not fixed by
  `AbstractNEMConstraintFormulation`: a future formulation must re-derive which stage is safe from
  its own variable dependencies, using this ADR's reasoning rather than assuming
  `LinearFactorLimit`'s choice applies unchanged.
