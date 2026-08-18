# The fixed, closed set of AEMO NEM FCAS response-time bands. Modeled as a scoped enum
# (matching PowerSystems' own convention, e.g. `UnitSystem` in `MarketBidCost`) rather than
# a free-floating `Float64`, since only these bands exist under AEMO's FCAS framework.
#
# `SEC1` is reserved for the 1-second fast FCAS markets (`RAISE1SEC`/`LOWER1SEC`, introduced
# Oct 2023, deferred to a follow-up) so the enum doesn't need a breaking change later — no
# reserve constructed by this initial pass uses it.
#
# A docstring can't be attached directly above this call: `@scoped_enum` expands to an
# `Expr(:toplevel, ...)`, which Julia's docsystem cannot document.
IS.@scoped_enum(
    FCASResponseTime,
    SEC1 = 1,   # RAISE1SEC/LOWER1SEC - deferred, unused for now
    SEC6 = 2,   # RAISE6SEC/LOWER6SEC
    SEC60 = 3,  # RAISE60SEC/LOWER60SEC
    MIN5 = 4,   # RAISE5MIN/LOWER5MIN
)

"""
Abstract supertype for Australian NEM FCAS (Frequency Control Ancillary Services) reserve
products — subtypes of `PowerSystems.Reserve`. See [`ContingencyFCASReserve`](@ref) and
[`RegulationFCASReserve`](@ref).
"""
abstract type NEMFCASReserve{T <: PSY.ReserveDirection} <: PSY.Reserve{T} end

"""
Event-triggered contingency FCAS (RAISE6SEC/60SEC/5MIN, LOWER6SEC/60SEC/5MIN). One instance
per (market, region).
"""
mutable struct ContingencyFCASReserve{T <: PSY.ReserveDirection} <: NEMFCASReserve{T}
    "Name of the reserve, e.g. \"RAISE6SEC_NSW1\""
    name::String
    "Indicator of whether the reserve is available"
    available::Bool
    "The NEM region this reserve requirement applies to"
    region::Union{Nothing, PSY.Area}
    "AEMO FCAS response-time band for this contingency market"
    response_time::FCASResponseTime
    "Regional requirement quantity (MW)"
    requirement::Float64
    "Maximum portion [0, 1.0] of the reserve that can be contributed per device"
    max_participation_factor::Float64
    "Fraction of service procurement assumed to be actually deployed"
    deployed_fraction::Float64
    ext::Dict{String, Any}
    internal::IS.InfrastructureSystemsInternal
end

function ContingencyFCASReserve{T}(
        name::AbstractString,
        available::Bool,
        region::Union{Nothing, PSY.Area},
        response_time::FCASResponseTime,
        requirement::Float64,
        max_participation_factor::Float64 = 1.0,
        deployed_fraction::Float64 = 0.0,
        ext::Dict{String, Any} = Dict{String, Any}(),
    ) where {T <: PSY.ReserveDirection}
    return ContingencyFCASReserve{T}(
        String(name), available, region, response_time, requirement,
        max_participation_factor, deployed_fraction, ext, IS.InfrastructureSystemsInternal(),
    )
end

function ContingencyFCASReserve{T}(;
        name::AbstractString,
        available::Bool,
        response_time::FCASResponseTime,
        requirement::Float64,
        region::Union{Nothing, PSY.Area} = nothing,
        max_participation_factor::Float64 = 1.0,
        deployed_fraction::Float64 = 0.0,
        ext::Dict{String, Any} = Dict{String, Any}(),
        internal::IS.InfrastructureSystemsInternal = IS.InfrastructureSystemsInternal(),
    ) where {T <: PSY.ReserveDirection}
    return ContingencyFCASReserve{T}(
        String(name), available, region, response_time, requirement,
        max_participation_factor, deployed_fraction, ext, internal,
    )
end

# Ordinary multiple dispatch on new methods of PSY's own generic functions, extended for a
# type we own — not type piracy (see plan §1 / PowerSystems/docs/src/how_to/add_new_types.md).
"""Get [`ContingencyFCASReserve`](@ref) `available`."""
PSY.get_available(value::ContingencyFCASReserve) = value.available
"""Get [`ContingencyFCASReserve`](@ref) `region`."""
get_region(value::ContingencyFCASReserve) = value.region
"""Get [`ContingencyFCASReserve`](@ref) `response_time`."""
get_response_time(value::ContingencyFCASReserve) = value.response_time
"""Get [`ContingencyFCASReserve`](@ref) `requirement`."""
PSY.get_requirement(value::ContingencyFCASReserve) = value.requirement
"""Get [`ContingencyFCASReserve`](@ref) `max_participation_factor`."""
PSY.get_max_participation_factor(value::ContingencyFCASReserve) = value.max_participation_factor
"""Get [`ContingencyFCASReserve`](@ref) `deployed_fraction`."""
PSY.get_deployed_fraction(value::ContingencyFCASReserve) = value.deployed_fraction
"""Get [`ContingencyFCASReserve`](@ref) `ext`."""
PSY.get_ext(value::ContingencyFCASReserve) = value.ext

