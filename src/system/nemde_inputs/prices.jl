# The band prices of each energy, FCAS and MNSP bid, held as typed day-constants of the bid.


"""
    _day_band_prices(curves::Vector{PiecewiseStepData}, label::AbstractString) -> NTuple{10, Float64}

The band prices of `curves`, the offer curves of the dispatch intervals, padded with `0.0` to ten bands. Throws an
`ArgumentError` when `curves` is empty, the prices differ between intervals, or a curve has more than ten bands.

# Arguments
- `curves`: the offer curves, one per dispatch interval.
- `label`: names the bid in error messages.

# Returns
An `NTuple{10, Float64}`.
"""
function _day_band_prices(curves::Vector{PSY.PiecewiseStepData}, label::AbstractString)
    isempty(curves) && throw(ArgumentError("$label has no offer curve in the dispatch range"))
    prices = unique(
        map(curves) do curve
            y = PSY.get_y_coords(curve)
            length(y) <= 10 || throw(ArgumentError("$label has $(length(y)) bands, more than the ten NEMDE allows"))
            return ntuple(i -> i <= length(y) ? Float64(y[i]) : 0.0, 10)
        end,
    )
    length(prices) == 1 || throw(
        ArgumentError("band prices of $label vary within the dispatch range; a NEMDE system covers one trading day"),
    )
    return only(prices)
end


"""
    _set_band_prices!(sys::PSY.System, grid = _nemde_grid(sys)) -> Nothing

Sets `band_prices` of each energy, FCAS and MNSP bid of `sys` through [`_day_band_prices`](@ref). An energy bid takes
the prices of its side's `energy_offer` series (loss-factor referred) over the dispatch intervals; an FCAS bid of a
modelled side those of its `offer_curves` series, and an MNSP link bid those of its `offer_curves` (a static curve
is its own prices), both unreferred and unrounded. Replaces each bid; repeat calls recompute the same values.
Throws `ArgumentError` when a bid's prices vary within the dispatch range, or an FCAS bid's `offer_curves` is static.
Requires the energy offer series.

# Arguments
- `sys`: the `System` whose bids are updated.
- `grid`: the timestamps the single time series of `sys` share; read from `sys` by default.

# Returns
`nothing`.
"""
function _set_band_prices!(sys::PSY.System, grid = _nemde_grid(sys))
    # The final stamp of the grid is not a dispatch interval.
    dispatch(curves) = curves[1:(end - 1)]
    for device in _bidding_devices(sys)
        cost = _nem_offer_cost(device)
        isnothing(cost) && continue
        for bid in copy(get_energy_bids(cost))
            side = _energy_offer_side(bid.direction)
            view = _energy_offer_view(device, side)
            isnothing(view) && continue
            prices = _day_band_prices(dispatch(view.curves), "$(PSY.get_name(device)) ENERGY $(side)")
            _set_energy_bid!(cost, _with_band_prices(bid, prices))
        end
        for bid in copy(get_fcas_bids(cost))
            isnothing(_fcas_bid_side(device, bid)) && continue
            curves = _values_on_grid(device, bid.offer_curves, grid; field = :offer_curves)
            prices = _day_band_prices(dispatch(curves), "$(PSY.get_name(device)) $(bid.service) $(bid.direction)")
            _set_fcas_bid!(cost, _with_band_prices(bid, prices))
        end
    end
    for device in PSY.get_components(PSY.AreaInterchange, sys), bid in collect(PSY.get_supplemental_attributes(NEMMNSPBid, device))
        # A static curve is its own prices.
        curves = bid.offer_curves isa PSY.PiecewiseStepData ? [bid.offer_curves] : dispatch(_values_on_grid(device, bid.offer_curves, grid))
        prices = _day_band_prices(curves, "$(PSY.get_name(device)) MNSP $(bid.direction)")
        PSY.remove_supplemental_attribute!(sys, device, bid)
        PSY.add_supplemental_attribute!(sys, device, _with_band_prices(bid, prices))
    end
    return
end

# `bid` with its `band_prices` replaced.
function _with_band_prices(bid, prices::NTuple{10, Float64})
    fields = (f for f in fieldnames(typeof(bid)) if f ∉ (:band_prices, :internal))
    return typeof(bid)(; (f => getfield(bid, f) for f in fields)..., band_prices = prices)
end
