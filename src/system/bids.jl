"""
    _offer_curves(present, prices, avail, load::Bool) -> Vector{PiecewiseStepData}

The offer curve of each row of one bid on the dispatch grid, from its price band and band
availability columns (`prices` and `avail`, equal-length tuples of column vectors). Every band is a segment, so
segment `k` is always the same price band; a `load` bid's bands are reversed so the curve stays
concave. A row that is not `present` gets a zero-width curve on the prices of the first present row.
Consecutive rows with the same prices share one price vector.
"""
function _offer_curves(present, prices, avail, load::Bool)
    n = length(prices)
    length(avail) == n || throw(BoundsError(avail, n))
    order = load ? (n:-1:1) : (1:n)
    reference = findfirst(present)
    curves = Vector{PiecewiseStepData}(undef, length(present))
    shared, shared_row = Float64[], 0
    for k in eachindex(present)
        row = present[k] ? k : reference
        if shared_row == 0 || !_same_prices(prices, row, shared_row)
            shared, shared_row = Float64[prices[i][row] for i in order], row
        end
        breakpoints = zeros(n + 1)
        for (j, i) in enumerate(order)
            breakpoints[j + 1] = breakpoints[j] + (present[k] ? avail[i][k] : 0.0)
        end
        curves[k] = PiecewiseStepData(breakpoints, shared)
    end
    return curves
end

# Whether rows `a` and `b` of the band `prices` columns hold the same prices.
function _same_prices(prices, a::Int, b::Int)
    for column in prices
        isequal(column[a], column[b]) || return false
    end
    return true
end


"""
    _dispatch_grid(date_range, resolution) -> Vector{DateTime}

The interval-ending stamps the run setters write: from the first stamp of `date_range` up to its
last stamp less `resolution`, the exclusive end of the range.
"""
function _dispatch_grid(date_range, resolution)
    return collect(first(date_range):resolution:(last(date_range) - resolution))
end


# Throws `ArgumentError` if `offers` repeats a stamp of a `(DUID, BIDTYPE, DIRECTION)` or has one outside `grid`.
function _check_stamps_on_grid(offers::AbstractDataFrame, grid)
    duplicate = findfirst(nonunique(offers, [:DUID, :BIDTYPE, :DIRECTION, :INTERVAL_DATETIME]))
    isnothing(duplicate) || throw(
        ArgumentError(
            "offers for $(offers.DUID[duplicate]) $(offers.BIDTYPE[duplicate]) $(offers.DIRECTION[duplicate]) " *
                "have a duplicate INTERVAL_DATETIME at $(offers.INTERVAL_DATETIME[duplicate])",
        ),
    )
    outside = findfirst(!in(Set(grid)), offers.INTERVAL_DATETIME)
    isnothing(outside) || throw(
        ArgumentError(
            "offers for $(offers.DUID[outside]) have INTERVAL_DATETIME outside the dispatch grid, e.g. $(offers.INTERVAL_DATETIME[outside])",
        ),
    )
    return
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


# `offers` with a `HAS_ROW` column, `true` on every row, sharing the columns of `offers`.
_with_has_row(offers::AbstractDataFrame) = insertcols(offers, :HAS_ROW => true; copycols = false)

# The rows of one bid (with `HAS_ROW`, in time order, every stamp on `grid` and none repeated) on `grid`: the
# rows themselves when the bid covers every stamp, else a join onto `grid` with `HAS_ROW` false and the offer
# columns missing at the stamps the bid has no row.
function _bid_on_grid(rows::AbstractDataFrame, grid)
    nrow(rows) == length(grid) && issorted(rows.INTERVAL_DATETIME) && return rows
    return @chain DataFrame(INTERVAL_DATETIME = grid) begin
        leftjoin(rows; on = :INTERVAL_DATETIME, order = :left)
        transform!(:HAS_ROW => ByRow(isequal(true)) => :HAS_ROW)
    end
end

