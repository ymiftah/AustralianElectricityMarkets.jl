function _require_fcas_float(row, ::Val{field}) where {field}
    value = getproperty(row, field)
    ismissing(value) && throw(
        ArgumentError(
            "BIDPEROFFER_D.$field is missing for DUID $(row.DUID) - cannot build an " *
                "FCASTrapezium without it.",
        ),
    )
    return Float64(value)
end


IS.@scoped_enum(FCASBidDirection, NONE = 0, INCREMENTAL = 1, DECREMENTAL = 2, BOTH = 3)


@doc """
    FCASBidDirection

Which sides of an FCAS bid a device carries: `NONE`, `INCREMENTAL` (generation side),
`DECREMENTAL` (load side) or `BOTH`. Returned by [`fcas_bid_direction`](@ref).
""" FCASBidDirection


"""
    fcas_bid_direction(device, bid_type) -> FCASBidDirection

Which sides of a `bid_type` FCAS bid `device` carries, read from the [`NEMFCASBid`](@ref)s of its
[`NEMOfferCost`](@ref).

# Arguments
- `device`: any component.
- `bid_type`: the FCAS [`BidType`](@ref).

# Returns
An [`FCASBidDirection`](@ref).
"""
function fcas_bid_direction(device, bid_type::BidType)
    cost = _nem_offer_cost(device)
    isnothing(cost) && return FCASBidDirection.NONE
    sides = Set{OfferSide}()
    for bid in get_fcas_bids(cost)
        bid.service == bid_type || continue
        side = _fcas_bid_side(device, bid)
        isnothing(side) || push!(sides, side)
    end
    has_inc, has_dec = OfferSide.GEN in sides, OfferSide.LOAD in sides
    has_inc && has_dec && return FCASBidDirection.BOTH
    has_inc && return FCASBidDirection.INCREMENTAL
    has_dec && return FCASBidDirection.DECREMENTAL
    return FCASBidDirection.NONE
end


"""
    _fcas_bid_side(device, bid::NEMFCASBid) -> Union{Nothing, OfferSide}

The side of `device`'s FCAS `bid` that the formulation models: a `LOAD` bid is the load side of a
storage device or a controllable load, and a `GEN` or `BIDIRECTIONAL` bid is the generation side of a
generator or a storage device. `nothing` for a bid the formulation does not model (a generator's
`LOAD` bid, a controllable load's `GEN` or `BIDIRECTIONAL` bid).
"""
function _fcas_bid_side(device, bid::NEMFCASBid)
    if bid.direction == BidDirection.LOAD
        return device isa PSY.ControllableLoad || device isa PSY.Storage ? OfferSide.LOAD : nothing
    end
    return device isa PSY.ControllableLoad ? nothing : OfferSide.GEN
end


"""
    _fcas_bid_modeled(device, bid_type) -> Bool

Whether `device`'s `bid_type` FCAS bid has a direction the FCAS market formulation models: an
incremental bid on any device but a load, a decremental-only bid on a `Storage` device or an
`ControllableLoad`, or a `Storage` device's regulation bid on both sides.
"""
function _fcas_bid_modeled(device, bid_type::BidType)
    direction = fcas_bid_direction(device, bid_type)
    direction == FCASBidDirection.INCREMENTAL && return !(device isa ControllableLoad)
    direction == FCASBidDirection.DECREMENTAL && return device isa Storage || device isa ControllableLoad
    direction == FCASBidDirection.BOTH && return device isa Storage && bid_type in FCAS_REGULATION_MARKETS
    return false
end


"""
    add_fcas_services!(sys; bid_types = FCAS_BID_TYPES) -> (added, excluded)

Adds one [`FCASService`](@ref) named `"<REGIONID>_<BIDTYPE>"` for every region and FCAS market in
`bid_types` with at least one available device bidding it, attached via `add_service!` to those devices
whose bid direction the FCAS market formulation models (an incremental bid, a decremental-only
bid on a `Storage` device or a load, or a `Storage` device's regulation bid on both sides). The bids
are the [`NEMFCASBid`](@ref)s stored by [`set_market_bids!`](@ref). A service already in `sys` under
that name is left as is. Devices bidding a market in a direction the formulation does not model are
left out and reported.

# Arguments
- `sys`: the `System` to add to, holding the FCAS bids of its devices.
- `bid_types`: the FCAS markets to add services for.

# Returns
`(added, excluded)`: `added::Vector{String}` of service names created, and
`excluded::Dict{String, Vector{String}}` mapping a service name to the device names left out of
it.
"""
function add_fcas_services!(sys; bid_types = FCAS_BID_TYPES)
    added = String[]
    excluded = Dict{String, Vector{String}}()
    for region in sort(get_name.(get_components(Area, sys)))
        candidates = _region_devices(sys, region; loads = true)
        for bid_type in bid_types
            name = fcas_service_name(region, bid_type)
            isnothing(get_component(FCASService, sys, name)) || continue
            # A device bids a market if it carries an FCAS bid on a side the formulation models.
            bidders = filter(d -> get_available(d) && fcas_bid_direction(d, bid_type) != FCASBidDirection.NONE, candidates)
            devices = filter(d -> _fcas_bid_modeled(d, bid_type), bidders)
            left_out = setdiff(get_name.(bidders), get_name.(devices))
            isempty(left_out) || (excluded[name] = sort(left_out))
            isempty(devices) && continue
            _add_nem_service!(sys, FCASService(; name = name, region = region, bid_type = bid_type), devices)
            push!(added, name)
        end
    end
    if !isempty(excluded)
        @warn "add_fcas_services!: left $(sum(length, values(excluded))) device(s) out of $(length(excluded)) FCAS market(s) - their bid direction is not modeled" excluded
    end
    return added, excluded
end
