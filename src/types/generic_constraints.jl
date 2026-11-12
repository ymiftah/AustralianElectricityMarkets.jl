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
    `devices` is the region's contributing `Generator`/`Storage` names.
    `region` and `bid_type` are kept alongside it so downstream code can still see this is a regional
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
# serialized to a single `Dict`; an array field dispatches on the *declared* type, so a
# `Vector` of the term union comes back as raw `Dict`s. Resolve each element individually.
_deserialize_device_parameter(d::Dict) =
    IS.deserialize(IS.get_type_from_serialization_metadata(IS.get_serialization_metadata(d)), d)

IS.deserialize(::Type{Vector{Union{UnitTerm, InterconnectorTerm, RegionTerm}}}, data::Vector) =
    Union{UnitTerm, InterconnectorTerm, RegionTerm}[_deserialize_device_parameter(d) for d in data]

IS.deserialize(::Type{Vector{FCASRequirement}}, data::Vector) =
    FCASRequirement[_deserialize_device_parameter(d) for d in data]


"""
A NEM generic constraint, `LHS <sense> RHS` — the mechanism AEMO uses for both network limits
and FCAS requirements. Attached to its contributing devices as a `PSY.Service`.

# Fields
- `name`: identifier — `GENCONID@EFFECTIVEDATE#VERSIONNO` for an AEMO-sourced constraint.
- `available`: whether it is enforced.
- `sense`: `LE`, `GE` or `EQ`, from `GENCONDATA.CONSTRAINTTYPE`.
- `rhs`: `GENCONDATA.CONSTRAINTVALUE` in MW as published, or a key of the per-interval right-hand side
  series in MW; read it with [`get_rhs`](@ref).
- `invoked`: whether the constraint is enforced, or a key of the per-interval invoked series; read it
  with [`get_invoked`](@ref).
- `constraint_weight`: `GENCONDATA.GENERICCONSTRAINTWEIGHT` verbatim; 1.0 for a constraint whose
  `source` is `"built-in"`, which has no `GENCONDATA` row.
- `description`: human-readable, defaults to `""`.
- `gencon_id`: `GENCONDATA.GENCONID` without the version suffix; defaults to the part of `name`
  before `@`.
- `limit_type`: `GENCONDATA.LIMITTYPE`, or `nothing` if absent.
- `source`: `GENCONDATA.SOURCE`, or `nothing` if absent.
- `effective_date`: `GENCONDATA.EFFECTIVEDATE`, or `nothing` if absent.
- `version_no`: `GENCONDATA.VERSIONNO`, or `nothing` if absent.
- `terms`: the LHS algebra, from the `SPD*` tables.
- `fcas_requirements`: the `(region, service)` prices this constraint governs.
- `ext`: free-form annotations; a NEMDE build leaves it empty.
- `internal`: `InfrastructureSystems` bookkeeping.
"""
mutable struct GenericConstraint <: PSY.Service
    name::String
    available::Bool
    sense::ConstraintSense
    rhs::Union{IS.StaticTimeSeriesKey, Float64}
    invoked::Union{IS.StaticTimeSeriesKey, Bool}
    constraint_weight::Float64
    description::String
    gencon_id::String
    limit_type::Union{String, Nothing}
    source::Union{String, Nothing}
    effective_date::Union{DateTime, Nothing}
    version_no::Union{Int, Nothing}
    terms::Vector{Union{UnitTerm, InterconnectorTerm, RegionTerm}}
    fcas_requirements::Vector{FCASRequirement}
    ext::Dict{String, Any}
    internal::IS.InfrastructureSystemsInternal
end


function GenericConstraint(;
        name::AbstractString,
        available::Bool = true,
        sense::ConstraintSense,
        rhs::Union{IS.StaticTimeSeriesKey, Real},
        invoked::Union{IS.StaticTimeSeriesKey, Bool} = true,
        constraint_weight::Float64 = 1.0,
        description::AbstractString = "",
        gencon_id = missing,
        limit_type = nothing,
        source = nothing,
        effective_date = nothing,
        version_no = nothing,
        terms::Vector{<:ConstraintTerm} = ConstraintTerm[],
        fcas_requirements::Vector{FCASRequirement} = FCASRequirement[],
        ext::Dict{String, Any} = Dict{String, Any}(),
        internal::IS.InfrastructureSystemsInternal = IS.InfrastructureSystemsInternal(),
    )
    id = (ismissing(gencon_id) || isnothing(gencon_id)) ? first(split(String(name), "@")) : String(gencon_id)
    return GenericConstraint(
        String(name), available, sense, _bid_number(rhs), invoked, constraint_weight, String(description),
        id, _constraint_text(limit_type), _constraint_text(source), _constraint_time(effective_date),
        _constraint_version(version_no), Vector{Union{UnitTerm, InterconnectorTerm, RegionTerm}}(terms), fcas_requirements, ext, internal,
    )
