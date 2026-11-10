# TODO This module is hard to read. it would be easier to read if more operations were done with DtaFrames jl interfaces
# with only conversion to our types as a last stage.


"""
    set_mnsp_offers!(sys, db, date_range; intervention = 0) -> Vector{String}

Attaches the offers and link data of each available MNSP interconnector. Standing
`INTERCONNECTORCONSTRAINT.ICTYPE` data determines which interconnectors require offers.

Each `PSY.AreaInterchange` of an MNSP receives, per direction, a [`NEMMNSPLink`](@ref) (the link's
registration) and a [`NEMMNSPBid`](@ref) whose keys hold the cumulative price bands and their
`MAXAVAIL` in MW, the `RAMPUPRATE` in MW/min as published, and the `FIXEDLOAD` in MW, NaN where it is
NULL (a numeric zero is an active fixed loading of zero). The forward link's
`METEREDMWFLOW` in MW, selected by `intervention`, is held by a [`NEMMNSPObservedState`](@ref).
The forward link's direction is the interchange's `from_area` to its `to_area`.

Every link must have complete, valid inputs on the five-minute interval grid; missing or invalid
inputs, or an `ICTYPE` that differs between the first and last interval, throw `ArgumentError`
before any offers in `sys` are changed. Calling it again replaces earlier data, which requires
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
        tag = Symbol(direction)
        _remove_link_attributes!(sys, device, direction)
        if direction == "forward"
            for old in (get_supplemental_attributes(NEMMNSPObservedState, device)::Vector{NEMMNSPObservedState})
                remove_supplemental_attribute!(sys, device, old)
            end
            replace_single_series!(sys, device, single_series(NEM_MNSP_SERIES.initial_flow, start_date, Float64.(initial.METEREDMWFLOW), Minute(5)))
        end
        for (kind, values) in (
                ("offer", curves), ("max_avail", Float64.(rows.MAXAVAIL)),
                ("ramp_rate", Float64.(rows.RAMPUPRATE)),
            )
            series_name = getproperty(NEM_MNSP_SERIES, Symbol(direction, "_", kind))
            replace_single_series!(sys, device, single_series(series_name, start_date, values, Minute(5)))
        end
        fixed_name = getproperty(NEM_MNSP_SERIES, Symbol(direction, "_fixed_load"))
        if all(ismissing, rows.FIXEDLOAD)
            remove_single_series!(sys, device, fixed_name)
        else
            fixed = Float64[ismissing(v) ? NaN : Float64(v) for v in rows.FIXEDLOAD]
            replace_single_series!(sys, device, single_series(fixed_name, start_date, fixed, Minute(5)))
        end


        add_supplemental_attribute!(
            sys, device,
            NEMMNSPLink(;
                direction = tag == :forward ? MNSPDirection.FORWARD : MNSPDirection.REVERSE,
                link_id = link.LINKID, from_region_tlf = link.FROM_REGION_TLF, to_region_tlf = link.TO_REGION_TLF,
                lhs_factor = link.LHSFACTOR, max_capacity = link.MAXCAPACITY,
            ),
        )
        add_supplemental_attribute!(
            sys, device,
            NEMMNSPBid(;
                direction = tag == :forward ? MNSPDirection.FORWARD : MNSPDirection.REVERSE,
                offer_curves = _series_key(device, getproperty(NEM_MNSP_SERIES, Symbol(direction, "_offer"))),
                max_avail = _series_key(device, getproperty(NEM_MNSP_SERIES, Symbol(direction, "_max_avail"))),
                ramp_up = _series_key(device, getproperty(NEM_MNSP_SERIES, Symbol(direction, "_ramp_rate"))),
                fixed_load = all(ismissing, rows.FIXEDLOAD) ? nothing : _series_key(device, fixed_name),
            ),
        )
        if direction == "forward"
            add_supplemental_attribute!(
                sys, device, NEMMNSPObservedState(; initial_flow = _series_key(device, NEM_MNSP_SERIES.initial_flow)),
            )
        end
    end
    return required
end


"""
    _remove_link_attributes!(sys, device, direction)

Removes the [`NEMMNSPLink`](@ref) and [`NEMMNSPBid`](@ref) of `device`'s `direction` link, so a repeat call
replaces them.
"""
function _remove_link_attributes!(sys, device, direction::AbstractString)
    dir = direction == "forward" ? MNSPDirection.FORWARD : MNSPDirection.REVERSE
    for T in (NEMMNSPLink, NEMMNSPBid), attribute in collect(get_supplemental_attributes(T, device))
        attribute.direction == dir && remove_supplemental_attribute!(sys, device, attribute)
    end
    return
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
