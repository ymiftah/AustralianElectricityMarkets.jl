# NEM generic constraints are `LHS <op> RHS`, where LHS terms come from
# SPDCONNECTIONPOINTCONSTRAINT / SPDREGIONCONSTRAINT / SPDINTERCONNECTORCONSTRAINT and RHS
# from GENCONDATA/DISPATCHCONSTRAINT. Scoped enum matching AEMO's CONSTRAINTTYPE ('<=', '>=',
# '=') - see GenericConstraint types design, docs/superpowers/specs/2026-08-16-*.
IS.@scoped_enum(ConstraintSense, LE = 1, GE = 2, EQ = 3)

"""
Abstract supertype for one linear term on a [`GenericConstraint`](@ref)'s LHS. Concrete
subtypes hold names, not live component references — see [`GenericConstraint`](@ref) for why.
Factors are in natural MW, matching AEMO's own `FACTOR` columns; not per-unitized by
`BASE_POWER`.
"""
abstract type ConstraintTerm <: PSY.DeviceParameter end

get_factor(t::ConstraintTerm) = t.factor

"A `FACTOR * <unit's BidType service>` term, from `SPDCONNECTIONPOINTCONSTRAINT`."
struct UnitTerm <: ConstraintTerm
    duid::String
    bid_type::BidType
    factor::Float64
end
get_duid(t::UnitTerm) = t.duid
get_bid_type(t::UnitTerm) = t.bid_type

"A `FACTOR * <interconnector flow>` term, from `SPDINTERCONNECTORCONSTRAINT`."
struct InterconnectorTerm <: ConstraintTerm
    interconnector::String
    factor::Float64
end
get_interconnector(t::InterconnectorTerm) = t.interconnector

"A `FACTOR * <region's BidType aggregate>` term, from `SPDREGIONCONSTRAINT`."
struct RegionTerm <: ConstraintTerm
    region::String
    bid_type::BidType
    factor::Float64
end
get_region(t::RegionTerm) = t.region
get_bid_type(t::RegionTerm) = t.bid_type

"""
Tags a [`GenericConstraint`](@ref) as governing a `(region, service)` FCAS price — its shadow
price sums into that regional FCAS price, from `DISPATCH_FCAS_REQ`. Not the same as the
constraint's `terms`: a constraint's LHS can reference a service without governing its price,
and vice versa (regulation enablement counting toward the 5-minute requirement is both).
"""
struct FCASRequirement <: PSY.DeviceParameter
    region::String
    service::BidType
end
get_region(v::FCASRequirement) = v.region
get_service(v::FCASRequirement) = v.service
