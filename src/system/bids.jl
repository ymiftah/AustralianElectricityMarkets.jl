"""
    _extract_power_bids(row; keep_empty_bands = false)

Builds a `PiecewiseStepData` offer curve from a row's `PRICEBANDARRAY`/`BANDAVAILARRAY`
columns, reversing band order for `DIRECTION == "LOAD"` rows so the resulting curve stays
concave. Bands of zero availability are dropped unless `keep_empty_bands`, in which case every
band is a segment and segment `k` is always the same price band.
"""
function _extract_power_bids(row; keep_empty_bands::Bool = false)
    prices, quantities = row.PRICEBANDARRAY, row.BANDAVAILARRAY
    if keep_empty_bands && length(prices) == length(quantities)
        order = row.DIRECTION == "LOAD" ? (length(quantities):-1:1) : eachindex(quantities)
        a = Float64[prices[i] for i in order]
        widths = quantities[order]
    else
        price_band_array, bandavail_array = copy(prices), copy(quantities)
        if row.DIRECTION == "LOAD"
            reverse!(price_band_array)
            reverse!(bandavail_array)
        end
        kept = keep_empty_bands ? trues(length(bandavail_array)) : bandavail_array .> 0
        a = Float64.(price_band_array[kept])
        widths = bandavail_array[kept]
    end
    b = [zero(eltype(prices)); cumsum(widths)]
    return PiecewiseStepData(b, a)
end


"""
    _replay_grid(date_range, resolution) -> Vector{DateTime}

The interval-ending stamps the replay setters write: from the first stamp of `date_range` up to its
last stamp less `resolution`, the exclusive end of the range.
"""
function _replay_grid(date_range, resolution)
    return collect(first(date_range):resolution:(last(date_range) - resolution))
end


# Throws `ArgumentError` if `stamps` repeats a stamp or has one outside `grid`; `label` names the input.
function _check_stamps_on_grid(stamps, grid, label::AbstractString)
    allunique(stamps) || throw(ArgumentError("$label has a duplicate INTERVAL_DATETIME"))
    on_grid = Set(grid)
    outside = [t for t in stamps if !(t in on_grid)]
    isempty(outside) || throw(ArgumentError("$label has INTERVAL_DATETIME outside the replay grid, e.g. $(first(outside))"))
    return
end


# Averages the offers of each `(SETTLEMENTDATE, DUID, DIRECTION, BIDTYPE)` within each `resolution`
# bucket, as the interval ending at or after each stamp. Quantities are averaged, the price bands
# and the other text fields are taken from the bucket's first row.
function _aggregate_offers(offers::DataFrame, resolution::Dates.Period)
    bucketed = copy(offers)
    bucketed.INTERVAL_DATETIME = ceil.(offers.INTERVAL_DATETIME, resolution)
    groups = groupby(bucketed, [:SETTLEMENTDATE, :INTERVAL_DATETIME, :DUID, :DIRECTION, :BIDTYPE])
    rows = [NamedTuple(Symbol(c) => _bucket_value(Symbol(c), sub[!, c]) for c in names(sub)) for sub in groups]
    return DataFrame(rows)
end

function _bucket_value(column::Symbol, values)
    column in (:SETTLEMENTDATE, :INTERVAL_DATETIME, :DUID, :DIRECTION, :BIDTYPE) && return first(values)
    column == :PRICEBANDARRAY && return first(values)
    column == :BANDAVAILARRAY && return [mean(getindex.(values, i)) for i in eachindex(first(values))]
    eltype(values) <: Union{Missing, Number} || return first(values)
    present = collect(skipmissing(values))
    return isempty(present) ? missing : mean(present)
end

