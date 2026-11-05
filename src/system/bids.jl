"""
    _extract_power_bids(row; keep_empty_bands = false, price_factor = nothing, base_power = nothing)

Builds a `PiecewiseStepData` offer curve from a row's `PRICEBANDARRAY`/`BANDAVAILARRAY`
columns, reversing band order for `DIRECTION == "LOAD"` rows so the resulting curve stays
concave. Bands of zero availability are dropped unless `keep_empty_bands`, in which case every
band is a segment and segment `k` is always the same price band. When supplied, `price_factor`
divides prices before cent rounding and `base_power` divides cumulative MW breakpoints.
"""
function _extract_power_bids(row; keep_empty_bands::Bool = false, price_factor = nothing, base_power = nothing)
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
    if !isnothing(price_factor)
        for i in eachindex(a)
            a[i] = round(a[i] / price_factor; digits = 2)
        end
    end
    if !isnothing(base_power)
        # Base conversion must not hide a decrease in the original MW breakpoints.
        issorted(b) || PiecewiseStepData(b, a)
        b = Float64.(b) ./ base_power
    end
    return PiecewiseStepData(b, a)
end


"""
    _set_referred_bid_curves!(bids, factors; units = Set(bids.DUID)) -> bids

Builds energy curves with direction-specific loss factors and cent-rounded prices for
`units`. Other rows retain connection-point prices; every row's band quantities are validated.
Existing `piecewise_step_data` values are replaced.

# Arguments
- `bids`: raw prepared energy bids, modified in place.
- `factors`: unit generation and load loss factors from [`read_loss_factors`](@ref).
- `units`: names whose curves must have a loss factor.

# Returns
`bids`. Throws `ArgumentError` naming any required unit without a loss factor.
"""
function _set_referred_bid_curves!(bids, factors; units = Set(bids.DUID))
    lookup = Dict(r.DUID => (gen = r.GEN_LOSS_FACTOR, load = r.LOAD_LOSS_FACTOR) for r in eachrow(factors))
    transform!(
        bids,
        AsTable(:) => ByRow(
            r -> begin
                factor = if r.DUID in units && haskey(lookup, r.DUID)
                    r.DIRECTION == "LOAD" ? lookup[r.DUID].load : lookup[r.DUID].gen
                else
                    nothing
                end
                return _extract_power_bids(r; keep_empty_bands = true, price_factor = factor)
            end
        ) => :piecewise_step_data,
    )
    unknown = [name for name in unique(bids.DUID) if name in units && !haskey(lookup, name)]
    isempty(unknown) ||
        throw(ArgumentError("No DUDETAILSUMMARY loss factor for bid unit(s) $(join(unknown, ", "))."))
    return bids
end


"""
    _write_energy_bid!(sys, device, bids, side, start_date, resolution)

Sets `device` available and stores its energy offer on `side`: the `MAXAVAIL` of `bids`, per-unit
of the system base, as the series [`energy_max_avail_series_name`](@ref) names for `device` and
`side`, then the curves of `bids.piecewise_step_data` through [`set_energy_offer!`](@ref). Both series replace any of the same
name. Throws an `ArgumentError` if `device`'s operation cost is not a [`NEMOfferCost`](@ref), or if any
interval's `MAXAVAIL` is missing or not finite.

# Arguments
- `sys`: The `PowerSystems.System` object.
- `device`: a NEM device type.
- `bids`: the device's rows for `side` from `_pad_bids_to_grid`.
- `side`: the [`OfferSide`](@ref) of the bids.
- `start_date`: The first interval of the series.
- `resolution`: The series resolution.

# Returns
`nothing`.
"""
function _write_energy_bid!(sys, device, bids, side::OfferSide, start_date, resolution)
    get_operation_cost(device) isa NEMOfferCost || throw(
        ArgumentError(
            "set_market_bids!: $(get_name(device)) has a $(typeof(get_operation_cost(device))) operation cost; " *
                "bidding devices must be NEM device types with a NEMOfferCost",
        ),
    )
    set_available!(device, true)
    name = energy_max_avail_series_name(device, side)
    bad = findfirst(x -> ismissing(x) || !isfinite(x), bids.MAXAVAIL)
    isnothing(bad) || throw(
        ArgumentError(
            "set_market_bids!: $(get_name(device)) has no finite $name at $(bids.INTERVAL_DATETIME[bad]); " *
                "repopulate BIDPEROFFER_D with populate(...; force_new = true)",
        ),
    )
    replace_single_series!(
        sys, device,
        single_series(name, start_date, Float64.(bids.MAXAVAIL) ./ get_base_power(sys), resolution),
    )
    set_energy_offer!(sys, device, side, single_series(energy_offer_series_name(side), start_date, copy(bids.piecewise_step_data), resolution))
    return
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


