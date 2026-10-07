"Whether `load` carries a decremental FCAS trapezium series for any FCAS market."
_offers_fcas(load) = any(
    bt -> has_time_series(load, Deterministic, "fcas_trapezium_$(string(bt))_decremental"), FCAS_BID_TYPES,
)

"""
    _region_devices(sys, region; loads = false) -> Vector{Device}

A [`RegionTerm`](@ref)'s contributing devices.

# Arguments
- `sys`: the `System` to search.
- `region`: an `Area` name.
- `loads`: also include the region's `InterruptiblePowerLoad`s that carry an FCAS bid series
  ([`set_fcas_bids!`](@ref) must have run); loads are not part of a region's energy aggregate.

# Returns
`Vector{Device}` of every `Generator`/`Storage` (and, with `loads`, `InterruptiblePowerLoad`) in
`sys` whose bus's area is named `region`.
"""
function _region_devices(sys, region::AbstractString; loads::Bool = false)
    devices = Device[]
    sources = (get_components(Generator, sys), get_components(Storage, sys))
    loads && (sources = (sources..., get_components(_offers_fcas, InterruptiblePowerLoad, sys)))
    for d in Iterators.flatten(sources)
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
every `Generator`/`Storage` in that region (possibly empty), plus every `InterruptiblePowerLoad`
when the term is an FCAS term.
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
    loads = get_bid_type(term) != BidType.ENERGY
    return String[get_name(d) for d in _region_devices(sys, get_region(term); loads = loads)]
end