# Stores the loss factors of each unit in `factors` in its `ext`, the values AEMSim refers
# energy prices by. Throws `ArgumentError` naming any unit with an energy offer and no factor.
function _store_loss_factors!(sys, offers, factors)
    lookup = Dict(String(r.DUID) => r for r in eachrow(factors))
    energy_units = unique(String.(offers.DUID[offers.BIDTYPE .== Ref(BidType.ENERGY)]))
    unknown = sort!([u for u in energy_units if !haskey(lookup, u)])
    isempty(unknown) || throw(ArgumentError("No DUDETAILSUMMARY loss factor for bid unit(s) $(join(unknown, ", "))."))
    for T in (Generator, ControllableLoad, Storage), device in get_components(T, sys)
        factor = get(lookup, get_name(device), nothing)
        isnothing(factor) && continue
        get_ext(device)["nem_gen_loss_factor"] = Float64(factor.GEN_LOSS_FACTOR)
        get_ext(device)["nem_load_loss_factor"] = Float64(factor.LOAD_LOSS_FACTOR)
    end
    return
end


# Attaches `values` as the series `name` on `device`, or removes a stale series of that name when
# `values` is `nothing`. Returns the key of the series, or `nothing`.
function _bid_field!(sys, device, name::AbstractString, values, start_date, resolution)
    if isnothing(values)
        remove_single_series!(sys, device, name)
        return nothing
    end
    replace_single_series!(sys, device, single_series(name, start_date, values, resolution))
    return _series_key(device, name)
end


# A numeric column on `grid`: the value at each stamp of `by_time`, zero where it is missing or absent.
_numeric_on_grid(by_time, grid, column::Symbol) =
    Float64[haskey(by_time, t) && !ismissing(by_time[t][column]) ? Float64(by_time[t][column]) : 0.0 for t in grid]

# An offer curve on `grid`: the curve at each stamp of `by_time`, or a zero-width curve on the
# prices of the earliest row where there is none.
function _curves_on_grid(by_time, grid)
    curves = Dict(t => _extract_power_bids(row; keep_empty_bands = true) for (t, row) in by_time)
    prices = get_y_coords(curves[minimum(keys(by_time))])
    absent = PiecewiseStepData(zeros(length(prices) + 1), copy(prices))
    return [get(curves, t, absent) for t in grid]
end

# Whether every row of `rows` holds NULL in `column`, or zero where `zero_is_null` (a fixed load of 0 is none).
function _all_null(rows, column::Symbol; zero_is_null::Bool = false)
    return all(rows[!, column]) do x
        ismissing(x) || (zero_is_null && iszero(x))
    end
end


"""
    _write_energy_bid!(sys, device, direction, rows, grid, start_date, resolution) -> NEMEnergyBid

Writes the energy bid of `device` in `direction` from `rows` (its `BIDPEROFFER_D` and
`BIDDAYOFFER_D` rows of that direction, from [`read_offers`](@ref)) as one series per field, named by
[`bid_series_name`](@ref), on `grid`, and records it in the device's [`NEMOfferCost`](@ref). A NULL
field over every row is `nothing`; otherwise NULL intervals and intervals without a row hold zero.
Throws `ArgumentError` for a `MAXAVAIL` that is missing or not finite.
"""
function _write_energy_bid!(sys, device, direction::BidDirection, rows, grid, start_date, resolution)
    name = get_name(device)
    _check_stamps_on_grid(rows.INTERVAL_DATETIME, grid, "energy bids for $name $(string(direction))")
    bad = findfirst(x -> ismissing(x) || !isfinite(x), rows.MAXAVAIL)
    isnothing(bad) || throw(
        ArgumentError(
            "set_market_bids!: $name has no finite MAXAVAIL at $(rows.INTERVAL_DATETIME[bad]); " *
                "repopulate BIDPEROFFER_D with populate(...; force_new = true)",
        ),
    )
    by_time = Dict(zip(rows.INTERVAL_DATETIME, eachrow(rows)))
    field(f::Symbol) = bid_series_name(BidType.ENERGY, f, direction)
    series(f::Symbol, values) = _bid_field!(sys, device, field(f), values, start_date, resolution)
    stamp_values(column::Symbol) = _numeric_on_grid(by_time, grid, column)
    fast_start = if _all_null(rows, :T1) && _all_null(rows, :T2) && _all_null(rows, :T3) && _all_null(rows, :T4)
        nothing
    else
        NTuple{4, Float64}[
            haskey(by_time, t) ? Tuple(Float64(coalesce(by_time[t][c], 0.0)) for c in (:T1, :T2, :T3, :T4)) : (0.0, 0.0, 0.0, 0.0)
                for t in grid
        ]
    end
    normal = _all_null(rows, :NORMALSTATUS) ? nothing :
        Float64[haskey(by_time, t) && isequal(by_time[t].NORMALSTATUS, "ON") ? 1.0 : 0.0 for t in grid]
    bid = NEMEnergyBid(;
        direction,
        offer_curves = series(:offer_curves, _curves_on_grid(by_time, grid)),
        max_avail = series(:max_avail, stamp_values(:MAXAVAIL)),
        roc_up = series(:roc_up, stamp_values(:ROCUP)),
        roc_down = series(:roc_down, stamp_values(:ROCDOWN)),
        fixed_load = series(:fixed_load, _all_null(rows, :FIXEDLOAD; zero_is_null = true) ? nothing : stamp_values(:FIXEDLOAD)),
        minimum_load = series(:minimum_load, _all_null(rows, :MINIMUMLOAD) ? nothing : stamp_values(:MINIMUMLOAD)),
        fast_start_profile = series(:fast_start_profile, fast_start),
        daily_energy_constraint = series(:daily_energy_constraint, _all_null(rows, :DAILYENERGYCONSTRAINT) ? nothing : stamp_values(:DAILYENERGYCONSTRAINT)),
        normal_status = series(:normal_status, normal),
        energy_limit = series(:energy_limit, _all_null(rows, :ENERGYLIMIT) ? nothing : stamp_values(:ENERGYLIMIT)),
    )
    _set_energy_bid!(get_operation_cost(device), bid)
    return bid
