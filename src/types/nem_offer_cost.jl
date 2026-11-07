# Keys are compared field by field: a key's `features` is a `Dict`, which `===` would compare by
# identity.
function _keys_equal(a, b)
    a === b && return true
    (a isa IS.TimeSeriesKey && b isa IS.TimeSeriesKey && typeof(a) == typeof(b)) || return false
    return all(getfield(a, f) == getfield(b, f) for f in fieldnames(typeof(a)))
end

# Compares two bid fields: keys by value, and a key only with a key of the same type.
function _field_equal(a, b)
    (a isa IS.TimeSeriesKey || b isa IS.TimeSeriesKey) && return typeof(a) == typeof(b) && _keys_equal(a, b)
    return a == b
end


"""
    FastStartProfile

The fast-start inflexibility profile `T1`-`T4` in minutes, as a named tuple of four `Float64`.
"""
const FastStartProfile = NamedTuple{(:t1, :t2, :t3, :t4), NTuple{4, Float64}}


"""
    FCASTrapeziumPoints

An FCAS trapezium's MW breakpoints `ENABLEMENTMIN`, `LOWBREAKPOINT`, `HIGHBREAKPOINT` and
`ENABLEMENTMAX`, as a named tuple of four `Float64`.
"""
const FCASTrapeziumPoints = NamedTuple{
    (:enablement_min, :low_breakpoint, :high_breakpoint, :enablement_max), NTuple{4, Float64},
}


"""
    NEMEnergyBid(; direction, offer_curves, max_avail, roc_up, roc_down, fixed_load = nothing,
        minimum_load = nothing, fast_start_profile = nothing, daily_energy_constraint = nothing,
        normal_status = nothing, energy_limit = nothing)

One side of a unit's energy offer as AEMO bid it: each field is a static value or a key of the
time series that holds it on the unit, or `nothing` where AEMO publishes no value.

# Fields
- `direction`: the [`BidDirection`](@ref), `GEN` or `LOAD`.
- `offer_curves`: the ten price bands, in MW and \$/MWh at the connection point, as
  `PiecewiseStepData`.
- `max_avail`: `MAXAVAIL`, MW.
- `roc_up`, `roc_down`: `ROCUP` and `ROCDOWN`, MW/min.
- `fixed_load`: `FIXEDLOAD`, MW.
- `minimum_load`: `MINIMUMLOAD`, MW.
- `fast_start_profile`: `T1` to `T4`, as a [`FastStartProfile`](@ref), in minutes.
- `daily_energy_constraint`: `DAILYENERGYCONSTRAINT`, MWh.
- `normal_status`: `NORMALSTATUS`, `true` for `ON`.
- `energy_limit`: `ENERGYLIMIT`, MWh.
"""
struct NEMEnergyBid <: PSY.DeviceParameter
    direction::BidDirection
    offer_curves::Union{IS.TimeSeriesKey, PiecewiseStepData}
    max_avail::Union{IS.TimeSeriesKey, Float64}
    roc_up::Union{IS.TimeSeriesKey, Float64}
    roc_down::Union{IS.TimeSeriesKey, Float64}
    fixed_load::Union{Nothing, IS.TimeSeriesKey, Float64}
    minimum_load::Union{Nothing, IS.TimeSeriesKey, Float64}
    fast_start_profile::Union{Nothing, IS.TimeSeriesKey, FastStartProfile}
    daily_energy_constraint::Union{Nothing, IS.TimeSeriesKey, Float64}
    normal_status::Union{Nothing, IS.TimeSeriesKey, Bool}
    energy_limit::Union{Nothing, IS.TimeSeriesKey, Float64}
end

function NEMEnergyBid(;
        direction::BidDirection, offer_curves, max_avail, roc_up, roc_down,
        fixed_load = nothing, minimum_load = nothing, fast_start_profile = nothing,
        daily_energy_constraint = nothing, normal_status = nothing, energy_limit = nothing,
    )
    f = _bid_number
    return NEMEnergyBid(
        direction, offer_curves, f(max_avail), f(roc_up), f(roc_down), f(fixed_load), f(minimum_load),
        fast_start_profile, f(daily_energy_constraint), normal_status, f(energy_limit),
    )
end

# A static numeric bid value as `Float64` (JSON reads `0.0` back as an integer); any other value as is.
_bid_number(x::Real) = Float64(x)
_bid_number(x) = x

function Base.:(==)(a::NEMEnergyBid, b::NEMEnergyBid)
    return all(f -> _field_equal(getfield(a, f), getfield(b, f)), fieldnames(NEMEnergyBid))
end


