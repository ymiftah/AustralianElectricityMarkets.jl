"""
    _extract_power_bids(row; keep_empty_bands = false)

Builds a `PiecewiseStepData` offer curve from a row's `PRICEBANDARRAY`/`BANDAVAILARRAY`
columns, reversing band order for `DIRECTION == "LOAD"` rows so the resulting curve stays
concave. Bands of zero availability are dropped unless `keep_empty_bands`, in which case every
band is a segment and segment `k` is always the same price band.
"""
function _extract_power_bids(row; keep_empty_bands::Bool = false)
    prices, quantities = row.PRICEBANDARRAY, row.BANDAVAILARRAY
    load = row.DIRECTION == "LOAD"
    if keep_empty_bands && length(prices) == length(quantities)
        order = load ? (length(quantities):-1:1) : eachindex(quantities)
        a = Float64[prices[i] for i in order]
        widths = quantities[order]
    else
        price_band_array, bandavail_array = copy(prices), copy(quantities)
        if load
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

# Attaches `values` as the series `name` on `device`, or removes a stale series of that name when
# `values` is `nothing`. Returns the key of the series, or `nothing`.
function _bid_field!(sys, device, name::AbstractString, values, start_date, resolution)
    if isnothing(values)
        remove_single_series!(sys, device, name)
        return nothing
    end
    return replace_single_series!(sys, device, single_series(name, start_date, values, resolution))
end


# The row index of each stamp of `stamps`.
_stamp_index(stamps) = Dict{DateTime, Int}(t => i for (i, t) in enumerate(stamps))

# `column` on `grid`: the value at each stamp of `index`, `absent` where it is missing or has no row.
function _on_grid(index::Dict{DateTime, Int}, column::AbstractVector, grid, absent::Float64)
    out = fill(absent, length(grid))
    for (k, t) in enumerate(grid)
        i = get(index, t, 0)
        i == 0 && continue
        v = column[i]
        ismissing(v) || (out[k] = Float64(v))
    end
    return out
end

# A numeric column on `grid`: zero where it is missing or absent.
_numeric_on_grid(index, column::AbstractVector, grid) = _on_grid(index, column, grid, 0.0)

# A numeric column on `grid`: `NaN` where it is missing or absent.
_nan_on_grid(index, column::AbstractVector, grid) = _on_grid(index, column, grid, NaN)

# The columns `names` of `rows` as one concretely typed `NamedTuple` per row.
function _typed_rows(rows, names::Tuple)
    return _typed_rows(NamedTuple{names}(map(n -> rows[!, n], names)))
end
function _typed_rows(columns::NamedTuple)
    return [NamedTuple{keys(columns)}(map(c -> c[i], values(columns))) for i in eachindex(first(columns))]
end

# An offer curve on `grid`: the curve at each stamp of `index`, or a zero-width curve on the
# prices of the earliest row where there is none.
function _curves_on_grid(index::Dict{DateTime, Int}, rows, grid)
    typed = _typed_rows(rows, (:PRICEBANDARRAY, :BANDAVAILARRAY, :DIRECTION))
    curves = [_extract_power_bids(row; keep_empty_bands = true) for row in typed]
    earliest = index[minimum(keys(index))]
    prices = get_y_coords(curves[earliest])
    absent = PiecewiseStepData(zeros(length(prices) + 1), copy(prices))
    return [(i = get(index, t, 0); i == 0 ? absent : curves[i]) for t in grid]
end

# Whether every row of `rows` holds NULL in `column`, or zero where `zero_is_null` (a fixed load of 0 is none).
function _all_null(rows, column::Symbol; zero_is_null::Bool = false)
    return all(rows[!, column]) do x
        ismissing(x) || (zero_is_null && iszero(x))
    end
end


# The `T1` to `T4` fast-start times at each stamp of `grid`, zero where missing or without a row.
function _fast_start_on_grid(index::Dict{DateTime, Int}, rows, grid)
    t1, t2, t3, t4 = rows.T1, rows.T2, rows.T3, rows.T4
    out = fill((0.0, 0.0, 0.0, 0.0), length(grid))
    for (k, t) in enumerate(grid)
        i = get(index, t, 0)
        i == 0 && continue
        out[k] = (
            Float64(coalesce(t1[i], 0.0)), Float64(coalesce(t2[i], 0.0)),
            Float64(coalesce(t3[i], 0.0)), Float64(coalesce(t4[i], 0.0)),
        )
    end
    return out
end