end


# The FCAS trapezium of one row, in MW, validated as [`FCASTrapezium`](@ref) is.
function _fcas_trapezium_points(row)
    points = FCASTrapeziumPoints(
        (
            _require_fcas_float(row, Val(:ENABLEMENTMIN)),
            _require_fcas_float(row, Val(:LOWBREAKPOINT)),
            _require_fcas_float(row, Val(:HIGHBREAKPOINT)),
            _require_fcas_float(row, Val(:ENABLEMENTMAX)),
        )
    )
    _validate_fcas_trapezium(
        FCASTrapezium(;
            enablement_min = points.enablement_min, low_breakpoint = points.low_breakpoint,
            high_breakpoint = points.high_breakpoint, enablement_max = points.enablement_max,
            max_avail = _require_fcas_float(row, Val(:MAXAVAIL)),
        ),
        () -> begin
            interval = hasproperty(row, :INTERVAL_DATETIME) ? " at $(row.INTERVAL_DATETIME)" : ""
            return "BIDPEROFFER_D DUID $(row.DUID) ($(row.DIRECTION))$interval"
        end,
    )
    return points
end


"""
    _write_fcas_bid!(sys, device, service, direction, rows, grid, start_date, resolution) -> NEMFCASBid

Writes the FCAS bid of `device` for `service` in `direction` from `rows` (its `BIDPEROFFER_D` and
`BIDDAYOFFER_D` rows of that market and direction) as one series per field, named by
[`bid_series_name`](@ref), on `grid`, and records it in the device's [`NEMOfferCost`](@ref). Intervals
without a row hold a zero-width curve, a zero `MAXAVAIL` and a zero trapezium. Throws `ArgumentError`
for a row whose trapezium is missing or out of order.
"""
function _write_fcas_bid!(sys, device, service::BidType, direction::BidDirection, rows, grid, start_date, resolution)
    get_operation_cost(device) isa NEMOfferCost || throw(
        ArgumentError(
            "set_market_bids!: $(get_name(device)) has a $(typeof(get_operation_cost(device))) operation cost; " *
                "bidding devices must be NEM device types with a NEMOfferCost",
        ),
    )
    _check_stamps_on_grid(rows.INTERVAL_DATETIME, grid, "FCAS $(service) $(direction) rows for $(get_name(device))")
    by_time = Dict(zip(rows.INTERVAL_DATETIME, eachrow(rows)))
    field(f::Symbol) = bid_series_name(service, f, direction)
    series(f::Symbol, values) = _bid_field!(sys, device, field(f), values, start_date, resolution)
    points = Dict(t => _fcas_trapezium_points(row) for (t, row) in by_time)
    trapezium = [haskey(points, t) ? Tuple(points[t]) : (0.0, 0.0, 0.0, 0.0) for t in grid]
    bid = NEMFCASBid(;
        service, direction,
        offer_curves = series(:offer_curves, _curves_on_grid(by_time, grid)),
        max_avail = series(:max_avail, _numeric_on_grid(by_time, grid, :MAXAVAIL)),
        trapezium = series(:trapezium, trapezium),
    )
    _set_fcas_bid!(get_operation_cost(device), bid)
    return bid
