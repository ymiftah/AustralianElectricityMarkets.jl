"""
    TIE_BREAK_CVP_FACTOR

Constraint violation penalty factor (1e-6) of AEMO's tie-break constraint (`TBSlack1` and
`TBSlack2`, item 53 of the *Schedule of Constraint Violation Penalty Factors* v8.0). It is also
the price tolerance, in `\$/MWh` after loss-factor adjustment, within which two energy bands are
price-tied.
"""
const TIE_BREAK_CVP_FACTOR = 1.0e-6


"""
    TIE_BREAK_SERVICE_NAME

Name of the [`EnergyTieBreak`](@ref) service [`set_tie_break_scales!`](@ref) attaches, and of the
`PowerSimulations.ServiceModel` that the NEM dispatch model set registers for it.
"""
const TIE_BREAK_SERVICE_NAME = "energy_tie_break"


# Name of the series holding segment `band`'s tie-break scale.
function _tie_break_series_name(band::Int, decremental::Bool)
    return "tie_break_scale_$(band)" * side_suffix(offer_side(decremental))
end


"""
    _tie_groups(bands) -> Vector{Vector{Int}}

Price-tied groups of `bands` (each with `price`, `name` and `band`): runs of the bands sorted by
price whose consecutive prices differ by at most [`TIE_BREAK_CVP_FACTOR`](@ref), kept when they
hold bands of two or more units. Each group lists indices into `bands` in sorted order. Throws an
`ArgumentError` for a run spanning more than [`TIE_BREAK_CVP_FACTOR`](@ref), which only
transitive ties produce.

# Returns
`Vector{Vector{Int}}`.
"""
function _tie_groups(bands)
    order = sort!(collect(eachindex(bands)); by = i -> (bands[i].price, bands[i].name, bands[i].band))
    groups = Vector{Int}[]
    start = 1
    for k in eachindex(order)
        (k == length(order) || bands[order[k + 1]].price - bands[order[k]].price > TIE_BREAK_CVP_FACTOR) || continue
        group = order[start:k]
        start = k + 1
        lo, hi = bands[first(group)], bands[last(group)]
        hi.price - lo.price > TIE_BREAK_CVP_FACTOR && throw(
            ArgumentError(
                "tie-break: the prices of $(lo.name) band $(lo.band) ($(lo.price)) and $(hi.name) band $(hi.band) " *
                    "($(hi.price)) are tied only through bands between them; transitive ties are not supported.",
            ),
        )
        length(unique(bands[i].name for i in group)) > 1 && push!(groups, group)
    end
    return groups
end


# The energy offers of one (direction, region): offer timestamps and resolution, and each unit's curves on them.
const _TieOffers = @NamedTuple{
    stamps::Vector{DateTime}, resolution::Dates.Period, offers::Vector{Tuple{PSY.Component, Vector{PSY.PiecewiseStepData}}},
}


# Whether `device` is priced on a `MarketBidCost`.
function _has_market_bid(device::PSY.Component)
    return hasmethod(PSY.get_operation_cost, Tuple{typeof(device)}) && PSY.get_operation_cost(device) isa PSY.MarketBidCost
end


"""
    _tie_break_offers(sys) -> Dict

Every available component's energy offer curves, grouped by (direction, region):
`(decremental, region) => (stamps, resolution, offers)`, `offers` holding one `(device, curves)` per unit, the
`PiecewiseStepData` curves (natural units) on `stamps`. A unit with a fixed curve repeats it over the
`stamps` of its region's time-varying curves, or of another region's, and is left out when no unit has a
time-varying curve in that direction. Throws an `ArgumentError` when two time-varying curves of a group
are on different timestamps.

# Returns
`Dict{Tuple{Bool, String}, _TieOffers}`.
"""
function _tie_break_offers(sys::PSY.System)
    offers = Dict{Tuple{Bool, String}, _TieOffers}()
    fixed = Tuple{Bool, String, PSY.Component, PSY.PiecewiseStepData}[]
    for device in PSY.get_available_components(PSY.StaticInjection, sys)
        region = PSY.get_name(PSY.get_area(PSY.get_bus(device)))
        for side in (OfferSide.GEN, OfferSide.LOAD)
            offer = get_energy_offer(device, side)
            isnothing(offer) && continue
            decremental = side == OfferSide.LOAD
            if isnothing(offer.timestamps)
                push!(fixed, (decremental, region, device, only(offer.curves)))
                continue
            end
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
    for (decremental, region, device, curve) in fixed
        grid = get(offers, (decremental, region), nothing)
        if isnothing(grid)
            donors = sort!([k for k in keys(offers) if first(k) == decremental])
            isempty(donors) && continue
            grid = offers[first(donors)]
        end
        entry = get!(() -> _TieOffers((grid.stamps, grid.resolution, [])), offers, (decremental, region))
        push!(entry.offers, (device, fill(curve, length(grid.stamps))))
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