# One where `status` is `"ON"` at each stamp of `grid`, zero otherwise or without a row.
function _normal_on_grid(index::Dict{DateTime, Int}, status::AbstractVector, grid)
    out = zeros(length(grid))
    for (k, t) in enumerate(grid)
        i = get(index, t, 0)
        i != 0 && isequal(status[i], "ON") && (out[k] = 1.0)
    end
    return out
end


"""
    _write_energy_bid!(sys, device, direction, rows, grid, start_date, resolution) -> NEMEnergyBid

Writes the energy bid of `device` in `direction` from `rows` (its `BIDPEROFFER_D` and
`BIDDAYOFFER_D` rows of that direction, from [`read_offers`](@ref)) as one series per field, named by
[`bid_series_name`](@ref), on `grid`, and records it in the device's [`NEMOfferCost`](@ref). A NULL
field over every row is `nothing`; otherwise NULL intervals and intervals without a row hold zero,
except `fixed_load`, which holds `NaN` so that an unpublished loading is distinct from one of zero
and is `nothing` where every row is NULL or zero. Throws `ArgumentError` for a `MAXAVAIL` that is
missing or not finite.
"""
function _write_energy_bid!(sys, device, direction::BidDirection, rows, grid, start_date, resolution, offer_cost = _nem_offer_cost(device))
    name = get_name(device)
    _check_stamps_on_grid(rows.INTERVAL_DATETIME, grid, "energy bids for $name $(string(direction))")
    bad = findfirst(x -> ismissing(x) || !isfinite(x), rows.MAXAVAIL)
    isnothing(bad) || throw(
        ArgumentError(
            "set_market_bids!: $name has no finite MAXAVAIL at $(rows.INTERVAL_DATETIME[bad]); " *
                "repopulate BIDPEROFFER_D with populate(...; force_new = true)",
        ),
    )
    index = _stamp_index(rows.INTERVAL_DATETIME)
    field(f::Symbol) = bid_series_name(BidType.ENERGY, f, direction)
    series(f::Symbol, values) = _bid_field!(sys, device, field(f), values, start_date, resolution)
    stamp_values(column::Symbol) = _numeric_on_grid(index, rows[!, column], grid)
    fast_start = if _all_null(rows, :T1) && _all_null(rows, :T2) && _all_null(rows, :T3) && _all_null(rows, :T4)
        nothing
    else
        _fast_start_on_grid(index, rows, grid)
    end
    normal = _all_null(rows, :NORMALSTATUS) ? nothing : _normal_on_grid(index, rows.NORMALSTATUS, grid)
    bid = NEMEnergyBid(;
        direction,
        offer_curves = series(:offer_curves, _curves_on_grid(index, rows, grid)),
        max_avail = series(:max_avail, stamp_values(:MAXAVAIL)),
        roc_up = series(:roc_up, stamp_values(:ROCUP)),
        roc_down = series(:roc_down, stamp_values(:ROCDOWN)),
        fixed_load = series(:fixed_load, _all_null(rows, :FIXEDLOAD; zero_is_null = true) ? nothing : _nan_on_grid(index, rows.FIXEDLOAD, grid)),
        minimum_load = series(:minimum_load, _all_null(rows, :MINIMUMLOAD) ? nothing : stamp_values(:MINIMUMLOAD)),
        fast_start_profile = series(:fast_start_profile, fast_start),
        daily_energy_constraint = series(:daily_energy_constraint, _all_null(rows, :DAILYENERGYCONSTRAINT) ? nothing : stamp_values(:DAILYENERGYCONSTRAINT)),
        normal_status = series(:normal_status, normal),
        energy_limit = series(:energy_limit, _all_null(rows, :ENERGYLIMIT) ? nothing : stamp_values(:ENERGYLIMIT)),
    )
    _set_energy_bid!(offer_cost, bid)
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


