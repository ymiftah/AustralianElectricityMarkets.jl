# The tie-break scales of the price-tied energy bands and the EnergyTieBreak service over their units.


# The energy offers of one (direction, region): offer timestamps and resolution, and each unit's curves on them.
const _TieOffers = @NamedTuple{
    stamps::Vector{DateTime}, resolution::Dates.Period, offers::Vector{Tuple{PSY.Component, Vector{PSY.PiecewiseStepData}}},
}


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
    _tie_break_offers(sys) -> Dict

Every available component's energy offer curves, grouped by (direction, region):
`(decremental, region) => (stamps, resolution, offers)`, `offers` holding one `(device, curves)` per unit, the
`PiecewiseStepData` curves (natural units) on `stamps`. Throws an `ArgumentError` when two curves of a group
are on different timestamps.

# Returns
`Dict{Tuple{Bool, String}, _TieOffers}`.
"""
function _tie_break_offers(sys::PSY.System)
    offers = Dict{Tuple{Bool, String}, _TieOffers}()
    for device in PSY.get_available_components(PSY.StaticInjection, sys)
        region = PSY.get_name(PSY.get_area(PSY.get_bus(device)))
        for side in (OfferSide.GEN, OfferSide.LOAD)
            offer = _energy_offer_view(device, side)
            isnothing(offer) && continue
            decremental = side == OfferSide.LOAD
            entry = get!(() -> _TieOffers((offer.timestamps, offer.resolution, [])), offers, (decremental, region))
            entry.stamps == offer.timestamps || throw(
                ArgumentError(
                    "tie-break: $(PSY.get_name(device))'s offer curves are on timestamps from $(first(offer.timestamps)), " *
                        "unlike the other units of region $region from $(first(entry.stamps)).",
                ),
            )
            push!(entry.offers, (device, offer.curves))
        end
    end
    return offers
end


"""
    _tie_break_active_bands(offers) -> Dict{Tuple{Bool, String}, Set{Int}}

The segments of each unit's offer curves that have a positive width at some timestamp, keyed
`(decremental, unit name)`. Only these can take part in a tie: a segment empty throughout, such as
an unused top band priced at the Market Price Cap, would only add vacuous rows.

# Returns
A `Dict`.
"""
function _tie_break_active_bands(offers)
    active = Dict{Tuple{Bool, String}, Set{Int}}()
    for ((decremental, _), (; offers)) in offers, (device, curves) in offers
        segments = get!(Set{Int}, active, (decremental, PSY.get_name(device)))
        for curve in curves
            x = PSY.get_x_coords(curve)
            union!(segments, (k for k in 1:(length(x) - 1) if x[k + 1] > x[k]))
        end
    end
    return active
end


# Bands of `offers` at stamp `i`, in the `tie_groups` form, restricted to the `active` segments.
function _tie_break_stamp_bands(offers, i::Int, active, decremental::Bool)
    return [
        (; price, width = x[k + 1] - x[k], name = PSY.get_name(device), band = k)
            for (device, curves) in offers
            for (x, y) in ((PSY.get_x_coords(curves[i]), PSY.get_y_coords(curves[i])),)
            for (k, price) in enumerate(y) if k in get(active, (decremental, PSY.get_name(device)), ())
    ]
end


# Pairs `(name_a, band_a, name_b, band_b)` of price-tied bands of different units at stamp `i`, the
# `(name, band)` of `a` ordered before that of `b`.
function _tie_break_pairs(offers, i::Int, active, decremental::Bool)
    bands = _tie_break_stamp_bands(offers, i, active, decremental)
    pairs = Set{Tuple{String, Int, String, Int}}()
    for group in tie_groups(bands), x in 1:(length(group) - 1), y in (x + 1):length(group)
        a, b = bands[group[x]], bands[group[y]]
        a.name == b.name && continue
        lo, hi = minmax((a.name, a.band), (b.name, b.band))
        push!(pairs, (lo..., hi...))
    end
    return pairs
end


# Pair membership depends on active prices, not the widths used to scale the tie-break rows.
function _tie_break_prices_unchanged(offers, i::Int, reference::Int, active, decremental::Bool)
    for (device, curves) in offers
        current = PSY.get_y_coords(curves[i])
        initial = PSY.get_y_coords(curves[reference])
        length(current) == length(initial) || return false
        for k in get(active, (decremental, PSY.get_name(device)), ())
            k <= length(current) || continue
            current[k] == initial[k] || return false
        end
    end
    return true
end


"""
    _check_tie_break_prices(sys, stamps)