"""Set [`ContingencyFCASReserve`](@ref) `available`."""
PSY.set_available!(value::ContingencyFCASReserve, val) = value.available = val
"""Set [`ContingencyFCASReserve`](@ref) `region`."""
set_region!(value::ContingencyFCASReserve, val) = value.region = val
"""Set [`ContingencyFCASReserve`](@ref) `response_time`."""
set_response_time!(value::ContingencyFCASReserve, val) = value.response_time = val
"""Set [`ContingencyFCASReserve`](@ref) `requirement`."""
PSY.set_requirement!(value::ContingencyFCASReserve, val) = value.requirement = val
"""Set [`ContingencyFCASReserve`](@ref) `max_participation_factor`."""
PSY.set_max_participation_factor!(value::ContingencyFCASReserve, val) = value.max_participation_factor = val
"""Set [`ContingencyFCASReserve`](@ref) `deployed_fraction`."""
PSY.set_deployed_fraction!(value::ContingencyFCASReserve, val) = value.deployed_fraction = val
"""Set [`ContingencyFCASReserve`](@ref) `ext`."""
PSY.set_ext!(value::ContingencyFCASReserve, val) = value.ext = val

"""
AGC-driven regulation FCAS (RAISEREG/LOWERREG). One instance per (direction, region).
Continuous, not response-time banded, so there is no `response_time` field.
"""
mutable struct RegulationFCASReserve{T <: PSY.ReserveDirection} <: NEMFCASReserve{T}
    "Name of the reserve, e.g. \"RAISEREG_NSW1\""
    name::String
    "Indicator of whether the reserve is available"
    available::Bool
    "The NEM region this reserve requirement applies to"
    region::Union{Nothing, PSY.Area}
    "Regional requirement quantity (MW)"
    requirement::Float64
    "Maximum portion [0, 1.0] of the reserve that can be contributed per device"
    max_participation_factor::Float64
    "Fraction of service procurement assumed to be actually deployed"
    deployed_fraction::Float64
    ext::Dict{String, Any}
    internal::IS.InfrastructureSystemsInternal
end

function RegulationFCASReserve{T}(
        name::AbstractString,
        available::Bool,
        region::Union{Nothing, PSY.Area},
        requirement::Float64,
        max_participation_factor::Float64 = 1.0,
        deployed_fraction::Float64 = 0.0,
        ext::Dict{String, Any} = Dict{String, Any}(),
    ) where {T <: PSY.ReserveDirection}
    return RegulationFCASReserve{T}(
        String(name), available, region, requirement,
        max_participation_factor, deployed_fraction, ext, IS.InfrastructureSystemsInternal(),
    )
end

function RegulationFCASReserve{T}(;
        name::AbstractString,
        available::Bool,
        requirement::Float64,
        region::Union{Nothing, PSY.Area} = nothing,
        max_participation_factor::Float64 = 1.0,
        deployed_fraction::Float64 = 0.0,
        ext::Dict{String, Any} = Dict{String, Any}(),
        internal::IS.InfrastructureSystemsInternal = IS.InfrastructureSystemsInternal(),
    ) where {T <: PSY.ReserveDirection}
    return RegulationFCASReserve{T}(
        String(name), available, region, requirement,
        max_participation_factor, deployed_fraction, ext, internal,
    )
end

"""Get [`RegulationFCASReserve`](@ref) `available`."""
PSY.get_available(value::RegulationFCASReserve) = value.available
"""Get [`RegulationFCASReserve`](@ref) `region`."""
get_region(value::RegulationFCASReserve) = value.region
"""Get [`RegulationFCASReserve`](@ref) `requirement`."""
PSY.get_requirement(value::RegulationFCASReserve) = value.requirement
"""Get [`RegulationFCASReserve`](@ref) `max_participation_factor`."""
PSY.get_max_participation_factor(value::RegulationFCASReserve) = value.max_participation_factor
"""Get [`RegulationFCASReserve`](@ref) `deployed_fraction`."""
PSY.get_deployed_fraction(value::RegulationFCASReserve) = value.deployed_fraction
"""Get [`RegulationFCASReserve`](@ref) `ext`."""
PSY.get_ext(value::RegulationFCASReserve) = value.ext

"""Set [`RegulationFCASReserve`](@ref) `available`."""
PSY.set_available!(value::RegulationFCASReserve, val) = value.available = val
"""Set [`RegulationFCASReserve`](@ref) `region`."""
set_region!(value::RegulationFCASReserve, val) = value.region = val
"""Set [`RegulationFCASReserve`](@ref) `requirement`."""
PSY.set_requirement!(value::RegulationFCASReserve, val) = value.requirement = val
"""Set [`RegulationFCASReserve`](@ref) `max_participation_factor`."""
PSY.set_max_participation_factor!(value::RegulationFCASReserve, val) = value.max_participation_factor = val
"""Set [`RegulationFCASReserve`](@ref) `deployed_fraction`."""
PSY.set_deployed_fraction!(value::RegulationFCASReserve, val) = value.deployed_fraction = val
"""Set [`RegulationFCASReserve`](@ref) `ext`."""
PSY.set_ext!(value::RegulationFCASReserve, val) = value.ext = val