# The validated trapezium of each row of `rows`, on `grid`, zero where there is no row.
function _trapezium_on_grid(index::Dict{DateTime, Int}, rows, grid)
    names = (:INTERVAL_DATETIME, :DUID, :DIRECTION, :ENABLEMENTMIN, :LOWBREAKPOINT, :HIGHBREAKPOINT, :ENABLEMENTMAX, :MAXAVAIL)
    typed = _typed_rows(rows, names)
    points = [Tuple(_fcas_trapezium_points(row)) for row in typed]
    return [(i = get(index, t, 0); i == 0 ? (0.0, 0.0, 0.0, 0.0) : points[i]) for t in grid]
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
    has_nem_unit_data(device) || throw(
        ArgumentError(
            "set_market_bids!: $(get_name(device)) has no NEM unit data; build it with nem_system",
        ),
    )
    _check_stamps_on_grid(rows.INTERVAL_DATETIME, grid, "FCAS $(service) $(direction) rows for $(get_name(device))")
    index = _stamp_index(rows.INTERVAL_DATETIME)
    field(f::Symbol) = bid_series_name(service, f, direction)
    series(f::Symbol, values) = _bid_field!(sys, device, field(f), values, start_date, resolution)
    trapezium = _trapezium_on_grid(index, rows, grid)
    bid = NEMFCASBid(;
        service, direction,
        offer_curves = series(:offer_curves, _curves_on_grid(index, rows, grid)),
        max_avail = series(:max_avail, _numeric_on_grid(index, rows.MAXAVAIL, grid)),
        trapezium = series(:trapezium, trapezium),
    )
    _set_fcas_bid!(_nem_offer_cost(device), bid)
    return bid
end


"""
    _check_registered_bids(device, registration, direction, rows, grid)

Throws `ArgumentError` naming `device` and `direction` when the device is registered at a stamp of
`grid` (its `registration`, see [`NEMRegistration`](@ref)) and has no row in `rows`.
"""
function _check_registered_bids(device, registration, direction::BidDirection, rows, grid)
    name = get_name(device)
    stamps = Set(rows.INTERVAL_DATETIME)
    missing_stamps = [t for t in grid if _is_registered(registration, t) && !(t in stamps)]
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
function _bid_device_energy!(sys, device, required, groups, grid, start_date, resolution)
    name = get_name(device)
    rows_of(direction::BidDirection) = get(groups, (name, BidType.ENERGY, string(direction)), nothing)
    if any(d -> isnothing(rows_of(d)), required)
        set_available!(device, false)
        return false
    end
    unit = _nem_unit_data(device)
    isnothing(unit) && throw(
        ArgumentError("set_market_bids!: $name has no NEM unit data; build it with nem_system"),
    )
    set_available!(device, true)
    registration = _require_unit_data(unit.registration, "registration", device)
    for direction in required
        _check_registered_bids(device, registration, direction, rows_of(direction), grid)
    end
    for direction in (BidDirection.GEN, BidDirection.LOAD)
        rows = rows_of(direction)
        isnothing(rows) && continue
        _write_energy_bid!(sys, device, direction, rows, grid, start_date, resolution, unit.offer)
    end
    return true
end


"""
    set_market_bids!(sys, db, date_range; markets = NEM_MARKETS, resolution = Minute(5)) -> (; added, excluded)

Stores the bids of each unit of `sys` for `date_range`. On a replay system (units carrying NEM unit
data, built by [`nem_network`](@ref) or `nem_system(db, NEMDEConfiguration(); date_range)`) it is one
[`read_offers`](@ref) read of the `markets`, written as one series per bid field
([`bid_series_name`](@ref)) and recorded on the unit's [`NEMOfferCost`](@ref) as
[`NEMEnergyBid`](@ref)s and [`NEMFCASBid`](@ref)s. The values are as offered: MW, \$/MWh at the
connection point and MW/min. A unit's loss factors, from which AEMSim refers its energy prices, are on
its [`NEMRegistration`](@ref) recorded by [`nem_network`](@ref).

On a system without NEM unit data, such as one built with [`RegionalNetworkConfiguration`](@ref), only
the energy bids are read and each bidding unit gets a `MarketBidCost` for PowerSimulations' own
formulations: the incremental offer curves of its `GEN` bid and the decremental curves of its `LOAD`
bid, as `SingleTimeSeries` in natural units. Each curve's prices are divided by the unit's loss
factor from [`read_loss_factors`](@ref), so they are referred to the regional reference node, and its
quantity is capped at the interval's `MAXAVAIL`. FCAS bids are not read and no service is added.

Generators bid `GEN`. Scheduled loads bid `LOAD`, and a non-scheduled load bids no energy; an available one
gets a zero `MAXAVAIL` series of the `LOAD` energy bid name instead. Storage
devices bid both directions. A unit missing a required energy direction is set unavailable. A
device bidding a required direction at a stamp of its registration without a row throws. FCAS bids are
recorded for every unit, and the FCAS services of `markets` are added by [`add_fcas_services!`](@ref).
A non-scheduled load with an FCAS bid is made available when it is commissioned. Repeat calls
replace the series and the bids of the same direction and service.

# Arguments
- `sys`: The `PowerSystems.System` object, with NEM unit data attached to the bidding units.
- `db`: The database connection.
- `date_range`: The intervals to read (half-open, the last stamp exclusive).
- `markets`: The `BidType`s to read; defaults to [`NEM_MARKETS`](@ref).
- `resolution`: The spacing of the series, which must match the intervals of `date_range`.

# Returns
`(; added, excluded)` as [`add_fcas_services!`](@ref) returns them.
"""
function set_market_bids!(
        sys, db, date_range;
        markets = NEM_MARKETS, resolution::Dates.Period = Minute(5),
    )
    if !_is_replay_system(sys)
        offers = read_offers(db, date_range; markets = (BidType.ENERGY,))
        factors = read_loss_factors(db; as_of = first(date_range), through = last(date_range) - resolution)
        return _set_regional_market_bids!(sys, offers, factors, date_range; resolution)
    end
    return _set_market_bids!(sys, read_offers(db, date_range; markets), date_range; markets, resolution)
