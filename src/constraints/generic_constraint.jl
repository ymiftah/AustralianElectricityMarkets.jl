"""
A NEM generic constraint, `LHS <sense> RHS` — the mechanism AEMO uses for both network limits
and FCAS requirements. Attached to its contributing devices as a `PSY.Service`.

# Fields
- `name`: the constraint's identifier.
- `available`: whether it is enforced.
- `sense`: `LE`, `GE` or `EQ`, from `GENCONDATA.CONSTRAINTTYPE`.
- `rhs`: static default from `GENCONDATA.CONSTRAINTVALUE`. The `"rhs"` `Deterministic` series
  attached by [`add_nem_constraints!`](@ref) is the per-interval value NEMDE enforced, and is
  what should be used wherever a real interval's RHS matters.
- `constraint_weight`: `GENCONDATA.GENERICCONSTRAINTWEIGHT` verbatim — a weight, not a dollar
  penalty. A `PowerSimulations.jl` extension multiplies it by an AEMC-set base CVP rate.
- `description`: human-readable, defaults to `""`.
- `terms`: the LHS algebra, from the `SPD*` tables.
- `fcas_requirements`: the `(region, service)` prices this constraint governs, from
  `DISPATCH_FCAS_REQ`. Empty for a pure network constraint.
- `ext`: AEMO provenance from `GENCONDATA` — `limit_type`, `source`, `effective_date`,
  `version_no`, read through [`get_limit_type`](@ref)/[`get_source`](@ref)/
  [`get_effective_date`](@ref)/[`get_version_no`](@ref).
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
set_sense!(value::GenericConstraint, val) = value.sense = val
get_rhs(value::GenericConstraint) = value.rhs
set_rhs!(value::GenericConstraint, val) = value.rhs = val
get_constraint_weight(value::GenericConstraint) = value.constraint_weight
set_constraint_weight!(value::GenericConstraint, val) = value.constraint_weight = val
PSY.get_description(value::GenericConstraint) = value.description
PSY.set_description!(value::GenericConstraint, val) = value.description = val
get_terms(value::GenericConstraint) = value.terms
set_terms!(value::GenericConstraint, val) = value.terms = val
get_fcas_requirements(value::GenericConstraint) = value.fcas_requirements
set_fcas_requirements!(value::GenericConstraint, val) = value.fcas_requirements = val
PSY.get_ext(value::GenericConstraint) = value.ext
PSY.set_ext!(value::GenericConstraint, val) = value.ext = val

"""
    get_limit_type(value::GenericConstraint) -> Union{String, Nothing}

`GENCONDATA.LIMITTYPE`, or `nothing` if absent.
"""
get_limit_type(value::GenericConstraint) = get(value.ext, "limit_type", nothing)

"""
    get_source(value::GenericConstraint) -> Union{String, Nothing}

`GENCONDATA.SOURCE`, or `nothing` if absent.
"""
get_source(value::GenericConstraint) = get(value.ext, "source", nothing)

"""
    get_effective_date(value::GenericConstraint) -> Union{String, Nothing}

`GENCONDATA.EFFECTIVEDATE`, or `nothing` if absent.
"""
get_effective_date(value::GenericConstraint) = get(value.ext, "effective_date", nothing)

"""
    get_version_no(value::GenericConstraint) -> Union{Int, Nothing}

`GENCONDATA.VERSIONNO`, or `nothing` if absent.
"""
get_version_no(value::GenericConstraint) = get(value.ext, "version_no", nothing)
