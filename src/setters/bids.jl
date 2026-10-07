"""
    _set_incremental_bid_cost!(sys, gen, gen_bids, start_date, resolution)

Sets `gen` available with a `MarketBidCost` and attaches its incremental
(generation-side) variable cost time series and initial input, derived from
`gen_bids.piecewise_step_data`. Shared by the generator and battery branches
of `set_market_bids!`.
"""
function _set_incremental_bid_cost!(sys, gen, gen_bids, start_date, resolution)
    set_available!(gen, true)
    set_operation_cost!(
        gen,
        MarketBidCost(;
            no_load_cost = 0.0,
            start_up = (hot = 0.0, warm = 0.0, cold = 0.0),
            shut_down = 0.0,
        )
    )
    psd = gen_bids.piecewise_step_data
    time_series_data = Deterministic(;
        name = "variable_cost",
        data = Dict(start_date => psd),
        resolution = resolution,
        interval = resolution
    )
    set_incremental_variable_cost!(sys, gen, time_series_data, UnitSystem.NATURAL_UNITS)
    time_series_incremental_initial_input = Deterministic(;
        name = "incremental_initial_input",
        data = Dict(start_date => zeros(size(psd))),
        resolution = resolution,
        interval = resolution
    )
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
    device isa InterruptiblePowerLoad && set_operation_cost!(
        device,
        MarketBidCost(;
            no_load_cost = 0.0,
            start_up = (hot = 0.0, warm = 0.0, cold = 0.0),
            shut_down = 0.0,
        ),
    )
    psd = load_bids.piecewise_step_data
    time_series_data = Deterministic(;
        name = "decremental_variable_cost",
        data = Dict(start_date => psd),
        resolution = resolution,
        interval = resolution,
    )
    set_decremental_variable_cost!(sys, device, time_series_data, UnitSystem.NATURAL_UNITS)
    time_series_decremental_initial_input = Deterministic(;
        name = "decremental_initial_input",
        data = Dict(start_date => (first ∘ get_y_coords).(psd)),
        resolution = resolution,
        interval = resolution,
    )
    set_decremental_initial_input!(sys, device, time_series_decremental_initial_input)
    return
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
[`get_storage_energy_max_avail`](@ref)).

# Arguments
- `sys`: The `PowerSystems.System` object.
- `db`: The database connection.
- `date_range`: A range of dates for which to fetch the data.
- `loss_factors`: refer energy bid prices to the reference node (see below). Default `true`.
- `kwargs`: Additional keyword arguments passed to `_massage_bids` (e.g. `resolution`).

# Loss factors
Energy bid prices are connection-point prices. With `loss_factors = true` (the default) each
price is divided by the unit's loss factor, resolved as of `first(date_range)` by
[`read_loss_factors`](@ref) (one factor per unit for the whole range; a warning flags a change
inside it), which refers the bid to the regional reference node as NEMDE does.
The MW axis, FCAS bids and physical limits are untouched. A bidding generator, scheduled load or battery of `sys` with no
`DUDETAILSUMMARY` row in force throws an `ArgumentError`. Pass `loss_factors = false` to keep the raw
connection-point prices.
"""
function set_market_bids!(sys, db, date_range; loss_factors::Bool = true, kwargs...)
    start_date = first(date_range)
    end_date = last(date_range)
    resolution = get(kwargs, :resolution, Minute(5))

    energy_bids_table = read_hive(db, :BIDPEROFFER_D)
    pricebids_table = read_hive(db, :BIDDAYOFFER_D)
    bids = _massage_bids(db, energy_bids_table, pricebids_table, start_date, end_date; resolution = get(kwargs, :resolution, nothing))
    if loss_factors
        sys_units = Set(get_name(c) for T in (Generator, InterruptiblePowerLoad, EnergyReservoirStorage) for c in get_components(T, sys))
        factors = read_loss_factors(db; as_of = start_date, through = end_date)
        _refer_bids_to_reference_node!(subset!(bids, :DUID => ByRow(in(sys_units))), factors)
    end

    # Sets all generator subtype first
    foreach(get_components(Generator, sys)) do gen
        gen_id = get_name(gen)
        gen_bids = subset(bids, :DUID => ByRow(==(gen_id)), :DIRECTION => ByRow(==("GEN")))
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
        _is_non_scheduled_load(load) && return
        load_id = get_name(load)
        load_bids = subset(bids, :DUID => ByRow(==(load_id)), :DIRECTION => ByRow(==("LOAD")))
        if DataFrames.isempty(load_bids)
            any(==(load_id), bids.DUID) ? push!(gen_bid_loads, load_id) : push!(unbid_loads, load_id)
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
        gen_bids = subset(bids, :DUID => ByRow(==(gen_id)), :DIRECTION => ByRow(==("GEN")))
        load_bids = subset(bids, :DUID => ByRow(==(gen_id)), :DIRECTION => ByRow(==("LOAD")))

        if DataFrames.isempty(gen_bids) || DataFrames.isempty(load_bids)
            @warn "No bid data for generator $(gen_id), setting to unavailable."
            set_available!(gen, false)
        else
            _set_incremental_bid_cost!(sys, gen, gen_bids, start_date, resolution)

            _set_decremental_bid_cost!(sys, gen, load_bids, start_date, resolution)

            _set_storage_energy_max_avail!(sys, gen, gen_bids, "energy_max_avail", start_date, resolution)
            _set_storage_energy_max_avail!(sys, gen, load_bids, "energy_max_avail_decremental", start_date, resolution)
        end
    end
end

"""
    _is_non_scheduled_load(device) -> Bool