end


# Whether any device of `sys` carries NEM unit data, as a replay system's devices do.
_is_replay_system(sys) = any(has_nem_unit_data, get_components(Device, sys))


# The energy offer curve of each stamp of `grid` from `rows`, with its prices divided by `loss_factor`
# and its quantity capped at the stamp's `MAXAVAIL` (zero where there is no row).
function _referred_curves_on_grid(rows, grid, loss_factor::Float64)
    index = _stamp_index(rows.INTERVAL_DATETIME)
    max_avail = _numeric_on_grid(index, rows.MAXAVAIL, grid)
    return map(_curves_on_grid(index, rows, grid), max_avail) do curve, cap
        return PiecewiseStepData(min.(get_x_coords(curve), cap), get_y_coords(curve) ./ loss_factor)
    end
end


"""
    _set_regional_market_bids!(sys, offers, factors, date_range; resolution = Minute(5)) -> (; added, excluded)

Gives each bidding unit of `sys` a `MarketBidCost` from the energy rows of `offers` (from
[`read_offers`](@ref)), as [`set_market_bids!`](@ref) does on a system without NEM unit data:
incremental curves from the `GEN` bid of a generator or storage unit, decremental curves from the
`LOAD` bid of a scheduled load or storage unit, referred by the loss factors of `factors` (from
[`read_loss_factors`](@ref)). A unit missing a required direction is set unavailable; a bidding unit
without a loss factor throws an `ArgumentError`. Non-scheduled loads are left as built.

# Returns
`(; added, excluded)`, both empty: no FCAS service is added.
"""
function _set_regional_market_bids!(sys, offers::DataFrame, factors::DataFrame, date_range; resolution::Dates.Period = Minute(5))
    start_date = first(date_range)
    grid = _replay_grid(date_range, resolution)
    offers = subset(offers, :BIDTYPE => ByRow(==(BidType.ENERGY)))
    if resolution != Minute(5)
        offers = _aggregate_offers(offers, resolution)
        subset!(offers, :INTERVAL_DATETIME => ByRow(t -> start_date <= t < last(date_range)))
    end
    groups = groupby(offers, [:DUID, :DIRECTION])
    loss_factor = Dict(String(r.DUID) => (gen = Float64(r.GEN_LOSS_FACTOR), load = Float64(r.LOAD_LOSS_FACTOR)) for r in eachrow(factors))
    unbid = String[]
    for device in (d for T in (Generator, ControllableLoad, Storage) for d in get_components(T, sys))
        device isa ControllableLoad && is_non_scheduled_load(device) && continue
        name = get_name(device)
        required = device isa Storage ? (BidDirection.GEN, BidDirection.LOAD) :
            device isa ControllableLoad ? (BidDirection.LOAD,) : (BidDirection.GEN,)
        rows = [get(groups, (name, string(direction)), nothing) for direction in required]
        if any(isnothing, rows)
            set_available!(device, false)
            push!(unbid, name)
            continue
        end
        haskey(loss_factor, name) || throw(
            ArgumentError("set_market_bids!: $name has no DUDETAILSUMMARY loss factor over $date_range"),
        )
        set_available!(device, true)
        set_operation_cost!(
            device,
            MarketBidCost(; no_load_cost = 0.0, start_up = (hot = 0.0, warm = 0.0, cold = 0.0), shut_down = 0.0),
        )
        for (direction, direction_rows) in zip(required, rows)
            _check_stamps_on_grid(direction_rows.INTERVAL_DATETIME, grid, "energy bids for $name $(string(direction))")
            gen = direction == BidDirection.GEN
            curves = _referred_curves_on_grid(direction_rows, grid, gen ? loss_factor[name].gen : loss_factor[name].load)
            prefix = gen ? "incremental" : "decremental"
            initial = gen ? zeros(length(grid)) : first.(get_y_coords.(curves))
            for series_name in ("$(prefix)_variable_cost", "$(prefix)_initial_input")
                remove_single_series!(sys, device, series_name)
            end
            cost_series = single_series("$(prefix)_variable_cost", start_date, curves, resolution)
            initial_series = single_series("$(prefix)_initial_input", start_date, initial, resolution)
            if gen
                set_incremental_variable_cost!(sys, device, cost_series, UnitSystem.NATURAL_UNITS)
                set_incremental_initial_input!(sys, device, initial_series)
            else
                set_decremental_variable_cost!(sys, device, cost_series, UnitSystem.NATURAL_UNITS)
                set_decremental_initial_input!(sys, device, initial_series)
            end
        end
    end
    isempty(unbid) || @warn "set_market_bids!: $(length(unbid)) unit(s) have no bid data for a required direction; setting to unavailable: $(join(unbid, ", "))"
    return (; added = String[], excluded = Dict{String, Vector{String}}())
