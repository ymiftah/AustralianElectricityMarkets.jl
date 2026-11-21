"""
    _fcas_system_base(component) -> Float64

The system base power, in MVA, that `component`'s FCAS offer curves are divided by on read. Throws
`ArgumentError` if `component` is not attached to a `System`.
"""
function _fcas_system_base(component)
    info = IS.get_internal(component).units_info
    isnothing(info) && throw(
        ArgumentError(
            "\"$(get_name(component))\" is not attached to a System, so its FCAS offer curves " *
                "have no system base to convert from.",
        ),
    )
    return Float64(info.base_value)
end


function _read_fcas_series(kind::AbstractString, component, name::AbstractString, service::BidType, decremental::Bool, initial_time, horizon::Integer)
    if !has_time_series(component, SingleTimeSeries, name)
        throw(
            ArgumentError(
                "No FCAS $kind series \"$name\" attached to component \"$(get_name(component))\" " *
                    "for service $(string(service))" * (decremental ? " (decremental)" : "") *
                    "; call set_market_bids! first.",
            ),
        )
    end
    return get_time_series_values(SingleTimeSeries, component, name; start_time = initial_time, len = horizon)
end


"""
    _fcas_offer_key(component, service::BidType, side::OfferSide) -> Union{Nothing, IS.StaticTimeSeriesKey}

The key of the offer curve series of `component`'s FCAS bid for `service` on `side`, the `offer_curves`
field of its [`NEMFCASBid`](@ref), or `nothing` when `component` bids no such FCAS bid or has no
`FCASService` for `service`. Throws `ArgumentError` when that field is static rather than series-backed.

# Returns
`Union{Nothing, IS.StaticTimeSeriesKey}`.
"""
function _fcas_offer_key(component, service::BidType, side::OfferSide)
    cost = _nem_offer_cost(component)
    isnothing(cost) && return nothing
    isempty(_fcas_services(component, service)) && return nothing
    bids = get_fcas_bids(cost)
    i = findfirst(b -> b.service == service && _fcas_bid_side(component, b) == side, bids)
    isnothing(i) && return nothing
    offer = bids[i].offer_curves
    offer isa IS.StaticTimeSeriesKey || throw(
        ArgumentError(
            "\"$(get_name(component))\" has a static `offer_curves` field for $(string(service)); FCAS offers need a series-backed bid.",
        ),
    )
    return offer
end


"""
    _fcas_offer_series_name(component, service::BidType, decremental::Bool) -> String

Name of the series [`_fcas_offer_key`](@ref) keys for `component`'s FCAS offer curve, `decremental`
selecting the load side. Throws `ArgumentError` when that key is absent.

# Returns
`String`.
"""
function _fcas_offer_series_name(component, service::BidType, decremental::Bool)
    key = _fcas_offer_key(component, service, offer_side(decremental))
    isnothing(key) && throw(
        ArgumentError(
            "\"$(get_name(component))\" has no FCAS offer curve for $(string(service))" *
                (decremental ? " (decremental)" : "") * "; call set_market_bids! first.",
        ),
    )
    return IS.get_name(key)
end