# The offer curve of each row of `on_grid`, one bid on the dispatch grid (see [`_offer_curves`](@ref)).
function _curves_on_grid(on_grid::AbstractDataFrame, direction::AbstractString)
    prices = Tuple(on_grid[!, c] for c in PRICE_BAND_COLUMNS)
    avail = Tuple(on_grid[!, c] for c in BAND_AVAIL_COLUMNS)
    return _offer_curves(on_grid.HAS_ROW, prices, avail, direction == "LOAD")
end

# Whether every row of `rows` holds NULL in `column`, or zero where `zero_is_null` (a fixed load of 0 is none).
function _all_null(rows, column::Symbol; zero_is_null::Bool = false)
    return all(rows[!, column]) do x
        ismissing(x) || (zero_is_null && iszero(x))
    end
end


"""
    _write_energy_bid!(sys, device, direction, on_grid, start_date, resolution) -> NEMEnergyBid

Writes the energy bid of `device` in `direction` from `on_grid` (its [`read_offers`](@ref) rows of that
direction on the dispatch grid, see [`_bid_on_grid`](@ref)) as one series per field, named by
[`bid_series_name`](@ref), and records it in the device's [`NEMOfferCost`](@ref). A NULL
field over every row is `nothing`; otherwise NULL intervals and intervals without a row hold zero,
except `fixed_load`, which holds `NaN` so that an unpublished loading is distinct from one of zero
and is `nothing` where every row is NULL or zero. Throws `ArgumentError` for a `MAXAVAIL` that is
missing or not finite.
"""
function _write_energy_bid!(sys, device, direction::BidDirection, on_grid, start_date, resolution, offer_cost = _nem_offer_cost(device))
    name = get_name(device)
    rows = view(on_grid, on_grid.HAS_ROW, :)
    bad = findfirst(x -> ismissing(x) || !isfinite(x), rows.MAXAVAIL)
    isnothing(bad) || throw(
        ArgumentError(
            "set_market_bids!: $name has no finite MAXAVAIL at $(rows.INTERVAL_DATETIME[bad]); " *
                "repopulate BIDPEROFFER_D with populate(...; force_new = true)",
        ),
    )
    zero_filled(column::Symbol) = Float64.(coalesce.(on_grid[!, column], 0.0))
    field(f::Symbol) = bid_series_name(BidType.ENERGY, f, direction)
    series(f::Symbol, values) = _bid_field!(sys, device, field(f), values, start_date, resolution)
    all_null(column::Symbol; zero_is_null::Bool = false) = _all_null(rows, column; zero_is_null)
    fast_start = if all_null(:T1) && all_null(:T2) && all_null(:T3) && all_null(:T4)
        nothing
    else
        collect(zip((zero_filled(c) for c in (:T1, :T2, :T3, :T4))...))
    end
    bid = NEMEnergyBid(;
        direction,
        offer_curves = series(:offer_curves, _curves_on_grid(on_grid, string(direction))),
        max_avail = series(:max_avail, zero_filled(:MAXAVAIL)),
        roc_up = series(:roc_up, zero_filled(:ROCUP)),
        roc_down = series(:roc_down, zero_filled(:ROCDOWN)),
        fixed_load = series(:fixed_load, all_null(:FIXEDLOAD; zero_is_null = true) ? nothing : Float64.(coalesce.(on_grid.FIXEDLOAD, NaN))),
        minimum_load = series(:minimum_load, all_null(:MINIMUMLOAD) ? nothing : zero_filled(:MINIMUMLOAD)),
        fast_start_profile = series(:fast_start_profile, fast_start),
        daily_energy_constraint = series(:daily_energy_constraint, all_null(:DAILYENERGYCONSTRAINT) ? nothing : zero_filled(:DAILYENERGYCONSTRAINT)),
        normal_status = series(:normal_status, all_null(:NORMALSTATUS) ? nothing : Float64.(isequal.(on_grid.NORMALSTATUS, "ON"))),
        energy_limit = series(:energy_limit, all_null(:ENERGYLIMIT) ? nothing : zero_filled(:ENERGYLIMIT)),
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


# The validated trapezium of each row of `on_grid`, zero where there is no row. The first row with a missing
# or out-of-order trapezium throws the error [`_fcas_trapezium_points`](@ref) gives it.
function _trapezium_on_grid(on_grid::AbstractDataFrame)
    columns = Tuple(on_grid[!, c] for c in (:ENABLEMENTMIN, :LOWBREAKPOINT, :HIGHBREAKPOINT, :ENABLEMENTMAX, :MAXAVAIL))
    bad = _first_bad_trapezium(on_grid.HAS_ROW, columns...)
    isnothing(bad) || _fcas_trapezium_points(NamedTuple(on_grid[bad, :]))
    return _trapezium_values(on_grid.HAS_ROW, columns...)
end

# The first present row whose trapezium is missing a point, out of order or has a negative `MAXAVAIL`.
function _first_bad_trapezium(present, emin, low, high, emax, avail)
    return findfirst(eachindex(present)) do i
        present[i] || return false
        any(ismissing, (emin[i], low[i], high[i], emax[i], avail[i])) && return true
        return !(emin[i] <= low[i] <= high[i] <= emax[i] && avail[i] >= 0)
    end
end

# The four trapezium points of each row, zero where the row is not present.
function _trapezium_values(present, emin, low, high, emax, _)
    return [
        present[i] ? (Float64(emin[i]), Float64(low[i]), Float64(high[i]), Float64(emax[i])) : (0.0, 0.0, 0.0, 0.0)
            for i in eachindex(present)
    ]
end


"""
    _write_fcas_bid!(sys, device, service, direction, on_grid, start_date, resolution) -> NEMFCASBid

Writes the FCAS bid of `device` for `service` in `direction` from `on_grid` (its [`read_offers`](@ref)
rows of that market and direction on the dispatch grid, see [`_bid_on_grid`](@ref)) as one series
per field, named by [`bid_series_name`](@ref), and records it in the device's [`NEMOfferCost`](@ref). Intervals
without a row hold a zero-width curve, a zero `MAXAVAIL` and a zero trapezium. Throws `ArgumentError`
for a row whose trapezium is missing or out of order.
"""
function _write_fcas_bid!(sys, device, service::BidType, direction::BidDirection, on_grid, start_date, resolution)
    has_nem_unit_data(device) || throw(
        ArgumentError(
            "set_market_bids!: $(get_name(device)) has no NEM unit data; build it with nem_system",
        ),
    )
    field(f::Symbol) = bid_series_name(service, f, direction)
    series(f::Symbol, values) = _bid_field!(sys, device, field(f), values, start_date, resolution)
    bid = NEMFCASBid(;
        service, direction,
        offer_curves = series(:offer_curves, _curves_on_grid(on_grid, string(direction))),
        max_avail = series(:max_avail, Float64.(coalesce.(on_grid.MAXAVAIL, 0.0))),
        trapezium = series(:trapezium, _trapezium_on_grid(on_grid)),
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


# Writes the energy bids of `device`, every direction present in `groups` (the rows of one unit by
# `(DUID, BIDTYPE, DIRECTION)`). Returns `false` and sets the device unavailable when a side of
# `energy_offer_sides(device)` has no rows.
function _bid_device_energy!(sys, device, groups, grid, start_date, resolution)
    name = get_name(device)
    required = BidDirection.(string.(energy_offer_sides(device)))
    rows_of(direction::BidDirection) = get(groups, (name, BidType.ENERGY, string(direction)), nothing)
    on_grid_of(direction::BidDirection) = _bid_on_grid(rows_of(direction), grid)
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
        isnothing(rows_of(direction)) && continue
        _write_energy_bid!(sys, device, direction, on_grid_of(direction), start_date, resolution, unit.offer)
    end
    return true
end


"""
    set_market_bids!(sys, db, date_range; markets = NEM_MARKETS, resolution = Minute(5)) -> (; added, excluded)

Stores the bids of each unit of `sys` for `date_range`. On a NEMDE system (units carrying NEM unit
data) the [`read_offers`](@ref) rows of `markets` are written as one series per bid field
([`bid_series_name`](@ref)) and recorded on the unit's [`NEMOfferCost`](@ref) as
[`NEMEnergyBid`](@ref)s and [`NEMFCASBid`](@ref)s, as offered: MW, `\$/MWh` at the connection point
and MW/min.

On a system without NEM unit data, such as a [`RegionalNetworkConfiguration`](@ref) system, only
energy bids are read: each bidding unit gets a `MarketBidCost` with the incremental curves of its
`GEN` bid and the decremental curves of its `LOAD` bid, prices divided by the loss factor of
[`read_loss_factors`](@ref) and quantities capped at `MAXAVAIL`. No FCAS service is added.

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
    if !_is_nemde_system(sys)
        offers = read_offers(db, date_range; markets = (BidType.ENERGY,))
        factors = read_loss_factors(db, date_range)
        return _set_regional_market_bids!(sys, offers, factors, date_range; resolution)
    end
    return _set_market_bids!(sys, read_offers(db, date_range; markets), date_range; markets, resolution)
end


# Whether any device of `sys` carries NEM unit data, as a NEMDE system's devices do.
_is_nemde_system(sys) = any(has_nem_unit_data, get_components(Device, sys))


# The energy offer curve of each stamp of `on_grid` (one bid in `direction` on the dispatch grid), with its prices
# divided by `loss_factor` and its quantity capped at the stamp's `MAXAVAIL` (zero where there is no row).
function _referred_curves_on_grid(on_grid, direction::BidDirection, loss_factor::Float64)
    max_avail = Float64.(coalesce.(on_grid.MAXAVAIL, 0.0))
    return map(_curves_on_grid(on_grid, string(direction)), max_avail) do curve, cap
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
    grid = _dispatch_grid(date_range, resolution)
    offers = @chain offers begin
        subset(:BIDTYPE => ByRow(==(BidType.ENERGY)))
        _aggregate_offers(resolution, date_range)
        _with_has_row
    end
    _check_stamps_on_grid(offers, grid)
    groups = groupby(offers, [:DUID, :DIRECTION])
    loss_factor = Dict(String(r.DUID) => (gen = Float64(r.GEN_LOSS_FACTOR), load = Float64(r.LOAD_LOSS_FACTOR)) for r in eachrow(factors))
    unbid = String[]
    for device in (d for T in (Generator, ControllableLoad, Storage) for d in get_components(T, sys))
        device isa ControllableLoad && is_non_scheduled_load(device) && continue
        name = get_name(device)
        required = BidDirection.(string.(energy_offer_sides(device)))
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
            gen = direction == BidDirection.GEN
            curves = _referred_curves_on_grid(
                _bid_on_grid(direction_rows, grid), direction, gen ? loss_factor[name].gen : loss_factor[name].load,
            )
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
# does.
function _set_market_bids!(sys, offers::DataFrame, date_range; markets = NEM_MARKETS, resolution::Dates.Period = Minute(5))
    start_date = first(date_range)
    grid = _dispatch_grid(date_range, resolution)
    sys_units = Set(get_name(c) for T in (Generator, ControllableLoad, Storage) for c in get_components(T, sys))
    offers = @chain offers begin
        _aggregate_offers(resolution, date_range)
        _with_has_row
        subset(:DUID => ByRow(in(sys_units)); view = true)
    end
    _check_stamps_on_grid(offers, grid)

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
        _write_fcas_bid!(sys, device, service, direction, _bid_on_grid(rows, grid), start_date, resolution)
        if device isa ControllableLoad && is_non_scheduled_load(device) && is_commissioned(device) &&
                direction == BidDirection.LOAD
            set_available!(device, true)
        end
    end
    # Services must exist before energy availability is set, so a unit unavailable for energy keeps them.
    added, excluded = add_fcas_services!(sys; bid_types = fcas_types)

    unbid = String[]
    gen_bid_loads = String[]
    for device in (d for T in (Generator, ControllableLoad, Storage) for d in get_components(T, sys))
        device isa ControllableLoad && is_non_scheduled_load(device) && continue
        _bid_device_energy!(sys, device, groups, grid, start_date, resolution) && continue
        bids_gen = device isa ControllableLoad && !isnothing(energy_rows(get_name(device), BidDirection.GEN))
        push!(bids_gen ? gen_bid_loads : unbid, get_name(device))
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