end

# Stores the bids of `offers`, the [`read_offers`](@ref) rows of `date_range`, as [`set_market_bids!`](@ref)
# does. Subsets `offers` in place.
function _set_market_bids!(sys, offers::DataFrame, date_range; markets = NEM_MARKETS, resolution::Dates.Period = Minute(5))
    start_date = first(date_range)
    grid = _replay_grid(date_range, resolution)
    if resolution != Minute(5)
        offers = _aggregate_offers(offers, resolution)
        subset!(offers, :INTERVAL_DATETIME => ByRow(t -> start_date <= t < last(date_range)))
    end
    sys_units = Set(get_name(c) for T in (Generator, ControllableLoad, Storage) for c in get_components(T, sys))
    subset!(offers, :DUID => ByRow(in(sys_units)))

    groups = groupby(offers, [:DUID, :BIDTYPE, :DIRECTION])
    energy_rows(name, direction) = get(groups, (name, BidType.ENERGY, string(direction)), nothing)

    device_by_name = Dict{String, Device}(
        get_name(d) => d for T in (Generator, ControllableLoad, Storage) for d in get_components(T, sys)
    )
    fcas_types = filter(in(markets), FCAS_BID_TYPES)
    for (key, rows) in pairs(groups)
        service = key.BIDTYPE
        service in fcas_types || continue
        device = device_by_name[key.DUID]
        direction = BidDirection(key.DIRECTION)
        _write_fcas_bid!(sys, device, service, direction, rows, grid, start_date, resolution)
        if device isa ControllableLoad && is_non_scheduled_load(device) && is_commissioned(device) &&
                direction == BidDirection.LOAD
            set_available!(device, true)
        end
    end
    # Services must exist before energy availability is set, so a unit unavailable for energy keeps them.
    added, excluded = add_fcas_services!(sys; bid_types = fcas_types)

    unbid = String[]
    for gen in get_components(Generator, sys)
        _bid_device_energy!(sys, gen, (BidDirection.GEN,), groups, grid, start_date, resolution) ||
            push!(unbid, get_name(gen))
    end
    gen_bid_loads = String[]
    for load in get_components(ControllableLoad, sys)
        is_non_scheduled_load(load) && continue
        _bid_device_energy!(sys, load, (BidDirection.LOAD,), groups, grid, start_date, resolution) ||
            push!(isnothing(energy_rows(get_name(load), BidDirection.GEN)) ? unbid : gen_bid_loads, get_name(load))
    end
    for stor in get_components(Storage, sys)
        _bid_device_energy!(sys, stor, (BidDirection.GEN, BidDirection.LOAD), groups, grid, start_date, resolution) ||
            push!(unbid, get_name(stor))
    end

    # A non-scheduled load has no energy bid; its energy availability is held at zero MW on the bid grid.
    zero_availability = bid_series_name(BidType.ENERGY, :max_avail, BidDirection.LOAD)
    for load in get_components(ControllableLoad, sys)
        is_non_scheduled_load(load) && get_available(load) || continue
        _bid_field!(sys, load, zero_availability, zeros(length(grid)), start_date, resolution)
    end

    isempty(gen_bid_loads) || @warn "set_market_bids!: $(length(gen_bid_loads)) scheduled load(s) bid GEN, not LOAD (wholesale demand response); setting to unavailable: $(join(gen_bid_loads, ", "))"
    isempty(unbid) || @warn "set_market_bids!: $(length(unbid)) unit(s) have no bid data for a required direction; setting to unavailable: $(join(unbid, ", "))"

    return (; added, excluded)
end