Whether `device` is a non-scheduled load ([`get_scheduled_loads_dataframe`](@ref)): it has no
energy bid, and takes part in the market only through FCAS offers.

# Arguments
- `device`: any component.

# Returns
`Bool`.
"""
_is_non_scheduled_load(device) = device isa InterruptiblePowerLoad && get(get_ext(device), "non_scheduled", false) === true

"""
    read_loss_factors(db; as_of = nothing, through = nothing) -> DataFrame

Reads each unit's connection-point loss factors from `DUDETAILSUMMARY`: the row with
`START_DATE <= as_of < END_DATE` in the latest archive.

# Arguments
- `db`: the database connection.
- `as_of`: a `Date` or `DateTime` to resolve the factors as of. `nothing` keeps each unit's open row
  (earliest `START_DATE`, the row [`read_units`](@ref) keeps).
- `through`: when a `Date` or `DateTime` after `as_of`, warns if any unit's factors change
  in `(as_of, through]`, since the result holds one factor per unit.

# Returns
A `DataFrame` with `DUID`, `LOAD_LOSS_FACTOR` (`TRANSMISSIONLOSSFACTOR * DISTRIBUTIONLOSSFACTOR`,
the factor for a load or a battery's charging side) and `GEN_LOSS_FACTOR` (`SECONDARY_TLF *
DISTRIBUTIONLOSSFACTOR` for a `BIDIRECTIONAL` unit that publishes a secondary factor, else
`LOAD_LOSS_FACTOR`). Requires the cached `DUDETAILSUMMARY` to hold the loss-factor columns;
re-populate it with `force_new = true` otherwise.
"""
function read_loss_factors(
        db; as_of::Union{Nothing, Date, DateTime} = nothing,
        through::Union{Nothing, Date, DateTime} = nothing,
    )
    source = read_hive(db, :DUDETAILSUMMARY)
    window = isnothing(as_of) ? "(END_DATE IS NULL OR year(END_DATE) = 2999)" : "START_DATE <= ? AND (END_DATE IS NULL OR END_DATE > ?)"
    # Open rows keep the earliest START_DATE, as read_units does, so both readers pick the same row.
    order = isnothing(as_of) ? "ASC" : "DESC"
    sql = """
        SELECT DUID,
            TRANSMISSIONLOSSFACTOR * DISTRIBUTIONLOSSFACTOR AS LOAD_LOSS_FACTOR,
            CASE WHEN DISPATCHTYPE = 'BIDIRECTIONAL' AND SECONDARY_TLF IS NOT NULL
                 THEN SECONDARY_TLF * DISTRIBUTIONLOSSFACTOR
                 ELSE TRANSMISSIONLOSSFACTOR * DISTRIBUTIONLOSSFACTOR END AS GEN_LOSS_FACTOR
        FROM $source
        WHERE archive_month = (SELECT max(archive_month) FROM $source) AND $window
        QUALIFY row_number() OVER (PARTITION BY DUID ORDER BY START_DATE $order) = 1
    """
    factors = isnothing(as_of) ? _query(db, sql) : _query(db, sql, [as_of, as_of])
    if !isnothing(as_of) && !isnothing(through) && through > as_of
        changed = _query(
            db,
            """
            SELECT DISTINCT DUID FROM $source
            WHERE archive_month = (SELECT max(archive_month) FROM $source) AND START_DATE > ? AND START_DATE <= ?
            """,
            [as_of, through],
        ).DUID
        isempty(changed) ||
            @warn "Loss factors change within the date range; the factors in force at its start are used throughout" as_of through first_changed = first(changed, 5)
    end
    return select(factors, :DUID, :GEN_LOSS_FACTOR, :LOAD_LOSS_FACTOR)
end

"""
    _refer_bids_to_reference_node!(bids, factors) -> bids

Divides every price of `bids.piecewise_step_data` by its unit's loss factor, leaving the MW
breakpoints unchanged.

# Arguments
- `bids`: the `DataFrame` from `_massage_bids`, modified in place.
- `factors`: the output of [`read_loss_factors`](@ref); `GEN_LOSS_FACTOR` applies to `GEN` rows and
  `LOAD_LOSS_FACTOR` to `LOAD` rows. Throws an `ArgumentError` naming any bid `DUID` it lacks.

# Returns
`bids`.
"""
function _refer_bids_to_reference_node!(bids, factors)
    lookup = Dict(r.DUID => (gen = r.GEN_LOSS_FACTOR, load = r.LOAD_LOSS_FACTOR) for r in eachrow(factors))
    unknown = setdiff(unique(bids.DUID), keys(lookup))
    isempty(unknown) ||
        throw(ArgumentError("No DUDETAILSUMMARY loss factor for bid unit(s) $(join(unknown, ", "))."))
    bids.piecewise_step_data = map(eachrow(bids)) do row
        factor = row.DIRECTION == "LOAD" ? lookup[row.DUID].load : lookup[row.DUID].gen
        psd = row.piecewise_step_data
        return PiecewiseStepData(get_x_coords(psd), get_y_coords(psd) ./ factor)
    end
    return bids
end

"""
    _set_storage_energy_max_avail!(sys, storage, bids, name, start_date, resolution)

Attaches `bids.MAXAVAIL` to `storage` as a `Deterministic` series `name`, per-unit of `sys`'s
system base. No-op if any interval's `MAXAVAIL` is missing or not finite.

# Returns
`nothing`.
"""
function _set_storage_energy_max_avail!(sys, storage, bids, name::AbstractString, start_date, resolution)
    all(x -> !ismissing(x) && isfinite(x), bids.MAXAVAIL) || return
    add_time_series!(
        sys, storage,
        Deterministic(;
            name = name,
            data = Dict(start_date => Float64.(bids.MAXAVAIL) ./ get_base_power(sys)),
            resolution = resolution,
            interval = resolution,
        ),
    )
    return
end

"""
    get_storage_energy_max_avail(component, initial_time, horizon) -> Union{Nothing, NamedTuple}

`component`'s energy bid `MAXAVAIL` for each direction, as attached by
[`set_market_bids!`](@ref), `horizon` steps from `initial_time`, in `component`'s `System`'s
current display units.

# Returns
`(gen = Vector{Float64}, load = Vector{Float64})`, or `nothing` unless both directions'
series are attached.
"""
function get_storage_energy_max_avail(component, initial_time, horizon::Integer)
    has_time_series(component, Deterministic, "energy_max_avail") || return nothing
    has_time_series(component, Deterministic, "energy_max_avail_decremental") || return nothing
    multiplier = _fcas_units_multiplier(component)
    read(name) = get_time_series_values(Deterministic, component, name; start_time = initial_time, len = horizon) .* multiplier
    return (gen = read("energy_max_avail"), load = read("energy_max_avail_decremental"))
end

"""
    read_bids(db, date_range; kwargs...)

Reads energy offers from `BIDPEROFFER_D`/`BIDDAYOFFER_D` and returns one row per
`(SETTLEMENTDATE, DUID, DIRECTION, INTERVAL_DATETIME)` with the 10-band offer curve
collapsed into a `piecewise_step_data` column of connection-point prices (not referred to the
reference node, unlike [`set_market_bids!`](@ref)), plus `MAXAVAIL` (`BIDPEROFFER_D`) and
`MINIMUMLOAD`/`DAILYENERGYCONSTRAINT` (`BIDDAYOFFER_D`) - the physical bounds a caller needs
to clip dispatch to, not just the priced curve. See [`read_fcas_bids`](@ref) for the
FCAS-market equivalent.
"""
function read_bids(db, date_range; kwargs...)
    energy_bids_table = read_hive(db, :BIDPEROFFER_D)
    pricebids_table = read_hive(db, :BIDDAYOFFER_D)
    start_date = first(date_range)
    end_date = last(date_range)
    bids = _massage_bids(db, energy_bids_table, pricebids_table, start_date, end_date; resolution = get(kwargs, :resolution, nothing))
    return bids
end

"""
    _extract_power_bids(row)

Builds a `PiecewiseStepData` offer curve from a row's `PRICEBANDARRAY`/`BANDAVAILARRAY`
columns, reversing band order for `DIRECTION == "LOAD"` rows so the resulting curve stays
concave.
"""
function _extract_power_bids(row)
    price_band_array = copy(row.PRICEBANDARRAY)
    bandavail_array = copy(row.BANDAVAILARRAY)
    if row.DIRECTION == "LOAD"
        # Reverse the order for loads, so the decremental curves are concave
        reverse!(price_band_array)
        reverse!(bandavail_array)
    end
    a = price_band_array[bandavail_array .> 0]
    b = [zero(eltype(price_band_array)); bandavail_array[bandavail_array .> 0] |> cumsum]
    return PiecewiseStepData(b, a)
end

function _massage_bids(db, energy_bids_table, pricebids_table, start_date, end_date; resolution = nothing, bid_type::BidType = BidType.ENERGY)
    sd = Date(start_date) - Day(1)
    ed = Date(end_date) + Day(1)
    bid_type_str = string(bid_type)

    energy_schema = names(_query(db, "SELECT * FROM $energy_bids_table LIMIT 0"))
    energy_band_cols = join(filter(startswith("BANDAVAIL"), energy_schema), ", ")
    energy_bids = _query(
        db,
        """
        SELECT SETTLEMENTDATE, INTERVAL_DATETIME, DUID, DIRECTION, MAXAVAIL, $energy_band_cols
        FROM $energy_bids_table
        WHERE BIDTYPE = ? AND SETTLEMENTDATE BETWEEN ? AND ?
        QUALIFY row_number() OVER (
            PARTITION BY SETTLEMENTDATE, INTERVAL_DATETIME, DUID, DIRECTION ORDER BY VERSIONNO DESC
        ) = 1
        ORDER BY SETTLEMENTDATE, INTERVAL_DATETIME
        """,
        [bid_type_str, sd, ed],
    )

    priceband_schema = names(_query(db, "SELECT * FROM $pricebids_table LIMIT 0"))
    priceband_cols = join(filter(startswith("PRICEBAND"), priceband_schema), ", ")
    pricebids = _query(
        db,
        """
        SELECT SETTLEMENTDATE, DUID, DIRECTION, MINIMUMLOAD, DAILYENERGYCONSTRAINT, $priceband_cols
        FROM $pricebids_table
        WHERE BIDTYPE = ? AND SETTLEMENTDATE BETWEEN ? AND ?
        QUALIFY row_number() OVER (
            PARTITION BY SETTLEMENTDATE, DUID, DIRECTION ORDER BY VERSIONNO DESC
        ) = 1
        ORDER BY SETTLEMENTDATE
        """,
        [bid_type_str, sd, ed],
    )

    if !isnothing(resolution)
        energy_bids = @chain energy_bids begin
            transform(:INTERVAL_DATETIME => ByRow(x -> ceil.(x, resolution)); renamecols = false)
            groupby([:SETTLEMENTDATE, :INTERVAL_DATETIME, :DUID, :DIRECTION])
            combine(
                _,
                :MAXAVAIL => mean ∘ skipmissing,
                Cols(r"^BANDAVAIL") .=> mean ∘ skipmissing,
                ;
                renamecols = false
            )
        end
    end

    all_bids = innerjoin(pricebids, energy_bids, on = [:SETTLEMENTDATE, :DUID, :DIRECTION])
    prep_for_psy = @chain all_bids begin
        subset!(:INTERVAL_DATETIME => ByRow(x -> start_date <= x < end_date))
        transform(
            AsTable(r"^PRICEBAND") => ByRow(collect) => :PRICEBANDARRAY,
            AsTable(r"^BANDAVAIL") => ByRow(collect) => :BANDAVAILARRAY,
        )
        select(
            :SETTLEMENTDATE, :DUID, :DIRECTION, :INTERVAL_DATETIME, :PRICEBANDARRAY, :BANDAVAILARRAY,
            :MAXAVAIL, :MINIMUMLOAD, :DAILYENERGYCONSTRAINT,
            AsTable(:) => ByRow(_extract_power_bids) => :piecewise_step_data
        )
    end
    return prep_for_psy
end
