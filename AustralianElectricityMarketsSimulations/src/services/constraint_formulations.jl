# One level below `PSI.AbstractServiceFormulation`, mirroring PSI's own `AbstractReservesFormulation`
# (`services_models/reserves.jl`) — a common ancestor for future `GenericConstraint` formulations
# to share trait methods against; `TermConstraint` is its only member today.
abstract type AbstractNEMConstraintFormulation <: PSI.AbstractServiceFormulation end
