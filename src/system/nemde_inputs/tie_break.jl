# The tie-break scales of the price-tied energy bands and the EnergyTieBreak service over their units.


# Whether `device` has an energy bid on either side.
function _has_energy_offer(device::PSY.Component)
    cost = _nem_offer_cost(device)
    return !isnothing(cost) && !isempty(get_energy_bids(cost))
end


"""
    _energy_offer_view(device, side::OfferSide) -> Union{Nothing, NamedTuple}

The energy offer of `device` on `side`, read from the `"energy_offer"` series of that side: its `side`, the
`timestamps` and `resolution` of the series and its `curves` (`PiecewiseStepData`, natural units). Returns
`nothing` when `device` has no NEM offer, no energy bid on `side`, or no offer series on `side`.

# Arguments
- `device`: the bidding device.
- `side`: the `OfferSide` to read.

# Returns
A `NamedTuple` with fields `side`, `timestamps`, `resolution` and `curves`, or `nothing`.
"""
function _energy_offer_view(device::PSY.Component, side::OfferSide)
    cost = _nem_offer_cost(device)
    isnothing(cost) && return nothing
    isnothing(_energy_bid(cost, side)) && return nothing
    name = energy_offer_series_name(side)
    PSY.has_time_series(device, PSY.SingleTimeSeries, name) || return nothing
    ts = PSY.get_time_series(PSY.SingleTimeSeries, device, name)
    series = PSY.get_time_series_array(PSY.SingleTimeSeries, device, name)
    return (;
        side, timestamps = PSY.TimeSeries.timestamp(series), resolution = IS.get_resolution(ts),
        curves = collect(values(series)),
    )
end


"""
    _tie_break_band_table(sys, grid) -> DataFrame

The energy offer bands of every available unit on `grid`, one row per (side, unit, interval, segment): the `side`
(an [`OfferSide`](@ref)), the unit's `region` (area name), `device` and `name`, the `stamp`, the offer segment `band`, and
its `price` and `width` (MW). Only the segments of a unit and side with a positive width at some interval are kept,
so a band empty throughout the offer series is left out.

# Arguments
- `sys`: the system whose energy offer series [`_set_referred_energy_offers!`](@ref) wrote.
- `grid`: the timestamps the single time series of `sys` share.

# Returns
A `DataFrame`.
"""
function _tie_break_band_table(sys::PSY.System, grid)
    # Rows are collected in a vector, which is far cheaper to grow than a `DataFrame`.
    rows = _TieBandRow[]
    for device in PSY.get_available_components(PSY.StaticInjection, sys), side in (OfferSide.GEN, OfferSide.LOAD)
        offer = _energy_offer_view(device, side)
        isnothing(offer) && continue
        region = PSY.get_name(PSY.get_area(PSY.get_bus(device)))
        _push_band_rows!(rows, side, region, device, grid, offer.curves)
    end
    return DataFrame(rows)
end

const _TieBandRow = @NamedTuple{
    side::OfferSide, region::String, device::PSY.Component, name::String, stamp::DateTime, band::Int, price::Float64, width::Float64,
}

# Appends one row per (interval, segment) of `device`'s offer `curves` on `grid`, for the segments with
# a positive width at some interval.
function _push_band_rows!(rows, side, region, device, grid, curves)
    name = PSY.get_name(device)
    width(curve, k) = PSY.get_x_coords(curve)[k + 1] - PSY.get_x_coords(curve)[k]
    segments = length(PSY.get_x_coords(first(curves))) - 1
    active = [k for k in 1:segments if any(curve -> width(curve, k) > 0, curves)]
    for (stamp, curve) in zip(grid, curves), k in active
        push!(rows, (side, region, device, name, stamp, k, PSY.get_y_coords(curve)[k], width(curve, k)))
    end
    return
end


"""
    _tie_break_active_bands(sys) -> Set{Tuple{Bool, String, Int}}

The `(decremental, unit name, segment)` of each segment of a unit's offer curves with a positive width at some interval.

# Arguments
- `sys`: the system whose energy offer series are written.

# Returns
A `Set`.
"""
function _tie_break_active_bands(sys::PSY.System)
    active = unique(_tie_break_band_table(sys, _nemde_grid(sys)), [:side, :name, :band])
    return Set((row.side == OfferSide.LOAD, row.name, row.band) for row in eachrow(active))
end


# The tied members of one (side, region, interval) group of bands, from its columns: the unit, band and tie-break
# scale of each band in a price-tied group, `w / w_ref` over the widest band of its group.
function _tie_break_scales(price, device, name, band, width)
    bands = [(; price = p, name = n, band = b) for (p, n, b) in zip(price, name, band)]
    tied = (; device = PSY.Component[], name = String[], band = Int[], scale = Float64[])
    for members in tie_groups(bands)
        reference_width = maximum(width[i] for i in members)
        for i in members
            push!(tied.device, device[i])
            push!(tied.name, name[i])
            push!(tied.band, band[i])
            push!(tied.scale, tie_break_scale(width[i], reference_width))
        end
    end
    return tied
end


"""
    _set_tie_break!(sys::PSY.System, grid = _nemde_grid(sys)) -> Nothing

Adds each price-tied energy band's tie-break scale `w / w_ref` (its width over the widest band of its
tie group at that interval, 0 when the band is untied or the group has no width) as the `SingleTimeSeries`
[`tie_break_series_name`](@ref) of its unit, where the segment index is the band's offer segment, on `grid`. Adds the
[`EnergyTieBreak`](@ref) named [`TIE_BREAK_SERVICE_NAME`](@ref), with the available units that carry an energy
bid as its contributing devices, once. Throws `ArgumentError` when a tied group is not valid. Requires
the energy offer series written before it in the NEMDE input stage.

# Arguments
- `sys`: the `System` to add to.
- `grid`: the timestamps the single time series of `sys` share; read from `sys` by default.

# Returns
`nothing`.
"""
function _set_tie_break!(sys::PSY.System, grid = _nemde_grid(sys))
    tied = @chain _tie_break_band_table(sys, grid) begin
        groupby([:side, :region, :stamp])
        combine([:price, :device, :name, :band, :width] => _tie_break_scales => AsTable)
    end
    position(stamp) = (stamp - first(grid)) ÷ step(grid) + 1
    for group in groupby(tied, [:side, :name, :band])
        # The scale is zero at the intervals where the band is not in a tied group.
        values = zeros(length(grid))
        values[position.(group.stamp)] .= group.scale
        (; side, device, band) = first(group)
        name = tie_break_series_name(band, side == OfferSide.LOAD)
        PSY.add_time_series!(sys, device, single_series(name, first(grid), values, step(grid)))
    end
    devices = [d for d in PSY.get_available_components(PSY.StaticInjection, sys) if _has_energy_offer(d)]
    isempty(devices) || _add_nem_service!(sys, EnergyTieBreak(; name = TIE_BREAK_SERVICE_NAME), devices)
    return
end