Verifies that the price-tied energy band pairs of `sys` are the same at every stamp of `stamps`, for every
region and direction, as a model built once and stepped through `stamps` requires. Band prices change only
between trading days, so a range inside one trading day passes. Unchanged active-band prices and band counts
reuse the first stamp's pair set; other stamps retain the full pair comparison.

# Arguments
- `sys`: the system whose offer curves are checked.
- `stamps`: the interval timestamps the replay solves, the first of which is the reference.

# Returns
`nothing`. Throws `ArgumentError` naming the first interval whose pairs differ and up to five of
the differing pairs, or a stamp that is not on a region's offer curve timestamps.
"""
function _check_tie_break_prices(sys::PSY.System, stamps)
    isempty(stamps) && return
    all_offers = _tie_break_offers(sys)
    active = _tie_break_active_bands(all_offers)
    for ((decremental, region), entry) in all_offers
        offers = entry.offers
        index = Dict(s => i for (i, s) in enumerate(entry.stamps))
        position(t) = get(
            () -> throw(ArgumentError("tie-break: interval $t is not on the offer curve timestamps of region $region.")),
            index, t,
        )
        reference_index = position(first(stamps))
        reference = _tie_break_pairs(offers, reference_index, active, decremental)
        for t in Iterators.drop(stamps, 1)
            i = position(t)
            _tie_break_prices_unchanged(offers, i, reference_index, active, decremental) && continue
            pairs = _tie_break_pairs(offers, i, active, decremental)
            pairs == reference && continue
            changed = first(sort!(collect(symdiff(pairs, reference))), 5)
            throw(
                ArgumentError(
                    "tie-break: the price-tied $(decremental ? "load bid" : "offer") bands of region $region at $t " *
                        "differ from those at $(first(stamps)), e.g. $(join(changed, ", ")). Band prices change " *
                        "between trading days; keep date_range within one trading day (04:05 to 04:00 next day).",
                ),
            )
        end
    end
    return
end


"""
    _set_tie_break!(sys::PSY.System) -> Nothing

Adds each price-tied energy band's tie-break scale `w / w_ref` (its width over the widest band of its
tie group at that interval, 0 when the band is untied or the group has no width) as the `SingleTimeSeries`
[`tie_break_series_name`](@ref) of its unit, where the segment index is the band's offer segment. Adds the
[`EnergyTieBreak`](@ref) named [`TIE_BREAK_SERVICE_NAME`](@ref), with the available units that carry an energy
bid as its contributing devices, once. Then checks that the price-tied pairs hold over the replay intervals of
`sys`. Throws `ArgumentError` when the pairs change between intervals or a tied group is not valid. Requires
the energy offer series written before it in the replay input stage.

# Arguments
- `sys`: the `System` to add to.

# Returns
`nothing`.
"""
function _set_tie_break!(sys::PSY.System)
    all_offers = _tie_break_offers(sys)
    active = _tie_break_active_bands(all_offers)
    for ((decremental, _), (; stamps, resolution, offers)) in all_offers
        scales = Dict{Tuple{PSY.Component, Int}, Vector{Float64}}()
        devices = Dict(PSY.get_name(device) => device for (device, _) in offers)
        for i in eachindex(stamps)
            bands = _tie_break_stamp_bands(offers, i, active, decremental)
            for group in tie_groups(bands)
                w_ref = maximum(bands[j].width for j in group)
                for j in group
                    s = get!(() -> zeros(length(stamps)), scales, (devices[bands[j].name], bands[j].band))
                    s[i] = tie_break_scale(bands[j].width, w_ref)
                end
            end
        end
        for ((device, band), values) in scales
            name = tie_break_series_name(band, decremental)
            PSY.add_time_series!(sys, device, single_series(name, first(stamps), values, resolution))
        end
    end
    devices = [d for d in PSY.get_available_components(PSY.StaticInjection, sys) if _has_energy_offer(d)]
    isempty(devices) || _add_nem_service!(sys, EnergyTieBreak(; name = TIE_BREAK_SERVICE_NAME), devices)
    _check_tie_break_prices(sys, _replay_interval_stamps(sys))
    return
end