# Bands of `offers` at stamp `i`, in the `_tie_groups` form, restricted to the `active` segments.
function _tie_break_stamp_bands(offers, i::Int, active, decremental::Bool)
    return [
        (; price, width = x[k + 1] - x[k], name = PSY.get_name(device), band = k)
            for (device, curves) in offers
            for (x, y) in ((PSY.get_x_coords(curves[i]), PSY.get_y_coords(curves[i])),)
            for (k, price) in enumerate(y) if k in get(active, (decremental, PSY.get_name(device)), ())
    ]
end


"""
    set_tie_break_scales!(sys)

Attaches each price-tied energy band's tie-break scale `w / w_ref` (its width over the widest band of its
tie group at that interval, 0 when the band is untied or the group has no width) as the `SingleTimeSeries`
`"tie_break_scale_<k>[_decremental]"` of its unit, where `k` is the band's segment index. Series left by an earlier call
on any `StaticInjection` are removed first. Replaces any [`EnergyTieBreak`](@ref) named [`TIE_BREAK_SERVICE_NAME`](@ref)
with one whose contributing devices are every available unit priced on a `MarketBidCost`, or leaves none
when there is no such unit. Call it after [`set_market_bids!`](@ref) and before
`transform_single_time_series!`. Every contributor carrying a scale must be modelled in the build, or the
build fails.

# Arguments
- `sys`: the `System` to add to.

# Returns
`nothing`.
"""
function set_tie_break_scales!(sys::PSY.System)
    all_offers = _tie_break_offers(sys)
    for device in PSY.get_components(PSY.StaticInjection, sys), key in collect(PSY.get_time_series_keys(device))
        name = IS.get_name(key)
        startswith(name, "tie_break_scale_") && remove_single_series!(sys, device, name)
    end
    active = _tie_break_active_bands(all_offers)
    for ((decremental, _), (; stamps, resolution, offers)) in all_offers
        scales = Dict{Tuple{PSY.Component, Int}, Vector{Float64}}()
        devices = Dict(PSY.get_name(device) => device for (device, _) in offers)
        for i in eachindex(stamps)
            bands = _tie_break_stamp_bands(offers, i, active, decremental)
            for group in _tie_groups(bands)
                w_ref = maximum(bands[j].width for j in group)
                for j in group
                    s = get!(() -> zeros(length(stamps)), scales, (devices[bands[j].name], bands[j].band))
                    s[i] = w_ref > 0.0 ? bands[j].width / w_ref : 0.0
                end
            end
        end
        for ((device, band), values) in scales
            name = _tie_break_series_name(band, decremental)
            PSY.add_time_series!(sys, device, single_series(name, first(stamps), values, resolution))
        end
    end
    existing = PSY.get_component(EnergyTieBreak, sys, TIE_BREAK_SERVICE_NAME)
    isnothing(existing) || PSY.remove_component!(sys, existing)
    devices = [d for d in PSY.get_available_components(PSY.StaticInjection, sys) if _has_market_bid(d)]
    isempty(devices) || PSY.add_service!(sys, EnergyTieBreak(; name = TIE_BREAK_SERVICE_NAME), devices)
    return
end
