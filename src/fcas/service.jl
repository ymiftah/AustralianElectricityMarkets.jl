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

"""
    fcas_service_name(region, bid_type) -> String
    fcas_service_name(device, bid_type) -> String

The name `"<REGIONID>_<BIDTYPE>"` of the [`FCASService`](@ref) for `bid_type` in `region`, or in the
area of `device`'s own bus.

# Arguments
- `region`: an `Area` name.
- `device`: a device attached to a bus in an `Area`.
- `bid_type`: the FCAS market.

# Returns
A `String`.
"""
fcas_service_name(region::AbstractString, bid_type::BidType) = "$(region)_$(string(bid_type))"
function fcas_service_name(device::Device, bid_type::BidType)
    return fcas_service_name(get_name(get_area(get_bus(device))), bid_type)
end

"""
    _fcas_bid_direction(device, bid_type) -> Symbol

`:incremental`, `:decremental`, `:both` or `:none`, describing which `"fcas_trapezium_<bid_type>
[_decremental]"` series `device` carries.
"""
function _fcas_bid_direction(device, bid_type::BidType)
    bid_type_str = string(bid_type)
    has_inc = has_time_series(device, Deterministic, "fcas_trapezium_$bid_type_str")
    has_dec = has_time_series(device, Deterministic, "fcas_trapezium_$(bid_type_str)_decremental")
    has_inc && has_dec && return :both
    has_inc && return :incremental
    has_dec && return :decremental
    return :none
end

"""
    _fcas_bid_modeled(device, bid_type) -> Bool

Whether `device`'s `bid_type` FCAS bid has a direction the FCAS market formulation models: an
incremental bid on any device but a load, a decremental-only bid on a `Storage` device or an
`InterruptiblePowerLoad`, or a `Storage` device's regulation bid on both sides.
"""
function _fcas_bid_modeled(device, bid_type::BidType)
    direction = _fcas_bid_direction(device, bid_type)
    direction == :incremental && return !(device isa InterruptiblePowerLoad)
    direction == :decremental && return device isa Storage || device isa InterruptiblePowerLoad
    direction == :both && return device isa Storage && bid_type in FCAS_REGULATION_MARKETS
    return false
end

# A device bids a (region, bid_type) market if it carries either direction's curve series - a
# storage device can provide the market while charging or discharging.
function _fcas_service_devices(sys, region::AbstractString, bid_type::BidType)
    inc_name = _fcas_series_name("fcas_curve", bid_type, false)
    dec_name = _fcas_series_name("fcas_curve", bid_type, true)
    return filter(_region_devices(sys, region; loads = true)) do d
        has_time_series(d, Deterministic, inc_name) || has_time_series(d, Deterministic, dec_name)
    end
end

"""
    add_fcas_services!(sys) -> (added, excluded)

Adds one [`FCASService`](@ref) named `"<REGIONID>_<BIDTYPE>"` for every region and FCAS market
with at least one available device bidding it, attached via `add_service!` to those devices
whose bid direction the FCAS market formulation models (an incremental bid, a decremental-only
bid on a `Storage` device or a load, or a `Storage` device's regulation bid on both sides). A
service already in `sys` under that name is left as is. Devices bidding a market in a direction the formulation does not model are left out and
reported.

# Arguments
- `sys`: the `System` to add to, after [`set_fcas_bids!`](@ref) has run.

# Returns
`(added, excluded)`: `added::Vector{String}` of service names created, and
`excluded::Dict{String, Vector{String}}` mapping a service name to the device names left out of
it.
"""
function add_fcas_services!(sys)
    added = String[]
    excluded = Dict{String, Vector{String}}()
    for region in sort(get_name.(get_components(Area, sys))), bid_type in FCAS_BID_TYPES
        name = fcas_service_name(region, bid_type)
        isnothing(get_component(FCASService, sys, name)) || continue
        bidders = filter(get_available, _fcas_service_devices(sys, region, bid_type))
        devices = filter(d -> _fcas_bid_modeled(d, bid_type), bidders)
        left_out = setdiff(get_name.(bidders), get_name.(devices))
        isempty(left_out) || (excluded[name] = sort(left_out))
        isempty(devices) && continue
        add_service!(sys, FCASService(; name = name, region = region, bid_type = bid_type), devices)
        push!(added, name)
    end
    if !isempty(excluded)
        @warn "add_fcas_services!: left $(sum(length, values(excluded))) device(s) out of $(length(excluded)) FCAS market(s) - their bid direction is not modeled" excluded
    end
    return added, excluded
end
