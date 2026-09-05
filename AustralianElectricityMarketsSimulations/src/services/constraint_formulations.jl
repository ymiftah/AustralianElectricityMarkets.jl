# One level below `PSI.AbstractServiceFormulation`, mirroring PSI's own `AbstractReservesFormulation` —
# a common ancestor for future `GenericConstraint` formulations to share trait methods against.
abstract type AbstractNEMConstraintFormulation <: PSI.AbstractServiceFormulation end
