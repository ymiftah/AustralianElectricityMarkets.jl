"""
    set_mnsp_offers!(sys, db, date_range) -> Vector{String}

Attaches each MNSP link's offer to the `PSY.AreaInterchange` of its interconnector. For a link
whose `FROMREGION` is the interconnector's from area (the forward link) the series are
`"mnsp_forward_offer"`, a `Deterministic` of `PSY.PiecewiseStepData` (cumulative MW, `\$/MWh`, one
step per band with a positive `BANDAVAIL`), and `"mnsp_forward_max_avail"`, the link's `MAXAVAIL` in
MW; the other link gets `"mnsp_reverse_offer"` and `"mnsp_reverse_max_avail"`. The interconnector's
`ext` records `"mnsp_forward"` and `"mnsp_reverse"` with the link's `link_id`, `from_region_tlf`,
`to_region_tlf`, `lhs_factor` and `max_capacity`.

Only links that offer in `date_range` (named by `DISPATCH_MNSPBIDTRK`) are used, so interconnectors
that are no longer MNSPs are ignored. An interconnector with offers for only one of its links, or
with a missing interval, is left unchanged and listed in a warning: it keeps the free-flow model
with static flow limits. The same happens, with a warning, when the MNSP tables are not cached or
no offer is found; the first trading day of a month also needs the previous month's
`MNSP_BIDOFFERPERIOD` and `MNSP_DAYOFFER` cached. Calling it again replaces earlier series.

# Arguments
- `sys`: the `PSY.System` to add to.
- `db`: an `AEMDB` connection.
- `date_range`: the five-minute dispatch intervals to replay.

# Returns
The names of the interconnectors that received offers.
"""
function set_mnsp_offers!(sys, db, date_range)
    step(date_range) == Minute(5) ||
        throw(ArgumentError("set_mnsp_offers!: MNSP offers are five-minute data, got a step of $(step(date_range))"))
    start_date = first(date_range)
    intervals = collect(date_range)[1:(end - 1)]
    uncached = filter(t -> !_table_is_cached(db, t), [:MNSP_INTERCONNECTOR, :MNSP_DAYOFFER, :MNSP_BIDOFFERPERIOD, :DISPATCH_MNSPBIDTRK])
    if !isempty(uncached)
        @warn "set_mnsp_offers!: $(join(uncached, ", ")) not cached; MNSP interconnectors keep the free-flow model with static flow limits"
        return String[]
    end
    offers = AustralianElectricityMarketsData.read_mnsp_offers(db, date_range)
    if isempty(offers)
        @warn "set_mnsp_offers!: no MNSP offers in $(first(date_range)) to $(last(date_range)); MNSP interconnectors keep the free-flow model with static flow limits. The first trading day of a month needs the previous month's MNSP_DAYOFFER and MNSP_BIDOFFERPERIOD cached."
        return String[]
    end
    links = AustralianElectricityMarketsData.read_mnsp_links(db, start_date)
    links = links[in.(links.LINKID, Ref(unique(offers.LINKID))), :]

    attached = String[]
    skipped = String[]
    for group in groupby(links, :INTERCONNECTORID)
        name = first(group.INTERCONNECTORID)
        device = get_component(AreaInterchange, sys, name)
        isnothing(device) && continue
        from_area = get_name(get_from_area(device))
        to_area = get_name(get_to_area(device))
        directions = Dict{String, Any}()
        for link in eachrow(group)
            direction = if link.FROMREGION == from_area
                "forward"
            elseif link.FROMREGION == to_area
                "reverse"
            else
                throw(ArgumentError("set_mnsp_offers!: link $(link.LINKID) starts in $(link.FROMREGION), which is neither area of $name ($from_area to $to_area)"))
            end
            directions[direction] = (link = link, rows = offers[offers.LINKID .== link.LINKID, :])
        end
        if nrow(group) != 2 || length(directions) != 2 ||
                any(d -> d.rows.INTERVAL_DATETIME != intervals, values(directions))
            push!(skipped, name)
            continue
        end
        for (direction, (; link, rows)) in directions
            curves = [_mnsp_offer_curve(row) for row in eachrow(rows)]
            max_avail = [ismissing(row.MAXAVAIL) ? last(get_x_coords(c)) : Float64(row.MAXAVAIL) for (row, c) in zip(eachrow(rows), curves)]
            for (series, values) in (("offer", curves), ("max_avail", max_avail))
                series_name = "mnsp_$(direction)_$series"
                has_time_series(device, Deterministic, series_name) &&
                    remove_time_series!(sys, Deterministic, device, series_name)
                add_time_series!(
                    sys, device,
                    Deterministic(;
                        name = series_name, data = Dict(start_date => values),
                        resolution = Minute(5), interval = Minute(5),
                    ),
                )
            end
            get_ext(device)["mnsp_$direction"] = Dict{String, Any}(
                "link_id" => link.LINKID, "from_region_tlf" => link.FROM_REGION_TLF,
                "to_region_tlf" => link.TO_REGION_TLF, "lhs_factor" => link.LHSFACTOR,
                "max_capacity" => link.MAXCAPACITY,
            )
        end
        push!(attached, name)
    end
    isempty(skipped) ||
        @warn "set_mnsp_offers!: no complete offer pair for $(join(skipped, ", ")); the whole interconnector keeps the free-flow model with static flow limits"
    return attached
end

"""
    _mnsp_offer_curve(row) -> PSY.PiecewiseStepData

The offer curve of one `read_mnsp_offers` row: one step per band with a positive `BANDAVAIL`, in
band order. A row with no available band yields a single zero-width step.
"""
function _mnsp_offer_curve(row)
    avail = [coalesce(row[Symbol("BANDAVAIL$i")], 0.0) for i in 1:10]
    prices = [coalesce(row[Symbol("PRICEBAND$i")], 0.0) for i in 1:10]
    keep = avail .> 0
    any(keep) || return PiecewiseStepData([0.0, 0.0], [0.0])
    return PiecewiseStepData([0.0; cumsum(Float64.(avail[keep]))], Float64.(prices[keep]))
end