"""
    _pad_bids_to_grid(group, grid) -> DataFrame

Pads one `(DUID, DIRECTION)` group of energy bids to every stamp of `grid`. An absent stamp has
`MAXAVAIL` zero and a zero-width curve on the group's first prices, so the unit offers nothing there.
Throws an `ArgumentError` for a duplicated stamp or one outside `grid`.

# Arguments
- `group`: the bids of one unit and direction, with `INTERVAL_DATETIME`, `MAXAVAIL` and
  `piecewise_step_data`.
- `grid`: the interval-ending stamps of the replay chunk.

# Returns
A `DataFrame` with `DUID`, `DIRECTION`, `INTERVAL_DATETIME`, `MAXAVAIL` and `piecewise_step_data`,
one row per stamp of `grid`.
"""
function _pad_bids_to_grid(group::AbstractDataFrame, grid)
    duid, direction = first(group.DUID), first(group.DIRECTION)
    _check_stamps_on_grid(group.INTERVAL_DATETIME, grid, "energy bids for $duid $direction")
    by_time = Dict(zip(group.INTERVAL_DATETIME, eachrow(group)))
    prices = get_y_coords(first(group.piecewise_step_data))
    absent = PiecewiseStepData(zeros(length(prices) + 1), copy(prices))
    return DataFrame(
        DUID = fill(duid, length(grid)),
        DIRECTION = fill(direction, length(grid)),
        INTERVAL_DATETIME = collect(grid),
        MAXAVAIL = [haskey(by_time, t) ? by_time[t].MAXAVAIL : 0.0 for t in grid],
        piecewise_step_data = [haskey(by_time, t) ? by_time[t].piecewise_step_data : absent for t in grid],
    )
end


