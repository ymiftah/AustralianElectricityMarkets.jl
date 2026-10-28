# NEM generic constraints are `LHS <op> RHS`, where LHS terms come from
# SPDCONNECTIONPOINTCONSTRAINT / SPDREGIONCONSTRAINT / SPDINTERCONNECTORCONSTRAINT and RHS
# from GENCONDATA/DISPATCHCONSTRAINT. Scoped enum matching AEMO's CONSTRAINTTYPE ('<=', '>=',
# '=').
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

# Keyword constructor: `IS.deserialize_struct` always calls `T(; vals...)`, so any
# `DeviceParameter` that round-trips through JSON needs one (see `FCASTrapezium`).
function UnitTerm(; duid::AbstractString, bid_type::BidType, factor::Float64)
    return UnitTerm(String(duid), bid_type, factor)
end

get_duid(t::UnitTerm) = t.duid

get_bid_type(t::UnitTerm) = t.bid_type


"A `FACTOR * <interconnector flow>` term, from `SPDINTERCONNECTORCONSTRAINT`."
struct InterconnectorTerm <: ConstraintTerm
    interconnector::String
    factor::Float64
end

function InterconnectorTerm(; interconnector::AbstractString, factor::Float64)
    return InterconnectorTerm(String(interconnector), factor)
end

get_interconnector(t::InterconnectorTerm) = t.interconnector


"""
A `FACTOR * <region's BidType aggregate>` term, from `SPDREGIONCONSTRAINT`.

!!! note
    `devices` is the region's contributing `Generator`/`Storage` names, resolved once by
    [`resolve_term_devices`](@ref) at ingestion time (see [`add_nem_constraints!`](@ref)) — `region`
    and `bid_type` are kept alongside it so downstream code can still see this is a regional
    aggregate, not merely an unlabelled device list.
"""
struct RegionTerm <: ConstraintTerm
    region::String
    bid_type::BidType
    factor::Float64
    devices::Vector{String}
end

function RegionTerm(
        region::AbstractString, bid_type::BidType, factor::Float64, devices::AbstractVector = String[],
    )
    return RegionTerm(String(region), bid_type, factor, String[d for d in devices])
end


function RegionTerm(; region::AbstractString, bid_type::BidType, factor::Float64, devices::AbstractVector = String[])
    return RegionTerm(String(region), bid_type, factor, String[d for d in devices])
end

get_region(t::RegionTerm) = t.region

get_bid_type(t::RegionTerm) = t.bid_type


"""
    get_devices(t::RegionTerm) -> Vector{String}

The region's contributing `Generator`/`Storage` names. Possibly empty.
"""
get_devices(t::RegionTerm) = t.devices


"""
Tags a [`GenericConstraint`](@ref) as governing a `(region, service)` FCAS price. Its shadow
price sums into that regional FCAS price, from `DISPATCH_FCAS_REQ`.
"""
struct FCASRequirement <: PSY.DeviceParameter
    region::String
    service::BidType
end

function FCASRequirement(; region::AbstractString, service::BidType)
    return FCASRequirement(String(region), service)
end

get_region(v::FCASRequirement) = v.region

get_service(v::FCASRequirement) = v.service


# IS reads a field's concrete type back from its own `__metadata__` tag only when the field
# serialized to a single `Dict`; an array field dispatches on the *declared* type, so
# `Vector{ConstraintTerm}` comes back as raw `Dict`s. Resolve each element individually.
_deserialize_device_parameter(d::Dict) =
    IS.deserialize(IS.get_type_from_serialization_metadata(IS.get_serialization_metadata(d)), d)

IS.deserialize(::Type{Vector{ConstraintTerm}}, data::Vector) =
    ConstraintTerm[_deserialize_device_parameter(d) for d in data]

IS.deserialize(::Type{Vector{FCASRequirement}}, data::Vector) =
    FCASRequirement[_deserialize_device_parameter(d) for d in data]


