# Keys are compared field by field: a key's `features` is a `Dict`, which `===` would compare by
# identity.
function _keys_equal(a, b)
    a === b && return true
    (a isa IS.TimeSeriesKey && b isa IS.TimeSeriesKey && typeof(a) == typeof(b)) || return false
    return all(getfield(a, f) == getfield(b, f) for f in fieldnames(typeof(a)))
end


"""
    NEMEnergyBid(side, curves, max_avail)

One side of a unit's energy offer, held as keys of the time series on the unit.

# Fields
- `side`: the [`OfferSide`](@ref) the bid is on.
- `curves`: key of the `PiecewiseStepData` series, natural units, loss-factor referred prices.
- `max_avail`: key of the `MAXAVAIL` series, per-unit of the system base.
"""
struct NEMEnergyBid <: PSY.DeviceParameter
    side::OfferSide
    curves::IS.TimeSeriesKey
    max_avail::IS.TimeSeriesKey
end

function NEMEnergyBid(; side::OfferSide, curves::IS.TimeSeriesKey, max_avail::IS.TimeSeriesKey)
    return NEMEnergyBid(side, curves, max_avail)
end

function Base.:(==)(a::NEMEnergyBid, b::NEMEnergyBid)
    return a.side == b.side && _keys_equal(a.curves, b.curves) && _keys_equal(a.max_avail, b.max_avail)
end


"""
    NEMFCASBid(service, side, curves, trapezium)

One side of a unit's offer for one FCAS service, held as keys of the time series on the unit.

# Fields
- `service`: the FCAS [`BidType`](@ref).
- `side`: the [`OfferSide`](@ref) the bid is on.
- `curves`: key of the `PiecewiseStepData` series, natural units.
- `trapezium`: key of the raw bid trapezium series.
"""
struct NEMFCASBid <: PSY.DeviceParameter
    service::BidType
    side::OfferSide
    curves::IS.TimeSeriesKey
    trapezium::IS.TimeSeriesKey
end

function NEMFCASBid(;
        service::BidType, side::OfferSide, curves::IS.TimeSeriesKey, trapezium::IS.TimeSeriesKey,
    )
    return NEMFCASBid(service, side, curves, trapezium)
end

function Base.:(==)(a::NEMFCASBid, b::NEMFCASBid)
    return a.service == b.service && a.side == b.side && _keys_equal(a.curves, b.curves) &&
        _keys_equal(a.trapezium, b.trapezium)
end


"""
    NEMOfferCost(; energy, fcas, fixed_load, fixed_load_invoked)

The operation cost of a NEM unit: the keys of its offer series, in place of a `MarketBidCost`.
`NEMOfferCost()` is the offer of a unit that bids nothing.

# Fields
- `energy`: at most one [`NEMEnergyBid`](@ref) per side.
- `fcas`: at most one [`NEMFCASBid`](@ref) per `(service, side)`.
- `fixed_load`: key of the net fixed-load target series, or `nothing`.
- `fixed_load_invoked`: key of the fixed-load invocation series, or `nothing`.
"""
mutable struct NEMOfferCost <: PSY.OperationalCost
    energy::Vector{NEMEnergyBid}
    fcas::Vector{NEMFCASBid}
    fixed_load::Union{Nothing, IS.TimeSeriesKey}
    fixed_load_invoked::Union{Nothing, IS.TimeSeriesKey}
end

function NEMOfferCost(;
        energy::AbstractVector{NEMEnergyBid} = NEMEnergyBid[],
        fcas::AbstractVector{NEMFCASBid} = NEMFCASBid[],
        fixed_load::Union{Nothing, IS.TimeSeriesKey} = nothing,
        fixed_load_invoked::Union{Nothing, IS.TimeSeriesKey} = nothing,
    )
    return NEMOfferCost(Vector{NEMEnergyBid}(energy), Vector{NEMFCASBid}(fcas), fixed_load, fixed_load_invoked)
end

function Base.:(==)(a::NEMOfferCost, b::NEMOfferCost)
    return a.energy == b.energy && a.fcas == b.fcas && _keys_equal(a.fixed_load, b.fixed_load) &&
        _keys_equal(a.fixed_load_invoked, b.fixed_load_invoked)
end

"""
    get_energy_bids(cost::NEMOfferCost) -> Vector{NEMEnergyBid}

The energy bids of `cost`, at most one per side.
"""
get_energy_bids(cost::NEMOfferCost) = cost.energy

"""
    get_fcas_bids(cost::NEMOfferCost) -> Vector{NEMFCASBid}

The FCAS bids of `cost`, at most one per `(service, side)`.
"""
get_fcas_bids(cost::NEMOfferCost) = cost.fcas

"""
    get_fixed_load(cost::NEMOfferCost) -> Union{Nothing, IS.TimeSeriesKey}

The key of the net fixed-load target series, or `nothing`.
"""
get_fixed_load(cost::NEMOfferCost) = cost.fixed_load

"""
    get_fixed_load_invoked(cost::NEMOfferCost) -> Union{Nothing, IS.TimeSeriesKey}

The key of the fixed-load invocation series, or `nothing`.
"""
get_fixed_load_invoked(cost::NEMOfferCost) = cost.fixed_load_invoked

# Replaces the entry of the same side, or appends one.
function _set_energy_bid!(cost::NEMOfferCost, bid::NEMEnergyBid)
    i = findfirst(b -> b.side == bid.side, cost.energy)
    isnothing(i) ? push!(cost.energy, bid) : (cost.energy[i] = bid)
    return
end

# Replaces the entry of the same service and side, or appends one.
function _set_fcas_bid!(cost::NEMOfferCost, bid::NEMFCASBid)
    i = findfirst(b -> b.service == bid.service && b.side == bid.side, cost.fcas)
    isnothing(i) ? push!(cost.fcas, bid) : (cost.fcas[i] = bid)
    return
end

# IS dispatches an array field on its declared type, so each element is resolved from its own
# metadata (see `ConstraintTerm`).
IS.deserialize(::Type{Vector{NEMEnergyBid}}, data::Vector) =
    NEMEnergyBid[_deserialize_device_parameter(d) for d in data]

IS.deserialize(::Type{Vector{NEMFCASBid}}, data::Vector) =
    NEMFCASBid[_deserialize_device_parameter(d) for d in data]