"""
    NEMFCASBid(; service, direction, offer_curves, max_avail, trapezium)

One direction of a unit's offer for one FCAS market, as AEMO bid it.

# Fields
- `service`: the FCAS [`BidType`](@ref).
- `direction`: the [`BidDirection`](@ref), `GEN`, `LOAD` or `BIDIRECTIONAL`.
- `offer_curves`: the ten price bands, in MW and \$/MW, as `PiecewiseStepData`.
- `max_avail`: `MAXAVAIL`, MW.
- `trapezium`: the [`FCASTrapeziumPoints`](@ref) of the bid, MW.
"""
struct NEMFCASBid <: PSY.DeviceParameter
    service::BidType
    direction::BidDirection
    offer_curves::Union{IS.TimeSeriesKey, PiecewiseStepData}
    max_avail::Union{IS.TimeSeriesKey, Float64}
    trapezium::Union{IS.TimeSeriesKey, FCASTrapeziumPoints}
end

function NEMFCASBid(;
        service::BidType, direction::BidDirection, offer_curves, max_avail, trapezium,
    )
    return NEMFCASBid(service, direction, offer_curves, _bid_number(max_avail), trapezium)
end

function Base.:(==)(a::NEMFCASBid, b::NEMFCASBid)
    return all(f -> _field_equal(getfield(a, f), getfield(b, f)), fieldnames(NEMFCASBid))
end


"""
    NEMOfferCost(; energy = NEMEnergyBid[], fcas = NEMFCASBid[])

The operation cost of a NEM unit: the bids it makes, as AEMO bid them. `NEMOfferCost()` is the offer
of a unit that bids nothing.

# Fields
- `energy`: at most one [`NEMEnergyBid`](@ref) per direction.
- `fcas`: at most one [`NEMFCASBid`](@ref) per `(service, direction)`.
"""
mutable struct NEMOfferCost <: PSY.OperationalCost
    energy::Vector{NEMEnergyBid}
    fcas::Vector{NEMFCASBid}
end

function NEMOfferCost(;
        energy::AbstractVector{NEMEnergyBid} = NEMEnergyBid[],
        fcas::AbstractVector{NEMFCASBid} = NEMFCASBid[],
    )
    return NEMOfferCost(Vector{NEMEnergyBid}(energy), Vector{NEMFCASBid}(fcas))
end

function Base.:(==)(a::NEMOfferCost, b::NEMOfferCost)
    return a.energy == b.energy && a.fcas == b.fcas
end

"""
    get_energy_bids(cost::NEMOfferCost) -> Vector{NEMEnergyBid}

The energy bids of `cost`, at most one per direction.
"""
get_energy_bids(cost::NEMOfferCost) = cost.energy

"""
    get_fcas_bids(cost::NEMOfferCost) -> Vector{NEMFCASBid}

The FCAS bids of `cost`, at most one per `(service, direction)`.
"""
get_fcas_bids(cost::NEMOfferCost) = cost.fcas

get_direction(bid::Union{NEMEnergyBid, NEMFCASBid}) = bid.direction
get_offer_curves(bid::Union{NEMEnergyBid, NEMFCASBid}) = bid.offer_curves
get_max_avail(bid::Union{NEMEnergyBid, NEMFCASBid}) = bid.max_avail
get_roc_up(bid::NEMEnergyBid) = bid.roc_up
get_roc_down(bid::NEMEnergyBid) = bid.roc_down
get_fixed_load(bid::NEMEnergyBid) = bid.fixed_load
get_minimum_load(bid::NEMEnergyBid) = bid.minimum_load
get_fast_start_profile(bid::NEMEnergyBid) = bid.fast_start_profile
get_daily_energy_constraint(bid::NEMEnergyBid) = bid.daily_energy_constraint
get_normal_status(bid::NEMEnergyBid) = bid.normal_status
get_energy_limit(bid::NEMEnergyBid) = bid.energy_limit
get_service(bid::NEMFCASBid) = bid.service
get_trapezium(bid::NEMFCASBid) = bid.trapezium

# The side of the energy offer a bid direction is on: `LOAD` for load, `GEN` otherwise.
_energy_offer_side(direction::BidDirection) = direction == BidDirection.LOAD ? OfferSide.LOAD : OfferSide.GEN

# Replaces the entry of the same direction, or appends one.
function _set_energy_bid!(cost::NEMOfferCost, bid::NEMEnergyBid)
    i = findfirst(b -> b.direction == bid.direction, cost.energy)
    isnothing(i) ? push!(cost.energy, bid) : (cost.energy[i] = bid)
    return
end

# Replaces the entry of the same service and direction, or appends one.
function _set_fcas_bid!(cost::NEMOfferCost, bid::NEMFCASBid)
    i = findfirst(b -> b.service == bid.service && b.direction == bid.direction, cost.fcas)
    isnothing(i) ? push!(cost.fcas, bid) : (cost.fcas[i] = bid)
    return
end

# IS dispatches an array field on its declared type, so each element is resolved from its own
# metadata (see `ConstraintTerm`).
IS.deserialize(::Type{Vector{NEMEnergyBid}}, data::Vector) =
    NEMEnergyBid[_deserialize_device_parameter(d) for d in data]

IS.deserialize(::Type{Vector{NEMFCASBid}}, data::Vector) =
    NEMFCASBid[_deserialize_device_parameter(d) for d in data]
