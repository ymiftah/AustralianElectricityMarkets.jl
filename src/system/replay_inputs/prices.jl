# The band prices of each energy and FCAS bid, held as typed day-constants of the bid.


"""
    _day_band_prices(curves::Vector{PiecewiseStepData}, stamps_in_replay::AbstractVector{Bool}, label::AbstractString) -> NTuple{10, Float64}

The band prices of `curves` at the first replay interval, padded with `0.0` to ten bands. Throws an
`ArgumentError` when no stamp is a replay interval, the prices at any other replay interval differ, or a curve in
the replay range has more than ten bands.

# Arguments
- `curves`: the offer curves, one per stamp.
- `stamps_in_replay`: which stamps are replay intervals.
- `label`: names the bid in error messages.

# Returns
An `NTuple{10, Float64}`.
"""
function _day_band_prices(
        curves::Vector{PSY.PiecewiseStepData}, stamps_in_replay::AbstractVector{Bool}, label::AbstractString,
    )
    prices = nothing
    for (curve, in_replay) in zip(curves, stamps_in_replay)
        in_replay || continue
        y = PSY.get_y_coords(curve)
        length(y) <= 10 || throw(ArgumentError("$label has $(length(y)) bands, more than the ten NEMDE allows"))
        padded = ntuple(i -> i <= length(y) ? Float64(y[i]) : 0.0, 10)
        if isnothing(prices)
            prices = padded
        elseif padded != prices
            throw(
                ArgumentError(
                    "band prices of $label vary within the replay range; a NEMDE system covers one trading day",
                ),
            )
        end
    end
    isnothing(prices) && throw(ArgumentError("$label has no offer curve in the replay range"))
    return prices
end


"""
    _set_band_prices!(sys::PSY.System) -> Nothing

Sets `band_prices` of each energy bid of `sys` to the band prices of its side's `energy_offer` series (loss-factor
referred) over the replay intervals, through [`_day_band_prices`](@ref). Replaces the bid; repeat calls recompute the
same value. Also sets `band_prices` of each FCAS bid of a modelled side to the prices of its `offer_curves` series
(no loss-factor referral, no rounding). Throws `ArgumentError` when a bid's prices vary within the replay range, or
an FCAS bid's `offer_curves` is static. Requires the energy offer series.

# Arguments
- `sys`: the `System` whose energy bids are updated.

# Returns
`nothing`.
"""
function _set_band_prices!(sys::PSY.System)
    replay = Set(_replay_interval_stamps(sys))
    for device in _bidding_devices(sys)
        cost = _nem_offer_cost(device)
        isnothing(cost) && continue
        for bid in copy(get_energy_bids(cost))
            side = _energy_offer_side(bid.direction)
            view = _energy_offer_view(device, side)
            isnothing(view) && continue
            label = "$(PSY.get_name(device)) ENERGY $(side)"
            prices = _day_band_prices(view.curves, [t in replay for t in view.timestamps], label)
            _set_energy_bid!(cost, _with_band_prices(bid, prices))
        end
        for bid in copy(get_fcas_bids(cost))
            isnothing(_fcas_bid_side(device, bid)) && continue
            key = bid.offer_curves
            key isa IS.StaticTimeSeriesKey || throw(
                ArgumentError(
                    "\"$(PSY.get_name(device))\" has a static `offer_curves` field for $(bid.service); FCAS offers need a series-backed bid.",
                ),
            )
            name = IS.get_name(key)
            series = PSY.get_time_series_array(PSY.SingleTimeSeries, device, name)
            curves = collect(values(series))
            label = "$(PSY.get_name(device)) $(bid.service) $(bid.direction)"
            prices = _day_band_prices(curves, [t in replay for t in PSY.TimeSeries.timestamp(series)], label)
            _set_fcas_bid!(cost, _with_band_prices(bid, prices))
        end
    end
    return
end

# `bid` with its `band_prices` replaced.
function _with_band_prices(bid::NEMEnergyBid, prices::NTuple{10, Float64})
    return NEMEnergyBid(;
        (f => getfield(bid, f) for f in fieldnames(NEMEnergyBid) if f != :band_prices)..., band_prices = prices,
    )
end

function _with_band_prices(bid::NEMFCASBid, prices::NTuple{10, Float64})
    return NEMFCASBid(;
        (f => getfield(bid, f) for f in fieldnames(NEMFCASBid) if f != :band_prices)..., band_prices = prices,
    )
end