end


"""
    _check_registered_bids(name, direction, rows, grid, registered)

Throws `ArgumentError` naming `name` and `direction` when a unit registered at a stamp of `grid`
(see [`registration_spans`](@ref)) has no row in `rows`. A `nothing` `registered` checks nothing.
"""
function _check_registered_bids(name::AbstractString, direction::BidDirection, rows, grid, registered)
    isnothing(registered) && return
    stamps = Set(rows.INTERVAL_DATETIME)
    missing_stamps = [t for t in grid if _is_registered(registered, name, t) && !(t in stamps)]
    isempty(missing_stamps) || throw(
        ArgumentError(
            "set_market_bids!: $name $(string(direction)) has no energy offer at $(first(missing_stamps)) while registered; " *
                "repopulate BIDPEROFFER_D with populate(...; force_new = true)",
        ),
    )
    return
end


# The energy offer rows of `device`, keyed by direction, that are written: every direction present
# in `groups` (the rows of one unit by `(DUID, BIDTYPE, DIRECTION)`). Returns `false` and sets the
# device unavailable when a direction in `required` has no rows.
function _bid_device_energy!(sys, device, required, groups, grid, start_date, resolution, registered)
    name = get_name(device)
    rows_of(direction::BidDirection) = get(groups, (name, BidType.ENERGY, string(direction)), nothing)
    if any(d -> isnothing(rows_of(d)), required)
        set_available!(device, false)
        return false
    end
    get_operation_cost(device) isa NEMOfferCost || throw(
        ArgumentError(
            "set_market_bids!: $name has a $(typeof(get_operation_cost(device))) operation cost; " *
                "bidding devices must be NEM device types with a NEMOfferCost",
        ),
    )
    set_available!(device, true)
    for direction in required
        _check_registered_bids(name, direction, rows_of(direction), grid, registered)
    end
    for direction in (BidDirection.GEN, BidDirection.LOAD)
        rows = rows_of(direction)
        isnothing(rows) && continue
        _write_energy_bid!(sys, device, direction, rows, grid, start_date, resolution)
    end
    return true
end


