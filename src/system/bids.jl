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
    _energy_market_bid_cost(device) -> MarketBidCost

A `MarketBidCost` with zero no-load and shut-down costs and no energy curves, for `device` to take
its energy bid. It keeps the FCAS services `device`'s service bids were added under by
[`set_fcas_bids!`](@ref).
"""
function _energy_market_bid_cost(device)
    cost = get_operation_cost(device)
    services = cost isa MarketBidCost ? get_ancillary_service_offers(cost) : Service[]
    return MarketBidCost(;
        no_load_cost = 0.0,
        start_up = (hot = 0.0, warm = 0.0, cold = 0.0),
        shut_down = 0.0,
        ancillary_service_offers = copy(services),
    )
end


"""
    _set_incremental_bid_cost!(sys, gen, gen_bids, start_date, resolution)

Sets `gen` available with a `MarketBidCost` and attaches its incremental
(generation-side) variable cost time series and initial input, derived from
`gen_bids.piecewise_step_data`. Shared by the generator and battery branches
of `set_market_bids!`.
"""
function _set_incremental_bid_cost!(sys, gen, gen_bids, start_date, resolution)
    set_available!(gen, true)
    set_operation_cost!(gen, _energy_market_bid_cost(gen))
    psd = copy(gen_bids.piecewise_step_data)
    time_series_data = single_series("variable_cost", start_date, psd, resolution)
    set_incremental_variable_cost!(sys, gen, time_series_data, UnitSystem.NATURAL_UNITS)
    time_series_incremental_initial_input = single_series("incremental_initial_input", start_date, zeros(size(psd)), resolution)
    set_incremental_initial_input!(sys, gen, time_series_incremental_initial_input)
    return
end


"""
    _set_decremental_bid_cost!(sys, device, load_bids, start_date, resolution)

Attaches the decremental (load-side) variable cost and initial input time series derived from
`load_bids.piecewise_step_data` to `device`, whose operation cost must already be a `MarketBidCost`
(set by `_set_incremental_bid_cost!` for a battery; a scheduled load's is replaced here). Shared by the
battery and scheduled-load branches of `set_market_bids!`.

# Arguments
- `sys`: The `PowerSystems.System` object.
- `device`: An `EnergyReservoirStorage` or `InterruptiblePowerLoad`.
- `load_bids`: The device's `LOAD` direction rows from `_massage_bids`.
- `start_date`: The first interval of the series.
- `resolution`: The series resolution.

# Returns
`nothing`.
"""
function _set_decremental_bid_cost!(sys, device, load_bids, start_date, resolution)
    set_available!(device, true)
    device isa InterruptiblePowerLoad && set_operation_cost!(device, _energy_market_bid_cost(device))
    psd = copy(load_bids.piecewise_step_data)
    time_series_data = single_series("decremental_variable_cost", start_date, psd, resolution)
    set_decremental_variable_cost!(sys, device, time_series_data, UnitSystem.NATURAL_UNITS)
    time_series_decremental_initial_input = single_series("decremental_initial_input", start_date, (first ∘ get_y_coords).(psd), resolution)
    set_decremental_initial_input!(sys, device, time_series_decremental_initial_input)
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

Adds market bid cost time series data to the system.

This function reads energy and price bid data for a specified date range from the
database, converts it into piecewise `MarketBidCost` variable cost time series, and
attaches it to `Generator`, scheduled `InterruptiblePowerLoad` (decremental bid only; a load that
bids `GEN` is made unavailable; a non-scheduled load is left as built) and `EnergyReservoirStorage`
components (the latter also
gets decremental/load-side bid costs, and each direction's energy `MAXAVAIL`, read back by
[`get_storage_energy_max_avail`](@ref)). Every curve has one segment per price band, in band order
(reversed for `LOAD`), bands of zero availability included as zero-width segments.

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
    sys_units = Set(get_name(c) for T in (Generator, InterruptiblePowerLoad, EnergyReservoirStorage) for c in get_components(T, sys))
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
            _set_incremental_bid_cost!(sys, gen, gen_bids, start_date, resolution)
        end
    end

    # Scheduled loads carry only a decremental (LOAD direction) offer. A load that bids GEN
    # (a wholesale demand response unit, whose response acts as supply) is not modelled.
    unbid_loads = String[]
    gen_bid_loads = String[]
    foreach(get_components(InterruptiblePowerLoad, sys)) do load
        is_non_scheduled_load(load) && return
        load_id = get_name(load)
        load_bids = get(padded, (load_id, "LOAD"), empty_bids)
        if DataFrames.isempty(load_bids)
            load_id in offered_units ? push!(gen_bid_loads, load_id) : push!(unbid_loads, load_id)
            set_available!(load, false)
        else
            _set_decremental_bid_cost!(sys, load, load_bids, start_date, resolution)
        end
    end
    isempty(gen_bid_loads) || @warn "set_market_bids!: $(length(gen_bid_loads)) scheduled load(s) bid GEN, not LOAD (wholesale demand response); setting to unavailable: $(join(gen_bid_loads, ", "))"
    isempty(unbid_loads) || @warn "set_market_bids!: $(length(unbid_loads)) scheduled load(s) have no bid data; setting to unavailable: $(join(unbid_loads, ", "))"

    # Then sets the batteries
    return foreach(get_components(EnergyReservoirStorage, sys)) do gen
        gen_id = get_name(gen)
        gen_bids = get(padded, (gen_id, "GEN"), empty_bids)
        load_bids = get(padded, (gen_id, "LOAD"), empty_bids)

        if DataFrames.isempty(gen_bids) || DataFrames.isempty(load_bids)
            @warn "No bid data for generator $(gen_id), setting to unavailable."
            set_available!(gen, false)
        else
            _set_incremental_bid_cost!(sys, gen, gen_bids, start_date, resolution)

            _set_decremental_bid_cost!(sys, gen, load_bids, start_date, resolution)

            _set_storage_energy_max_avail!(sys, gen, gen_bids, energy_max_avail_series_name(OfferSide.GEN), start_date, resolution)
            _set_storage_energy_max_avail!(sys, gen, load_bids, energy_max_avail_series_name(OfferSide.LOAD), start_date, resolution)
        end
    end
end


"""
    _set_storage_energy_max_avail!(sys, storage, bids, name, start_date, resolution)

Attaches `bids.MAXAVAIL` to `storage` as a `SingleTimeSeries` named `name`, per-unit of `sys`'s
system base. Throws an `ArgumentError` if any interval's `MAXAVAIL` is missing or not finite.

# Returns
`nothing`.
"""
function _set_storage_energy_max_avail!(sys, storage, bids, name::AbstractString, start_date, resolution)
    bad = findfirst(x -> ismissing(x) || !isfinite(x), bids.MAXAVAIL)
    isnothing(bad) || throw(
        ArgumentError(
            "set_market_bids!: $(get_name(storage)) has no finite $name at $(bids.INTERVAL_DATETIME[bad]); " *
                "repopulate BIDPEROFFER_D with populate(...; force_new = true)",
        ),
    )
    add_time_series!(
        sys, storage,
        single_series(name, start_date, Float64.(bids.MAXAVAIL) ./ get_base_power(sys), resolution),
    )
    return
end
