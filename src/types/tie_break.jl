"""
    EnergyTieBreak(; name, available = true, ext = Dict{String, Any}(), internal = InfrastructureSystemsInternal())

The anchor of the energy tie-break rows: the `add_service!` join between the tie-break and the units
whose price-tied energy bands it dispatches pro rata. Carries no time series of its own; each unit's
band scales live on the unit.

# Fields
- `name`: the service name.
- `available`: whether it is enforced.
- `ext`: unused, reserved.
- `internal`: `InfrastructureSystems` bookkeeping.
"""
mutable struct EnergyTieBreak <: PSY.Service
    name::String
    available::Bool
    ext::Dict{String, Any}
    internal::IS.InfrastructureSystemsInternal
end


function EnergyTieBreak(;
        name::AbstractString,
        available::Bool = true,
        ext::Dict{String, Any} = Dict{String, Any}(),
        internal::IS.InfrastructureSystemsInternal = IS.InfrastructureSystemsInternal(),
    )
    return EnergyTieBreak(String(name), available, ext, internal)
end


PSY.get_available(value::EnergyTieBreak) = value.available

PSY.set_available!(value::EnergyTieBreak, val) = value.available = val

PSY.get_ext(value::EnergyTieBreak) = value.ext

PSY.set_ext!(value::EnergyTieBreak, val) = value.ext = val

PSY.supports_time_series(::EnergyTieBreak) = false


"""
    TIE_BREAK_CVP_FACTOR

Constraint violation penalty factor (1e-6) of AEMO's tie-break constraint (`TBSlack1` and
`TBSlack2`, item 53 of the *Schedule of Constraint Violation Penalty Factors* v8.0). It is also
the price tolerance, in `\$/MWh` after loss-factor adjustment, within which two energy bands are
price-tied.
"""
const TIE_BREAK_CVP_FACTOR = 1.0e-6


"""
    TIE_BREAK_SERVICE_NAME

Name of the [`EnergyTieBreak`](@ref) service that the replay derivation (`set_effective_offers!` in AEMSim) attaches, and of the
tie-break service model that the NEM dispatch model set registers for it.
"""
const TIE_BREAK_SERVICE_NAME = "energy_tie_break"
