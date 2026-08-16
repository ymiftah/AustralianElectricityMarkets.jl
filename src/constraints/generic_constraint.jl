"""
A NEM generic constraint: `LHS <sense> RHS`, the mechanism AEMO uses for both network limits
and FCAS requirements — see the design doc for why these are one type, not two. `terms` is
the LHS algebra (from `SPD*`); `governs` is market attribution (from `DISPATCH_FCAS_REQ`) —
empty `governs` means a pure network constraint. `rhs` is a static default
(`GENCONDATA.CONSTRAINTVALUE`); a `"rhs"` `Deterministic` time series attached separately
(see [`add_nem_constraints!`](@ref)) replays `DISPATCHCONSTRAINT.RHS` per interval and is
the value that should be used wherever a real interval's enforced RHS matters, since RHS can
be dynamic (`GENCONDATA.DYNAMICRHS`) or an armed/disarmed variant switch.

`constraint_weight` is `GENCONDATA.GENERICCONSTRAINTWEIGHT` verbatim — a *weight*, not itself
the violation penalty in dollars; a PowerSimulations.jl extension multiplies it by an
AEMC-set base CVP rate.
"""
mutable struct GenericConstraint <: PSY.Component
    name::String
    available::Bool
    sense::ConstraintSense
    rhs::Float64
    constraint_weight::Float64
    terms::Vector{ConstraintTerm}
    governs::Vector{FCASRequirement}
    ext::Dict{String, Any}
    internal::IS.InfrastructureSystemsInternal
end

function GenericConstraint(;
        name::AbstractString,
        available::Bool = true,
        sense::ConstraintSense,
        rhs::Float64,
        constraint_weight::Float64 = 1.0,
        terms::Vector{<:ConstraintTerm} = ConstraintTerm[],
        governs::Vector{FCASRequirement} = FCASRequirement[],
        ext::Dict{String, Any} = Dict{String, Any}(),
        internal::IS.InfrastructureSystemsInternal = IS.InfrastructureSystemsInternal(),
    )
    return GenericConstraint(
        String(name), available, sense, rhs, constraint_weight,
        Vector{ConstraintTerm}(terms), governs, ext, internal,
    )
end

PSY.get_available(value::GenericConstraint) = value.available
PSY.set_available!(value::GenericConstraint, val) = value.available = val
get_sense(value::GenericConstraint) = value.sense
set_sense!(value::GenericConstraint, val) = value.sense = val
get_rhs(value::GenericConstraint) = value.rhs
set_rhs!(value::GenericConstraint, val) = value.rhs = val
get_constraint_weight(value::GenericConstraint) = value.constraint_weight
set_constraint_weight!(value::GenericConstraint, val) = value.constraint_weight = val
get_terms(value::GenericConstraint) = value.terms
set_terms!(value::GenericConstraint, val) = value.terms = val
get_governs(value::GenericConstraint) = value.governs
set_governs!(value::GenericConstraint, val) = value.governs = val
PSY.get_ext(value::GenericConstraint) = value.ext
PSY.set_ext!(value::GenericConstraint, val) = value.ext = val
