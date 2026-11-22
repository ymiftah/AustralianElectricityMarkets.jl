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
- `intervention`: the run of the metered flow: `0` for the pricing run. `1` for the physical run where the interval has one, else the pricing run.

# Returns
The names of the interconnectors that received offers. Regulated interconnectors require none.
"""
function set_mnsp_offers!(sys, db, date_range; intervention::Integer = 0)
    step(date_range) == Minute(5) ||
        throw(ArgumentError("set_mnsp_offers!: MNSP offers require five-minute data, got $(step(date_range))"))
    intervals = collect(date_range)[1:(end - 1)]
    isempty(intervals) && throw(ArgumentError("set_mnsp_offers!: the range contains no dispatch intervals"))
    start_date = first(date_range)
    fail(message) = throw(ArgumentError("set_mnsp_offers!: " * message))

    devices = @chain DataFrame(
        [
            (INTERCONNECTORID = get_name(d), device = d, from_area = get_name(get_from_area(d)), to_area = get_name(get_to_area(d)))
                for d in get_components(get_available, AreaInterchange, sys)
        ]; copycols = false
    ) begin
        leftjoin(select(read_interconnector_loss_parameters(db; as_of = start_date), :INTERCONNECTORID, :ICTYPE); on = :INTERCONNECTORID)
        leftjoin(
            select(read_interconnector_loss_parameters(db; as_of = last(intervals)), :INTERCONNECTORID, :ICTYPE => :END_ICTYPE);
            on = :INTERCONNECTORID,
        )
        sort(:INTERCONNECTORID)
    end
    for row in eachrow(subset(devices, :ICTYPE => ByRow(t -> !coalesce(t in ("MNSP", "REGULATED"), false))))
        fail("$(row.INTERCONNECTORID) has no valid ICTYPE at $start_date")
    end
    isempty(subset(devices, [:ICTYPE, :END_ICTYPE] => ByRow((a, b) -> !isequal(a, b)))) ||
        fail("ICTYPE differs between the first and last interval; split the run at the change")
    required = subset(devices, :ICTYPE => ByRow(==("MNSP")))
    isempty(required) && return String[]
    tables = (:MNSP_INTERCONNECTOR, :MNSP_DAYOFFER, :MNSP_BIDOFFERPERIOD, :DISPATCH_MNSPBIDTRK, :DISPATCHINTERCONNECTORRES)
    uncached = filter(t -> !_table_is_cached(db, t), tables)
    isempty(uncached) || fail(
        "required MNSP input tables are not cached: $(join(uncached, ", ")). " *
            "Populate the requested intervals and the offer dates named by DISPATCH_MNSPBIDTRK.",
    )

    # One row per link of a required MNSP; each interconnector must have exactly two.
    registered = innerjoin(required, read_mnsp_links(db, start_date); on = :INTERCONNECTORID)
    counts = @chain registered begin
        groupby(:INTERCONNECTORID)
        combine(nrow => :n)
        leftjoin(select(required, :INTERCONNECTORID), _; on = :INTERCONNECTORID)
        transform(:n => ByRow(n -> coalesce(n, 0)) => :n)
    end
    for row in eachrow(subset(counts, :n => ByRow(!=(2))))
        fail("MNSP $(row.INTERCONNECTORID) requires two registered directional links, found $(row.n)")
    end
    links = @chain registered begin
        transform(
            [:FROMREGION, :TOREGION, :from_area, :to_area] => ByRow(
                (f, t, from, to) -> f == from && t == to ? MNSPDirection.FORWARD : f == to && t == from ? MNSPDirection.REVERSE : missing,
            ) => :direction,
        )
        sort([:INTERCONNECTORID, :direction])
    end
    for row in eachrow(subset(links, :direction => ByRow(ismissing)))
        fail("MNSP $(row.INTERCONNECTORID) link $(row.LINKID) has incompatible endpoints")
    end
    duplicates = @chain links begin
        groupby([:INTERCONNECTORID, :direction])
        combine(nrow => :n)
        subset(:n => ByRow(>(1)))
    end
    for row in eachrow(duplicates)
        fail("MNSP $(row.INTERCONNECTORID) has duplicate $(lowercase(string(row.direction))) links")
    end
    is_positive(v) = v isa Real && isfinite(v) && v > 0
    for column in (:FROM_REGION_TLF, :TO_REGION_TLF, :MAXCAPACITY), row in eachrow(subset(links, column => ByRow(!is_positive)))
        fail("MNSP $(row.INTERCONNECTORID) link $(row.LINKID) has invalid $column")
    end
    for row in eachrow(subset(links, :LHSFACTOR => ByRow(v -> !(v isa Real && isfinite(v)))))
        fail("MNSP $(row.INTERCONNECTORID) link $(row.LINKID) has invalid LHSFACTOR")
    end

    # Offers: every link needs exactly one offer per interval, with valid bands, ramp and fixed load.
    offers = @chain read_mnsp_offers(db, date_range) begin
        semijoin(links; on = :LINKID)
        sort([:LINKID, :INTERVAL_DATETIME])
    end
    offer_coverage = @chain offers begin
        groupby(:LINKID)
        combine(:INTERVAL_DATETIME => (t -> t == intervals) => :complete, nrow => :n)
        leftjoin(links, _; on = :LINKID)
        transform(:complete => ByRow(c -> coalesce(c, false)) => :complete, :n => ByRow(n -> coalesce(n, 0)) => :n)
    end
    for row in eachrow(subset(offer_coverage, :complete => ByRow(!)))
        fail(
            "MNSP $(row.INTERCONNECTORID) link $(row.LINKID) requires exactly one offer for every interval " *
                "from $(first(intervals)) to $(last(intervals)); found $(row.n) rows for $(length(intervals)) intervals. " *
                "Populate DISPATCH_MNSPBIDTRK and its referenced MNSP_DAYOFFER/MNSP_BIDOFFERPERIOD, including the previous month when required.",
        )
    end
    link_names = Dict(links.LINKID .=> links.INTERCONNECTORID)
    nonnegative(v) = v isa Real && isfinite(v) && v >= 0
    finite(v) = v isa Real && isfinite(v)
    checks = [
        [(:MAXAVAIL, nonnegative), (:RAMPUPRATE, nonnegative)]
        [(Symbol("BANDAVAIL$i"), nonnegative) for i in 1:10]
        [(Symbol("PRICEBAND$i"), finite) for i in 1:10]
    ]
    for (column, valid) in checks, row in eachrow(subset(offers, column => ByRow(!valid)))
        fail("MNSP $(link_names[row.LINKID]) link $(row.LINKID) has invalid $column at $(row.INTERVAL_DATETIME)")
    end
    for row in eachrow(subset(offers, :FIXEDLOAD => ByRow(v -> !(ismissing(v) || nonnegative(v)))))
        fail("MNSP $(link_names[row.LINKID]) link $(row.LINKID) has invalid FIXEDLOAD")
    end

    # The forward link of each MNSP also carries the metered flow of the whole range.
    flows = @chain read_interconnector_limits(db, date_range; intervention) begin
        semijoin(required; on = :INTERCONNECTORID)
        sort([:INTERCONNECTORID, :SETTLEMENTDATE])
    end
    flow_coverage = @chain flows begin
        groupby(:INTERCONNECTORID)
        combine([:SETTLEMENTDATE, :METEREDMWFLOW] => ((t, f) -> t == intervals && all(finite, f)) => :complete)
        leftjoin(select(required, :INTERCONNECTORID), _; on = :INTERCONNECTORID)
    end
    for row in eachrow(subset(flow_coverage, :complete => ByRow(c -> !coalesce(c, false))))
        fail("MNSP $(row.INTERCONNECTORID) requires finite metered flow for every interval")
    end

    offer_groups = groupby(offers, :LINKID)
    flow_groups = groupby(flows, :INTERCONNECTORID)
    for link in eachrow(links)
        device = link.device
        rows = offer_groups[(link.LINKID,)]
        forward = link.direction == MNSPDirection.FORWARD
        tag = forward ? :forward : :reverse
        _remove_link_attributes!(sys, device, link.direction)
        if forward
            for old in (get_supplemental_attributes(NEMMNSPObservedState, device)::Vector{NEMMNSPObservedState})
                remove_supplemental_attribute!(sys, device, old)
            end
            initial = flow_groups[(link.INTERCONNECTORID,)].METEREDMWFLOW
            flow_key = replace_single_series!(
                sys, device, single_series(NEM_MNSP_SERIES.initial_flow, start_date, Float64.(initial), Minute(5)),
            )
            add_supplemental_attribute!(sys, device, NEMMNSPObservedState(; initial_flow = flow_key))
        end
        series(kind, values) = replace_single_series!(
            sys, device, single_series(getproperty(NEM_MNSP_SERIES, Symbol(tag, "_", kind)), start_date, values, Minute(5)),
        )
        curves = [_mnsp_offer_curve(row) for row in eachrow(rows)]
        offer_key = series("offer", curves)
        max_avail_key = series("max_avail", Float64.(rows.MAXAVAIL))
        ramp_key = series("ramp_rate", Float64.(rows.RAMPUPRATE))
        fixed_name = getproperty(NEM_MNSP_SERIES, Symbol(tag, "_fixed_load"))
        fixed_key = if all(ismissing, rows.FIXEDLOAD)
            remove_single_series!(sys, device, fixed_name)
            nothing
        else
            series("fixed_load", Float64[ismissing(v) ? NaN : Float64(v) for v in rows.FIXEDLOAD])
        end
        add_supplemental_attribute!(
            sys, device,
            NEMMNSPLink(;
                direction = link.direction, link_id = link.LINKID, from_region_tlf = link.FROM_REGION_TLF,
                to_region_tlf = link.TO_REGION_TLF, lhs_factor = link.LHSFACTOR, max_capacity = link.MAXCAPACITY,
            ),
        )
        add_supplemental_attribute!(
            sys, device,
            NEMMNSPBid(; direction = link.direction, offer_curves = offer_key, max_avail = max_avail_key, ramp_up = ramp_key, fixed_load = fixed_key),
        )
    end
    return required.INTERCONNECTORID
end


"""
    _remove_link_attributes!(sys, device, direction)

Removes the [`NEMMNSPLink`](@ref) and [`NEMMNSPBid`](@ref) of `device`'s `direction` link, so a repeat call
replaces them.
"""
function _remove_link_attributes!(sys, device, direction::MNSPDirection)
    for T in (NEMMNSPLink, NEMMNSPBid), attribute in collect(get_supplemental_attributes(T, device))
        attribute.direction == direction && remove_supplemental_attribute!(sys, device, attribute)
    end
    return
end


"""
    _mnsp_offer_curve(row) -> PSY.PiecewiseStepData

The offer curve of one `read_mnsp_offers` row: one step per band `1` to `10`, zero-width where `BANDAVAIL` is
zero, so step `k` is always `PRICEBAND<k>`.
"""
function _mnsp_offer_curve(row)
    avail = [Float64(row[Symbol("BANDAVAIL$i")]) for i in 1:10]
    prices = [Float64(row[Symbol("PRICEBAND$i")]) for i in 1:10]
    return PiecewiseStepData([0.0; cumsum(avail)], prices)
end
