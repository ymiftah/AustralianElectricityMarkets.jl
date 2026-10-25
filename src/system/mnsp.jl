"""
    set_mnsp_offers!(sys, db, date_range; intervention = 0) -> Vector{String}

Attaches both directional offers and availability series to each available MNSP interconnector.
Standing `INTERCONNECTORCONSTRAINT.ICTYPE` data determines which interconnectors require offers.
For the forward link, whose `FROMREGION` and `TOREGION` are the interconnector's from and to areas,
the series are `"mnsp_forward_offer"`, a `SingleTimeSeries` of `PSY.PiecewiseStepData` (cumulative
MW, `\$/MWh`, one step per band with a positive `BANDAVAIL`), and `"mnsp_forward_max_avail"`, the
link's `MAXAVAIL` in MW; the opposite link gets `"mnsp_reverse_offer"` and
`"mnsp_reverse_max_avail"`. The interconnector's `ext` records `"mnsp_forward"` and `"mnsp_reverse"`
with the link's `link_id`, `from_region_tlf`, `to_region_tlf`, `lhs_factor` and `max_capacity`.

Each link also receives `"mnsp_<direction>_ramp_rate"` in MW/min, `"mnsp_<direction>_fixed_load"`
in MW and a `"mnsp_<direction>_fixed_load_invoked"` flag. A NULL fixed loading is inactive;
a numeric zero is active. `"mnsp_initial_flow"` holds signed SCADA flow in MW from
`DISPATCHINTERCONNECTORRES.METEREDMWFLOW`, selected by `intervention`.

Every link must have complete, valid inputs on the five-minute interval grid; missing or invalid
inputs, or an `ICTYPE` that differs between the first and last interval, throw `ArgumentError`
before any offers in `sys` are changed. Calling it again replaces earlier series, which requires
`transform_single_time_series!` not to have run yet.

# Arguments
- `sys`: the `PSY.System` to add to.
- `db`: an `AEMDB` connection holding MNSP registration, offers and dispatch bid tracking.
- `date_range`: five-minute interval-ending timestamps, with an exclusive final timestamp.
- `intervention`: `0` for pricing-run metered flow, `1` for physical dispatch.

# Returns
The names of the interconnectors that received offers. Regulated interconnectors require none.
"""
function set_mnsp_offers!(sys, db, date_range; intervention::Integer = 0)
    step(date_range) == Minute(5) ||
        throw(ArgumentError("set_mnsp_offers!: MNSP offers require five-minute data, got $(step(date_range))"))
    intervals = collect(date_range)[1:(end - 1)]
    isempty(intervals) && throw(ArgumentError("set_mnsp_offers!: the range contains no dispatch intervals"))
    start_date = first(date_range)
    devices = Dict(get_name(d) => d for d in get_components(get_available, AreaInterchange, sys))
    parameters = read_interconnector_loss_parameters(db; as_of = start_date)
    types = Dict(r.INTERCONNECTORID => r.ICTYPE for r in eachrow(parameters))
    for name in sort!(collect(keys(devices)))
        kind = get(types, name, missing)
        (kind in ("MNSP", "REGULATED")) === true ||
            throw(ArgumentError("set_mnsp_offers!: $name has no valid ICTYPE at $start_date"))
    end
    end_parameters = read_interconnector_loss_parameters(db; as_of = last(intervals))
    end_types = Dict(r.INTERCONNECTORID => r.ICTYPE for r in eachrow(end_parameters))
    all(name -> isequal(types[name], get(end_types, name, missing)), keys(devices)) ||
        throw(ArgumentError("set_mnsp_offers!: ICTYPE differs between the first and last interval; split the replay at the change"))
    required = sort!([name for name in keys(devices) if types[name] == "MNSP"])
    isempty(required) && return String[]
    tables = (:MNSP_INTERCONNECTOR, :MNSP_DAYOFFER, :MNSP_BIDOFFERPERIOD, :DISPATCH_MNSPBIDTRK, :DISPATCHINTERCONNECTORRES)
    uncached = filter(t -> !_table_is_cached(db, t), tables)
    isempty(uncached) || throw(
        ArgumentError(
            "set_mnsp_offers!: required MNSP input tables are not cached: $(join(uncached, ", ")). " *
                "Populate the requested intervals and the offer dates named by DISPATCH_MNSPBIDTRK.",
        )
    )
    links = read_mnsp_links(db, start_date)
    offers = read_mnsp_offers(db, date_range)
    flows = read_interconnector_limits(db, date_range; intervention)
    staged = NamedTuple[]
    for name in required
        device = devices[name]
        initial = sort(flows[flows.INTERCONNECTORID .== name, :], :SETTLEMENTDATE)
        from_area = get_name(get_from_area(device))
        to_area = get_name(get_to_area(device))
        group = links[links.INTERCONNECTORID .== name, :]
        nrow(group) == 2 || throw(ArgumentError("set_mnsp_offers!: MNSP $name requires two registered directional links, found $(nrow(group))"))
        directions = Set{String}()
        for link in eachrow(group)
            direction = if link.FROMREGION == from_area && link.TOREGION == to_area
                "forward"
            elseif link.FROMREGION == to_area && link.TOREGION == from_area
                "reverse"
            else
                throw(ArgumentError("set_mnsp_offers!: MNSP $name link $(link.LINKID) has incompatible endpoints"))
            end
            direction in directions && throw(ArgumentError("set_mnsp_offers!: MNSP $name has duplicate $direction links"))
            push!(directions, direction)
            for column in (:FROM_REGION_TLF, :TO_REGION_TLF, :MAXCAPACITY)
                value = link[column]
                value isa Real && isfinite(value) && value > 0 ||
                    throw(ArgumentError("set_mnsp_offers!: MNSP $name link $(link.LINKID) has invalid $column"))
            end
            link.LHSFACTOR isa Real && isfinite(link.LHSFACTOR) ||
                throw(ArgumentError("set_mnsp_offers!: MNSP $name link $(link.LINKID) has invalid LHSFACTOR"))
            rows = offers[offers.LINKID .== link.LINKID, :]
            rows.INTERVAL_DATETIME == intervals || throw(
                ArgumentError(
                    "set_mnsp_offers!: MNSP $name link $(link.LINKID) requires exactly one offer for every interval " *
                        "from $(first(intervals)) to $(last(intervals)); found $(nrow(rows)) rows for $(length(intervals)) intervals. " *
                        "Populate DISPATCH_MNSPBIDTRK and its referenced MNSP_DAYOFFER/MNSP_BIDOFFERPERIOD, including the previous month when required.",
                )
            )
            initial.SETTLEMENTDATE == intervals && all(v -> v isa Real && isfinite(v), initial.METEREDMWFLOW) ||
                throw(ArgumentError("set_mnsp_offers!: MNSP $name requires finite metered flow for every interval"))
            for row in eachrow(rows)
                for column in (:MAXAVAIL, :RAMPUPRATE, (Symbol("BANDAVAIL$i") for i in 1:10)..., (Symbol("PRICEBAND$i") for i in 1:10)...)
                    value = row[column]
                    valid = value isa Real && isfinite(value) && (startswith(string(column), "PRICEBAND") || value >= 0)
                    valid || throw(ArgumentError("set_mnsp_offers!: MNSP $name link $(link.LINKID) has invalid $column at $(row.INTERVAL_DATETIME)"))
                end
            end
            all(v -> ismissing(v) || (v isa Real && isfinite(v) && v >= 0), rows.FIXEDLOAD) ||
                throw(ArgumentError("set_mnsp_offers!: MNSP $name link $(link.LINKID) has invalid FIXEDLOAD"))
            push!(staged, (; device, direction, link, rows, initial, curves = [_mnsp_offer_curve(row) for row in eachrow(rows)]))
        end
    end
    for (; device, direction, link, rows, initial, curves) in staged
        if direction == "forward"
            replace_single_series!(sys, device, single_series("mnsp_initial_flow", start_date, Float64.(initial.METEREDMWFLOW), Minute(5)))
        end
        for (series, values) in (
                ("offer", curves), ("max_avail", Float64.(rows.MAXAVAIL)),
                ("ramp_rate", Float64.(rows.RAMPUPRATE)),
                ("fixed_load", Float64.(coalesce.(rows.FIXEDLOAD, 0.0))),
                ("fixed_load_invoked", Float64.(.!ismissing.(rows.FIXEDLOAD))),
            )
            series_name = mnsp_series_name(direction, series)
            replace_single_series!(sys, device, single_series(series_name, start_date, values, Minute(5)))
        end
        get_ext(device)["mnsp_$direction"] = Dict{String, Any}(
            "link_id" => link.LINKID, "from_region_tlf" => link.FROM_REGION_TLF,
            "to_region_tlf" => link.TO_REGION_TLF, "lhs_factor" => link.LHSFACTOR,
            "max_capacity" => link.MAXCAPACITY,
        )
    end
    return required
end


"""
    _mnsp_offer_curve(row) -> PSY.PiecewiseStepData

The offer curve of one `read_mnsp_offers` row: one step per band with a positive `BANDAVAIL`, in
band order. A row with no available band yields a single zero-width step.
"""
function _mnsp_offer_curve(row)
    avail = [Float64(row[Symbol("BANDAVAIL$i")]) for i in 1:10]
    prices = [Float64(row[Symbol("PRICEBAND$i")]) for i in 1:10]
    keep = avail .> 0
    any(keep) || return PiecewiseStepData([0.0, 0.0], [0.0])
    return PiecewiseStepData([0.0; cumsum(Float64.(avail[keep]))], Float64.(prices[keep]))
end
