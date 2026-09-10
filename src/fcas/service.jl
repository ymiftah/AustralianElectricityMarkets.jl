"""
A `(REGIONID, BIDTYPE)` FCAS market anchor — the `add_service!` join between a region's
market and the devices contributing to it. Carries no requirement or time series of its own;
the regional RHS lives on the governing [`GenericConstraint`](@ref)'s own `"rhs"` series.

# Fields
- `name`: `"<REGIONID>_<BIDTYPE>"`.
- `available`: whether it is enforced.
- `region`: the NEM region.
- `bid_type`: the FCAS market.
- `ext`: unused, reserved.
- `internal`: `InfrastructureSystems` bookkeeping.
"""
mutable struct FCASService <: PSY.Service
    name::String
    available::Bool
    region::String
    bid_type::BidType
    ext::Dict{String, Any}
    internal::IS.InfrastructureSystemsInternal
end

function FCASService(;
        name::AbstractString,
        available::Bool = true,
        region::AbstractString,
        bid_type::BidType,
        ext::Dict{String, Any} = Dict{String, Any}(),
        internal::IS.InfrastructureSystemsInternal = IS.InfrastructureSystemsInternal(),
    )
    return FCASService(String(name), available, String(region), bid_type, ext, internal)
end

PSY.get_available(value::FCASService) = value.available
PSY.set_available!(value::FCASService, val) = value.available = val
PSY.get_ext(value::FCASService) = value.ext
PSY.set_ext!(value::FCASService, val) = value.ext = val
PSY.supports_time_series(::FCASService) = false
get_region(value::FCASService) = value.region
get_bid_type(value::FCASService) = value.bid_type

# A device contributes to a (region, bid_type) market if it carries either direction's curve
# series - a storage device can provide the market while charging or discharging.
function _fcas_service_devices(sys, region::AbstractString, bid_type::BidType)
    inc_name = _fcas_series_name("fcas_curve", bid_type, false)
    dec_name = _fcas_series_name("fcas_curve", bid_type, true)
    return filter(_region_devices(sys, region)) do d
        has_time_series(d, Deterministic, inc_name) || has_time_series(d, Deterministic, dec_name)
    end
end

"""
    add_fcas_services!(sys) -> (added, skipped)

Adds one [`FCASService`](@ref) per `(region, bid_type)` pair governed by some
[`GenericConstraint`](@ref) already in `sys` (via its `fcas_requirements`), attached via
`add_service!` to every region device carrying an incremental or decremental FCAS bid series
for that market.

# Arguments
- `sys`: the `System` to add to, after `set_fcas_bids!` and `add_nem_constraints!` have run.

# Returns
`(added, skipped)`: `added::Vector{String}` of service names created, `skipped::Dict{String,
Symbol}` mapping a skipped `"<REGIONID>_<BIDTYPE>"` name to `:no_devices`.
"""
function add_fcas_services!(sys)
    pairs = Set{Tuple{String, BidType}}()
    for gc in get_components(GenericConstraint, sys)
        get_available(gc) || continue
        for req in get_fcas_requirements(gc)
            push!(pairs, (get_region(req), get_service(req)))
        end
    end

    added = String[]
    skipped = Dict{String, Symbol}()
    for (region, bid_type) in pairs
        name = "$(region)_$(string(bid_type))"
        devices = _fcas_service_devices(sys, region, bid_type)
        if isempty(devices)
            skipped[name] = :no_devices
            continue
        end
        add_service!(sys, FCASService(; name = name, region = region, bid_type = bid_type), devices)
        push!(added, name)
    end

    if !isempty(skipped)
        @warn "add_fcas_services!: skipped $(length(skipped)) of $(length(pairs)) (region, bid_type) pairs with no contributing devices" skipped
    end

    return added, skipped
end