"""
A NEM generic constraint, `LHS <sense> RHS` — the mechanism AEMO uses for both network limits
and FCAS requirements. Attached to its contributing devices as a `PSY.Service`.

# Fields
- `name`: identifier — `GENCONID@EFFECTIVEDATE#VERSIONNO` for an AEMO-sourced constraint.
- `available`: whether it is enforced.
- `sense`: `LE`, `GE` or `EQ`, from `GENCONDATA.CONSTRAINTTYPE`.
- `rhs`: static default from `GENCONDATA.CONSTRAINTVALUE`, per-unit of the system base.
- `constraint_weight`: `GENCONDATA.GENERICCONSTRAINTWEIGHT` verbatim; 1.0 for a constraint whose
  `source` is `"built-in"`, which has no `GENCONDATA` row.
- `description`: human-readable, defaults to `""`.
- `terms`: the LHS algebra, from the `SPD*` tables.
- `fcas_requirements`: the `(region, service)` prices this constraint governs.
- `ext`: AEMO provenance — `gencon_id`, `limit_type`, `source`, `effective_date`, `version_no`.
- `internal`: `InfrastructureSystems` bookkeeping.
"""
mutable struct GenericConstraint <: PSY.Service
    name::String
    available::Bool
    sense::ConstraintSense
    rhs::Float64
    constraint_weight::Float64
    description::String
    terms::Vector{ConstraintTerm}
    fcas_requirements::Vector{FCASRequirement}
    ext::Dict{String, Any}
    internal::IS.InfrastructureSystemsInternal
end


function GenericConstraint(;
        name::AbstractString,
        available::Bool = true,
        sense::ConstraintSense,
        rhs::Float64,
        constraint_weight::Float64 = 1.0,
        description::AbstractString = "",
        terms::Vector{<:ConstraintTerm} = ConstraintTerm[],
        fcas_requirements::Vector{FCASRequirement} = FCASRequirement[],
        ext::Dict{String, Any} = Dict{String, Any}(),
        internal::IS.InfrastructureSystemsInternal = IS.InfrastructureSystemsInternal(),
    )
    return GenericConstraint(
        String(name), available, sense, rhs, constraint_weight, String(description),
        Vector{ConstraintTerm}(terms), fcas_requirements, ext, internal,
    )
end


PSY.get_available(value::GenericConstraint) = value.available

PSY.set_available!(value::GenericConstraint, val) = value.available = val

PSY.supports_time_series(::GenericConstraint) = true

get_sense(value::GenericConstraint) = value.sense

# pu under SYSTEM_BASE, MW under NATURAL_UNITS - stamped by add_service! like any other
# PSY.Component's units_info.
get_rhs(value::GenericConstraint) = PSY.get_value(value, Val(:rhs), Val(:mva))

"""
    get_constraint_weight(value::GenericConstraint) -> Float64

The weight of `value`'s slacks, as set by `GENCONDATA.GENERICCONSTRAINTWEIGHT` (1.0 when unset). It
scales the [`constraint_cvp_factor`](@ref) of the constraint.

# Arguments
- `value`: the [`GenericConstraint`](@ref).

# Returns
A `Float64`.
"""
get_constraint_weight(value::GenericConstraint) = value.constraint_weight

set_constraint_weight!(value::GenericConstraint, val) = value.constraint_weight = val

PSY.get_description(value::GenericConstraint) = value.description

PSY.set_description!(value::GenericConstraint, val) = value.description = val

get_terms(value::GenericConstraint) = value.terms

get_fcas_requirements(value::GenericConstraint) = value.fcas_requirements

PSY.get_ext(value::GenericConstraint) = value.ext

PSY.set_ext!(value::GenericConstraint, val) = value.ext = val


"""
    get_limit_type(value::GenericConstraint) -> Union{String, Nothing}

`GENCONDATA.LIMITTYPE`, or `nothing` if absent.
"""
get_limit_type(value::GenericConstraint) = coalesce(get(value.ext, "limit_type", nothing), nothing)


"""
    get_source(value::GenericConstraint) -> Union{String, Nothing}

`GENCONDATA.SOURCE`, or `nothing` if absent.
"""
get_source(value::GenericConstraint) = coalesce(get(value.ext, "source", nothing), nothing)


"""
    get_gencon_id(value::GenericConstraint) -> Union{String, Nothing}

AEMO's bare `GENCONID`, unversioned — unlike [`get_name`](@ref), which may include the
`EFFECTIVEDATE#VERSIONNO` suffix. Returns `nothing` if absent.
"""
get_gencon_id(value::GenericConstraint) = coalesce(get(value.ext, "gencon_id", nothing), nothing)
