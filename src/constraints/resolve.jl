"""
    _region_devices(sys, region) -> Vector{Device}

A [`RegionTerm`](@ref)'s contributing devices.

# Arguments
- `sys`: the `System` to search.
- `region`: an `Area` name.

# Returns
`Vector{Device}` of every `Generator`/`Storage` in `sys` whose bus's area is named `region`.
"""
function _region_devices(sys, region::AbstractString)
    devices = Device[]
    for d in Iterators.flatten((get_components(Generator, sys), get_components(Storage, sys)))
        get_name(get_area(get_bus(d))) == region && push!(devices, d)
    end
    return devices
end

"""
    resolve_term_devices(sys, term::ConstraintTerm) -> Union{Vector{String}, Nothing}

Resolves a [`ConstraintTerm`](@ref) to the names of the devices it contributes in `sys`. A pure
lookup — never throws, warns, or applies policy.

# Arguments
- `sys`: the `System` to resolve against.
- `term`: a `UnitTerm`, `InterconnectorTerm`, or `RegionTerm`.

# Returns
`nothing` if `term` references something `sys` doesn't have. Otherwise a `Vector{String}` of
device names — a `UnitTerm`/`InterconnectorTerm` resolves to its own name, a `RegionTerm` to
every `Generator`/`Storage` in that region (possibly empty).
"""
function resolve_term_devices(sys, term::UnitTerm)
    device = get_component(Device, sys, get_duid(term))
    return isnothing(device) ? nothing : [get_duid(term)]
end

function resolve_term_devices(sys, term::InterconnectorTerm)
    device = get_component(AreaInterchange, sys, get_interconnector(term))
    return isnothing(device) ? nothing : [get_interconnector(term)]
end

function resolve_term_devices(sys, term::RegionTerm)
    isnothing(get_component(Area, sys, get_region(term))) && return nothing
    return String[get_name(d) for d in _region_devices(sys, get_region(term))]
end