"""
    set_market_bids!(sys, db, date_range; kwargs...)

Stores each unit's energy offers on its NEM device type. It reads energy and price bid data for a
specified date range from the database and, through [`set_energy_offer!`](@ref), attaches each
bid's curves and `MAXAVAIL` series to the `Generator`s, scheduled `ControllableLoad`s (decremental bid only; a load that
bids `GEN` is made unavailable; a non-scheduled load is left as built) and `Storage` devices
of `sys` (the latter also get the load-side bid, and each direction's energy `MAXAVAIL`, read back by
[`get_storage_energy_max_avail`](@ref)). Every curve has one segment per price band, in band order
(reversed for `LOAD`), bands of zero availability included as zero-width segments. A repeat call
replaces the series and keeps one [`NEMEnergyBid`](@ref) per side. The devices must be NEM types, as
[`nem_network`](@ref) builds them.

# Arguments
- `sys`: The `PowerSystems.System` object.
- `db`: The database connection.
- `date_range`: A range of dates for which to fetch the data.
- `kwargs`: Additional keyword arguments passed to `_massage_bids` (e.g. `resolution`).

# Loss factors
Energy bid prices are connection-point prices and are always divided by the unit's loss factor,
resolved over the chunk by [`read_loss_factors`](@ref) (one factor per unit for the whole range;
a warning flags a change inside it), which refers the bids to the regional reference node as NEMDE
does. The MW axis, FCAS bids and physical limits are untouched. A bidding generator, scheduled
load or battery of `sys` with no `DUDETAILSUMMARY` row in the window throws an `ArgumentError`.

# Grid
Each `(DUID, DIRECTION)` series spans every interval of `date_range` but its last stamp. An interval
without an offer, such as one before the unit's registration, is zero `MAXAVAIL` with a zero-width
curve (see `_pad_bids_to_grid`); a gap inside a registration is caught before this function runs.
"""
function set_market_bids!(sys, db, date_range; kwargs...)
    start_date = first(date_range)
    end_date = last(date_range)
    resolution = get(kwargs, :resolution, Minute(5))

    bids = _massage_bids(db, start_date, end_date; resolution = get(kwargs, :resolution, nothing))
    sys_units = Set(get_name(c) for T in (Generator, ControllableLoad, Storage) for c in get_components(T, sys))
    factors = read_loss_factors(db; as_of = start_date, through = last(date_range) - step(date_range))
    # Validate band quantities even for units absent from the constructed system.
    _set_referred_bid_curves!(bids, factors; units = sys_units)
    subset!(bids, :DUID => ByRow(in(sys_units)))

    grid = _replay_grid(date_range, resolution)
    by_unit_side = groupby(bids, [:DUID, :DIRECTION]; sort = false)
    padded = Dict{Tuple{String, String}, DataFrame}(
        (String(key.DUID), String(key.DIRECTION)) => _pad_bids_to_grid(sub, grid) for (key, sub) in pairs(by_unit_side)
    )
    empty_bids = view(bids, Int[], :)
    offered_units = Set(bids.DUID)

    # Sets all generator subtype first
    foreach(get_components(Generator, sys)) do gen
        gen_id = get_name(gen)
        gen_bids = get(padded, (gen_id, "GEN"), empty_bids)
        if DataFrames.isempty(gen_bids)
            @warn "No bid data for generator $(gen_id), setting to unavailable."
            set_available!(gen, false)
        else
            _write_energy_bid!(sys, gen, gen_bids, OfferSide.GEN, start_date, resolution)
        end
    end

    # Scheduled loads carry only a decremental (LOAD direction) offer. A load that bids GEN
    # (a wholesale demand response unit, whose response acts as supply) is not modelled.
    unbid_loads = String[]
    gen_bid_loads = String[]
    foreach(get_components(ControllableLoad, sys)) do load
        is_non_scheduled_load(load) && return
        load_id = get_name(load)
        load_bids = get(padded, (load_id, "LOAD"), empty_bids)
        if DataFrames.isempty(load_bids)
            load_id in offered_units ? push!(gen_bid_loads, load_id) : push!(unbid_loads, load_id)
            set_available!(load, false)
        else
            _write_energy_bid!(sys, load, load_bids, OfferSide.LOAD, start_date, resolution)
        end
    end
    isempty(gen_bid_loads) || @warn "set_market_bids!: $(length(gen_bid_loads)) scheduled load(s) bid GEN, not LOAD (wholesale demand response); setting to unavailable: $(join(gen_bid_loads, ", "))"
    isempty(unbid_loads) || @warn "set_market_bids!: $(length(unbid_loads)) scheduled load(s) have no bid data; setting to unavailable: $(join(unbid_loads, ", "))"

    # Then sets the batteries
    return foreach(get_components(Storage, sys)) do gen
        gen_id = get_name(gen)
        gen_bids = get(padded, (gen_id, "GEN"), empty_bids)
        load_bids = get(padded, (gen_id, "LOAD"), empty_bids)

        if DataFrames.isempty(gen_bids) || DataFrames.isempty(load_bids)
            @warn "No bid data for generator $(gen_id), setting to unavailable."
            set_available!(gen, false)
        else
            _write_energy_bid!(sys, gen, gen_bids, OfferSide.GEN, start_date, resolution)
            _write_energy_bid!(sys, gen, load_bids, OfferSide.LOAD, start_date, resolution)
        end
    end
end