"""
    set_market_bids!(sys, db, date_range; markets = NEM_MARKETS, registered = nothing, resolution = Minute(5)) -> (; added, excluded)

Stores the bids of each unit of `sys` for `date_range`: one [`read_offers`](@ref) read of the
`markets`, written as one series per bid field ([`bid_series_name`](@ref)) and recorded on the unit's
[`NEMOfferCost`](@ref) as [`NEMEnergyBid`](@ref)s and [`NEMFCASBid`](@ref)s. The values are as offered:
MW, \$/MWh at the connection point and MW/min. A unit's loss factors are kept in its `ext`
(`"nem_gen_loss_factor"` and `"nem_load_loss_factor"`), from which AEMSim refers its energy prices.

Generators bid `GEN`. Scheduled loads bid `LOAD`, and a non-scheduled load bids no energy. Storage
devices bid both directions. A unit missing a required energy direction is set unavailable. A
device bidding a required direction at a stamp of `registered` without a row throws. FCAS bids are
recorded for every unit, and the FCAS services of `markets` are added by [`add_fcas_services!`](@ref).
A non-scheduled load with an FCAS bid is made available when it is commissioned. Repeat calls
replace the series and the bids of the same direction and service.

# Arguments
- `sys`: The `PowerSystems.System` object, with NEM device types for the bidding units.
- `db`: The database connection.
- `date_range`: The intervals to read (half-open, the last stamp exclusive).
- `markets`: The `BidType`s to read; defaults to [`NEM_MARKETS`](@ref).
- `registered`: The registration span of each unit, from [`registration_spans`](@ref), or `nothing`.
- `resolution`: The spacing of the series, which must match the intervals of `date_range`.

# Returns
`(; added, excluded)` as [`add_fcas_services!`](@ref) returns them.
"""
function set_market_bids!(
        sys, db, date_range;
        markets = NEM_MARKETS, registered = nothing, resolution::Dates.Period = Minute(5),
    )
    start_date = first(date_range)
    grid = _replay_grid(date_range, resolution)
    offers = read_offers(db, date_range; markets)
    if resolution != Minute(5)
        offers = _aggregate_offers(offers, resolution)
        subset!(offers, :INTERVAL_DATETIME => ByRow(t -> start_date <= t < last(date_range)))
    end
    sys_units = Set(get_name(c) for T in (Generator, ControllableLoad, Storage) for c in get_components(T, sys))
    subset!(offers, :DUID => ByRow(in(sys_units)))
    factors = read_loss_factors(db; as_of = start_date, through = last(date_range) - step(date_range))
    _store_loss_factors!(sys, offers, factors)
    groups = Dict{Tuple{String, BidType, String}, SubDataFrame}(
        (String(k.DUID), k.BIDTYPE, String(k.DIRECTION)) => sub for (k, sub) in pairs(groupby(offers, [:DUID, :BIDTYPE, :DIRECTION]))
    )
    energy_rows(name, direction) = get(groups, (name, BidType.ENERGY, string(direction)), nothing)

    fcas_types = filter(in(markets), FCAS_BID_TYPES)
    for T in (Generator, ControllableLoad, Storage), device in get_components(T, sys)
        name = get_name(device)
        for service in fcas_types, direction in (BidDirection.GEN, BidDirection.LOAD, BidDirection.BIDIRECTIONAL)
            rows = get(groups, (name, service, string(direction)), nothing)
            isnothing(rows) && continue
            _write_fcas_bid!(sys, device, service, direction, rows, grid, start_date, resolution)
            if device isa ControllableLoad && is_non_scheduled_load(device) && is_commissioned(device) &&
                    direction == BidDirection.LOAD
                set_available!(device, true)
            end
        end
    end
    # Services must exist before energy availability is set, so a unit unavailable for energy keeps them.
    added, excluded = add_fcas_services!(sys; bid_types = fcas_types)

    unbid = String[]
    for gen in get_components(Generator, sys)
        _bid_device_energy!(sys, gen, (BidDirection.GEN,), groups, grid, start_date, resolution, registered) ||
            push!(unbid, get_name(gen))
    end
    gen_bid_loads = String[]
    for load in get_components(ControllableLoad, sys)
        is_non_scheduled_load(load) && continue
        _bid_device_energy!(sys, load, (BidDirection.LOAD,), groups, grid, start_date, resolution, registered) ||
            push!(isnothing(energy_rows(get_name(load), BidDirection.GEN)) ? unbid : gen_bid_loads, get_name(load))
    end
    for stor in get_components(Storage, sys)
        _bid_device_energy!(sys, stor, (BidDirection.GEN, BidDirection.LOAD), groups, grid, start_date, resolution, registered) ||
            push!(unbid, get_name(stor))
    end
    isempty(gen_bid_loads) || @warn "set_market_bids!: $(length(gen_bid_loads)) scheduled load(s) bid GEN, not LOAD (wholesale demand response); setting to unavailable: $(join(gen_bid_loads, ", "))"
    isempty(unbid) || @warn "set_market_bids!: $(length(unbid)) unit(s) have no bid data for a required direction; setting to unavailable: $(join(unbid, ", "))"

    return (; added, excluded)
end
