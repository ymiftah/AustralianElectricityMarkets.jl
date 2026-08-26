# One level below `PSI.AbstractServiceFormulation`, mirroring PSI's own `AbstractReservesFormulation`
# (`services_models/reserves.jl`) — a common ancestor for future `GenericConstraint` formulations
# to share trait methods against; `TermConstraint` is its only member today.
#
# `NEMFCASMarket` stays a direct `PSI.AbstractServiceFormulation` subtype rather than joining this
# family (or a parallel one of its own): installed PSI keeps `TransmissionInterface`'s formulation
# as a sibling of `AbstractReservesFormulation`, not a member of it
# (`services_models/transmission_interface.jl` vs `services_models/reserves.jl`) — `TermConstraint`
# is `TransmissionInterface`-shaped (Type-dispatched), `NEMFCASMarket` is `Reserve`-shaped
# (instance-dispatched), and this mirrors that precedent exactly.
abstract type AbstractNEMConstraintFormulation <: PSI.AbstractServiceFormulation end
