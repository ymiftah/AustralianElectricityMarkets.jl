"""
    set_mnsp_offers!(sys, db, date_range) -> Vector{String}

Attaches each MNSP link's offer to the `PSY.AreaInterchange` of its interconnector. For a link
whose `FROMREGION` is the interconnector's from area (the forward link) the series are
`"mnsp_forward_offer"`, a `Deterministic` of `PSY.PiecewiseStepData` (cumulative MW, `\$/MWh`, one
step per band with a positive `BANDAVAIL`), and `"mnsp_forward_max_avail"`, the link's `MAXAVAIL` in
MW; the other link gets `"mnsp_reverse_offer"` and `"mnsp_reverse_max_avail"`. The interconnector's
`ext` records `"mnsp_forward"` and `"mnsp_reverse"` with the link's `link_id`, `from_region_tlf`,
`to_region_tlf`, `lhs_factor` and `max_capacity`.

An interconnector missing an offer for either link or any interval, or whose two links do not
run in opposite directions, is left unchanged and listed in a warning, so it keeps its
free-flow model.

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
    links = AustralianElectricityMarketsData.read_mnsp_links(db)
    offers = AustralianElectricityMarketsData.read_mnsp_offers(db, date_range)

    attached = String[]
    skipped = String[]
    for group in groupby(links, :INTERCONNECTORID)
        name = first(group.INTERCONNECTORID)
        device = get_component(AreaInterchange, sys, name)
        isnothing(device) && continue
        from_area = get_name(get_from_area(device))
        directions = Dict{String, Any}()
        for link in eachrow(group)
            direction = link.FROMREGION == from_area ? "forward" : "reverse"
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
            add_time_series!(
                sys, device,
                Deterministic(;
                    name = "mnsp_$(direction)_offer", data = Dict(start_date => curves),
                    resolution = Minute(5), interval = Minute(5),
                ),
            )
            add_time_series!(
                sys, device,
                Deterministic(;
                    name = "mnsp_$(direction)_max_avail", data = Dict(start_date => max_avail),
                    resolution = Minute(5), interval = Minute(5),
                ),
            )
            get_ext(device)["mnsp_$direction"] = Dict{String, Any}(
                "link_id" => link.LINKID, "from_region_tlf" => link.FROM_REGION_TLF,
                "to_region_tlf" => link.TO_REGION_TLF, "lhs_factor" => link.LHSFACTOR,
                "max_capacity" => link.MAXCAPACITY,
            )
        end
        push!(attached, name)
    end
    isempty(skipped) ||
        @warn "set_mnsp_offers!: no complete offer pair for $(join(skipped, ", ")); the interconnector keeps its free-flow model"
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
