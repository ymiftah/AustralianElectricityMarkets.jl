"""
    NEMEnergyOffer

One side of a unit's energy offer, as attached by [`set_market_bids!`](@ref): its price-band curves
over the offer's timestamps, or a single fixed curve.

# Fields
- `side::OfferSide`: the offer side.
- `timestamps::Union{Nothing, Vector{DateTime}}`: one per curve; `nothing` for a fixed curve.
- `resolution::Union{Nothing, Dates.Period}`: the spacing of `timestamps`; `nothing` for a fixed curve.
- `curves::Vector{PiecewiseStepData}`: the offer curves, as stored on the operation cost.
"""
struct NEMEnergyOffer
    side::OfferSide
    timestamps::Union{Nothing, Vector{DateTime}}
    resolution::Union{Nothing, Dates.Period}
    curves::Vector{PiecewiseStepData}
end


"""
    get_energy_offer(device, side::OfferSide) -> Union{Nothing, NEMEnergyOffer}

`device`'s energy offer on `side` from its `MarketBidCost`: the incremental curves for `GEN` and
the decremental curves for `LOAD`.

# Returns
A [`NEMEnergyOffer`](@ref), or `nothing` when `device` has no `MarketBidCost` or no curves on `side`.
"""
function get_energy_offer(device, side::OfferSide)
    hasmethod(get_operation_cost, Tuple{typeof(device)}) || return nothing
    cost = get_operation_cost(device)
    cost isa MarketBidCost || return nothing
    key = side == OfferSide.GEN ? get_incremental_offer_curves(cost) : get_decremental_offer_curves(cost)
    if key isa IS.TimeSeriesKey
        ts = get_time_series(SingleTimeSeries, device, IS.get_name(key))
        series = get_time_series_array(device, ts)
        return NEMEnergyOffer(side, timestamp(series), IS.get_resolution(ts), collect(values(series)))
    end
    key isa CostCurve || return nothing
    return NEMEnergyOffer(side, nothing, nothing, [get_function_data(get_value_curve(key))])
end


"""
    NEMFCASOffer

One side of a unit's offer for one FCAS market over a window, as attached by
[`set_fcas_bids!`](@ref): a trapezium and an offer curve per interval.

# Fields
- `service::BidType`: the FCAS market.
- `side::OfferSide`: the offer side.
- `trapeziums::Vector{FCASTrapezium}`: one per interval.
- `curves::Vector{PiecewiseStepData}`: one per interval.
"""
struct NEMFCASOffer
    service::BidType
    side::OfferSide
    trapeziums::Vector{FCASTrapezium}
    curves::Vector{PiecewiseStepData}
end


"""
    get_fcas_offer(component, service, side, initial_time, horizon; kwargs...) -> NEMFCASOffer

`component`'s `service` offer on `side`, `horizon` steps from `initial_time`, in `component`'s
`System`'s current display units: the [`get_scaled_fcas_trapezium`](@ref) trapeziums (`kwargs` are
passed to it), paired with the offer curves of `get_fcas_offer_curve`.
Throws `ArgumentError` if either series isn't attached or they differ in length.

# Returns
A [`NEMFCASOffer`](@ref).
"""
function get_fcas_offer(component, service::BidType, side::OfferSide, initial_time, horizon::Integer; kwargs...)
    decremental = side == OfferSide.LOAD
    trapeziums = get_scaled_fcas_trapezium(component, service, initial_time, horizon; decremental, kwargs...)
    curves = get_fcas_offer_curve(component, service, initial_time, horizon; decremental)
    _require_equal_length(trapeziums, curves, service, component)
    return NEMFCASOffer(service, side, trapeziums, curves)
end
