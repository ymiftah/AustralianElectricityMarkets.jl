"""
    _tie_break_offers(sys) -> Dict

Every available component's energy offer curves, grouped by (direction, region):
`(decremental, region) => (stamps, resolution, offers)`, `offers` holding one `(device, curves)` per unit, the
`PiecewiseStepData` curves (natural units) on `stamps`. A unit with a fixed curve repeats it over the
`stamps` of its region's time-varying curves, or of another region's, and is left out when no unit has a
time-varying curve in that direction. Throws an `ArgumentError` when two time-varying curves of a group
are on different timestamps.

# Returns
`Dict{Tuple{Bool, String}, NamedTuple}`.
"""
function _tie_break_offers(sys::PSY.System)
    offers = Dict{Tuple{Bool, String}, Any}()
    fixed = Tuple{Bool, String, PSY.Component, PSY.PiecewiseStepData}[]
    for device in PSY.get_available_components(PSY.StaticInjection, sys)
        hasmethod(PSY.get_operation_cost, Tuple{typeof(device)}) && PSY.get_operation_cost(device) isa PSY.MarketBidCost || continue
        region = PSY.get_name(PSY.get_area(PSY.get_bus(device)))
        for decremental in (false, true)
            key = PSI.get_offer_curves_maybe_decremental(Val(decremental), device)
            if PSI.is_time_variant(key)
                ts = PSY.get_time_series(PSY.SingleTimeSeries, device, IS.get_name(key))
                series = PSY.get_time_series_array(device, ts)
                stamps = PSY.TimeSeries.timestamp(series)
                entry = get!(
                    offers, (decremental, region),
                    (; stamps, resolution = IS.get_resolution(ts), offers = Tuple{PSY.Component, Vector{PSY.PiecewiseStepData}}[]),
                )
                entry.stamps == stamps || throw(
                    ArgumentError(
                        "tie-break: $(PSY.get_name(device))'s offer curves are on timestamps from $(first(stamps)), " *
                            "unlike the other units of region $region from $(first(entry.stamps)).",
                    ),
                )
                push!(entry.offers, (device, collect(values(series))))
            elseif key isa PSY.CostCurve
                push!(fixed, (decremental, region, device, PSY.get_function_data(PSY.get_value_curve(key))))
            end
        end
    end
    for (decremental, region, device, curve) in fixed
        grid = get(offers, (decremental, region), nothing)
        if isnothing(grid)
            donors = sort!([k for k in keys(offers) if first(k) == decremental])
            isempty(donors) && continue
            grid = offers[first(donors)]
        end
        entry = get!(
            offers, (decremental, region),
            (; stamps = grid.stamps, resolution = grid.resolution, offers = Tuple{PSY.Component, Vector{PSY.PiecewiseStepData}}[]),
        )
        push!(entry.offers, (device, fill(curve, length(grid.stamps))))
    end
    return offers
end


# Bands of `offers` at stamp `i`, in the `_tie_groups` form.
function _tie_break_stamp_bands(offers, i::Int)
    return [
        (; price, width = x[k + 1] - x[k], name = PSY.get_name(device), band = k)
            for (device, curves) in offers
            for (x, y) in ((PSY.get_x_coords(curves[i]), PSY.get_y_coords(curves[i])),)
            for (k, price) in enumerate(y)
    ]
end


"""
    set_tie_break_scales!(sys)

Attaches each price-tied energy band's tie-break scale `w / w_ref` (its width over the widest band of its
tie group at that interval, 0 when the band is untied or the group has no width) as the `SingleTimeSeries`
`"tie_break_scale_<k>[_decremental]"` of its unit, where `k` is the band's segment index. Call it after
[`set_market_bids!`](@ref) and before `transform_single_time_series!`. Every unit carrying a scale must be
modelled in the build: a battery needs `:batteries` in the replication `parts`, or the build fails.

# Arguments
- `sys`: the `System` to add to.

# Returns
`nothing`.
"""
function set_tie_break_scales!(sys::PSY.System)
    for ((decremental, _), (; stamps, resolution, offers)) in _tie_break_offers(sys)
        scales = Dict{Tuple{PSY.Component, Int}, Vector{Float64}}()
        devices = Dict(PSY.get_name(device) => device for (device, _) in offers)
        for i in eachindex(stamps)
            bands = _tie_break_stamp_bands(offers, i)
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
            PSY.has_time_series(device, PSY.SingleTimeSeries, name) && PSY.remove_time_series!(sys, PSY.SingleTimeSeries, device, name)
            PSY.add_time_series!(sys, device, AustralianElectricityMarkets._single_series(name, first(stamps), values, resolution))
        end
    end
    return
end