end

# A nullable GENCONDATA text value as a typed field: `missing` and `nothing` both mean absent.
_constraint_text(x::AbstractString) = String(x)
_constraint_text(::Any) = nothing

# GENCONDATA publishes the effective date as a `Date`; the field is a `DateTime` at midnight.
_constraint_time(x::DateTime) = x
_constraint_time(x::Date) = DateTime(x)
_constraint_time(::Any) = nothing

_constraint_version(x::Integer) = Int(x)
_constraint_version(::Any) = nothing


"""
    get_rhs(value::GenericConstraint, t::DateTime) -> Float64

The right-hand side of `value` at `t`, in MW as published. A static `rhs` is returned as stored; a keyed
one is read from its series at `t` with no unit conversion.

# Arguments
- `value`: the [`GenericConstraint`](@ref).
- `t`: the interval's start time.

# Returns
A `Float64` in MW.
"""
get_rhs(value::GenericConstraint, t::DateTime) = _constraint_value(value, value.rhs, t, Float64)


"""
    get_invoked(value::GenericConstraint, t::DateTime) -> Bool

Whether `value` is enforced at `t`. A static `invoked` is returned as stored; a keyed one is read from its
series at `t`, where a nonzero value means invoked.

# Arguments
- `value`: the [`GenericConstraint`](@ref).
- `t`: the interval's start time.

# Returns
A `Bool`.
"""
get_invoked(value::GenericConstraint, t::DateTime) = _constraint_value(value, value.invoked, t, Bool)

function _constraint_value(value::GenericConstraint, field::IS.TimeSeriesKey, t::DateTime, ::Type{T}) where {T}
    raw = IS.get_time_series_values(value, field; start_time = t, len = 1)::Vector{Float64}
    return T == Bool ? !iszero(only(raw)) : Float64(only(raw))
end

_constraint_value(::GenericConstraint, field, ::DateTime, ::Type{T}) where {T} = T == Bool ? Bool(field) : Float64(field)


PSY.get_available(value::GenericConstraint) = value.available

PSY.set_available!(value::GenericConstraint, val) = value.available = val

PSY.supports_time_series(::GenericConstraint) = true

get_sense(value::GenericConstraint) = value.sense

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

PSY.get_description(value::GenericConstraint) = value.description

PSY.set_description!(value::GenericConstraint, val) = value.description = val

get_terms(value::GenericConstraint) = value.terms

get_fcas_requirements(value::GenericConstraint) = value.fcas_requirements

PSY.get_ext(value::GenericConstraint) = value.ext

PSY.set_ext!(value::GenericConstraint, val) = value.ext = val


"""
    get_gencon_id(value::GenericConstraint) -> String

The constraint's `GENCONDATA.GENCONID` without the version suffix. Every version of one
`GENCONID` shares it.
"""
get_gencon_id(value::GenericConstraint) = value.gencon_id


"""
    get_limit_type(value::GenericConstraint) -> Union{String, Nothing}

`GENCONDATA.LIMITTYPE`, or `nothing` if absent.
"""
get_limit_type(value::GenericConstraint) = value.limit_type


"""
    get_source(value::GenericConstraint) -> Union{String, Nothing}

`GENCONDATA.SOURCE`, or `nothing` if absent.
"""
get_source(value::GenericConstraint) = value.source


"""
    get_effective_date(value::GenericConstraint) -> Union{DateTime, Nothing}

`GENCONDATA.EFFECTIVEDATE` at midnight, or `nothing` if absent.
"""
get_effective_date(value::GenericConstraint) = value.effective_date


"""
    get_version_no(value::GenericConstraint) -> Union{Int, Nothing}

`GENCONDATA.VERSIONNO`, or `nothing` if absent.
"""
get_version_no(value::GenericConstraint) = value.version_no
