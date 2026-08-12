using Dates
using DuckDB
using DataFrames
using Chain
using Statistics


"""
    read_hive(db::AEMDB, table_name::Symbol)

Builds the SQL `read_parquet(...)` source fragment for a hive-partitioned
parquet dataset, for use as a `FROM` source in a larger query.

# Arguments
- `db::AEMDB`: The database connection wrapper to use.
- `table_name::Symbol`: The name of the table to read.
"""
function read_hive(
        db::AEMDB,
        table_name::Symbol,
    )
    hive_root = _parse_hive_root(db.config)
    return "read_parquet('$hive_root/$table_name/**/*.parquet', hive_partitioning=true)"
end

"""
    _parse_hive_root(config::HiveConfiguration)

Construct the correct path to the Hive dataset based on the specified filesystem.

# Arguments
- `config::HiveConfiguration`: The configuration object containing filesystem and location details.
"""
function _parse_hive_root(config::HiveConfiguration)
    if islocal(config)
        return config.hive_location
    else
        prefix = get_filesystem(config)
        return "$(prefix)://" * config.hive_location
    end
end

"""
    _query(db::AEMDB, sql::String, params = ())

Executes `sql` against `db`'s connection and materializes the result as a `DataFrame`.
`params` are bound as positional `?` placeholders when provided.
"""
_query(db::AEMDB, sql::String) = DataFrame(DuckDB.execute(db.db, sql))
_query(db::AEMDB, sql::String, params) = DataFrame(DuckDB.execute(db.db, sql, params))

"""
    _filter_latest(source::String, key::Symbol = :archive_month)

Wraps a SQL source fragment (as returned by `read_hive`) in a subquery that
keeps only rows whose `key` column equals the maximum `key` value present —
i.e. the latest hive partition. Returns a new source fragment, so the result
can itself be used as a `FROM` source in a larger query.
"""
function _filter_latest(source::String, key::Symbol = Symbol(ARCHIVE_MONTH_PARTITION))
    return "(SELECT * FROM $source WHERE $key = (SELECT max($key) FROM $source))"
end

"""
    _hive_column_names(db, source::String)

Returns the column names available from a SQL source fragment, via a
zero-row query (cheap schema-only lookup, regardless of table size).
"""
_hive_column_names(db::AEMDB, source::String) = names(_query(db, "SELECT * FROM $source LIMIT 0"))

"""
    _prefixed_columns(db, source::String, prefix::String)

Returns the column names of `source` starting with `prefix` (e.g. `"BANDAVAIL"`),
mirroring the dynamic `starts_with(...)` column selection previously done via
TidierDB, since the number of bid bands isn't hardcoded in application code.
"""
_prefixed_columns(db::AEMDB, source::String, prefix::String) =
    filter(startswith(prefix), _hive_column_names(db, source))

"""
    read_interconnectors(db)

Reads and processes interconnector data from the database.

# Arguments
- `db`: The database connection.

# Returns
A `DataFrame` containing the latest interconnector constraint data.

# Example
```julia
db = aem_connect()
interconnectors_df = read_interconnectors(db)
println(interconnectors_df)
```
"""
function read_interconnectors(db)
    t_interconnector = read_hive(db, :INTERCONNECTOR)
    t_interconnector_constraint = read_hive(db, :INTERCONNECTORCONSTRAINT)

    sql = """
        WITH ic AS (SELECT * FROM $t_interconnector),
             latest_ic AS (
                 SELECT INTERCONNECTORID, REGIONFROM, REGIONTO, archive_month
                 FROM $(_filter_latest("ic"))
             ),
             icc AS (SELECT * FROM $t_interconnector_constraint)
        SELECT c.* EXCLUDE (archive_month), l.REGIONFROM, l.REGIONTO
        FROM icc c
        INNER JOIN latest_ic l
          ON c.INTERCONNECTORID = l.INTERCONNECTORID AND c.archive_month = l.archive_month
        QUALIFY row_number() OVER (
            PARTITION BY c.INTERCONNECTORID ORDER BY c.EFFECTIVEDATE DESC, c.VERSIONNO DESC
        ) = 1
    """
    return _query(db, sql)
end

"""
    read_demand(db; resolution::Dates.Period=Dates.Minute(5))

Read and process regional demand data from the database.

# Arguments
- `db`: The database connection.
- `resolution::Dates.Period`: The time resolution to which the data should be floored. Defaults to 5 minutes.

# Returns
A `DataFrame` with demand and renewable availability data, aggregated by the specified resolution.

# Example
```julia
db = aem_connect()
demand_df = read_demand(db; resolution=Dates.Hour(1))
println(demand_df)
```
   Row │ SETTLEMENTDATE       REGIONID  TOTALDEMAND  DISPATCHABLEGENERATION  DISPATCHABLELOAD  NETINTERCHANGE
	   │ Dates.DateTime       String7   Float64      Float64                 Float64           Float64
───────┼──────────────────────────────────────────────────────────────────────────────────────────────────────
	 1 │ 2024-01-01T00:05:00  NSW1          6574.92                 6721.88               0.0          146.96
	 2 │ 2024-01-01T00:05:00  QLD1          6228.31                 5713.21               0.0         -515.1
	 3 │ 2024-01-01T00:05:00  SA1           1293.98                 1116.68               0.0         -177.3
	 4 │ 2024-01-01T00:05:00  TAS1          1033.29                  580.29               0.0         -453.0
	 5 │ 2024-01-01T00:05:00  VIC1          3977.1                  5071.17               0.0         1094.07
"""
function read_demand(db; resolution::Dates.Period = Dates.Minute(5))
    source = read_hive(db, :DISPATCHREGIONSUM)
    df = _query(
        db,
        """
        SELECT SETTLEMENTDATE, REGIONID, TOTALDEMAND, SS_SOLAR_AVAILABILITY, SS_WIND_AVAILABILITY
        FROM $source
        WHERE SETTLEMENTDATE IS NOT NULL AND REGIONID IS NOT NULL
          AND TOTALDEMAND IS NOT NULL AND SS_SOLAR_AVAILABILITY IS NOT NULL AND SS_WIND_AVAILABILITY IS NOT NULL
        """
    )
    # df[!, :TOTALDEMAND] .+= df[!, :DISPATCHABLELOAD]  # Adds the dispatchable load to the total demand to get the actual native demand
    df[!, :SETTLEMENTDATE] = ceil.(df[!, :SETTLEMENTDATE], resolution)
    sort!(df, :SETTLEMENTDATE)
    return @chain df begin
        groupby([:SETTLEMENTDATE, :REGIONID])
        combine(_, valuecols(_) .=> mean ∘ skipmissing; renamecols = false)
    end
end

"""
    read_units(db)

Gathers and processes unit data from the database.

# Arguments
- `db`: The database connection.

# Returns
A `DataFrame` containing detailed information about each generation unit.

# Example
```julia
db = aem_connect()
units_df = read_units(db)
println(units_df)
```
"""
function read_units(db)
    dudetail_table = read_hive(db, :DUDETAIL)
    summary_table = read_hive(db, :DUDETAILSUMMARY)
    op_status_table = read_hive(db, :STATIONOPERATINGSTATUS)
    station_table = read_hive(db, :STATION)
    gen_units_table = read_hive(db, :GENUNITS)
    dualloc_table = read_hive(db, :DUALLOC)

    # All filtering, latest-partition/version resolution, and joins are pushed
    # into DuckDB via CTEs. Each hive source is scanned exactly once (bound to
    # a CTE) and reused from there — referencing the same `read_parquet(...)`
    # fragment twice in one query trips a DuckDB internal assertion.
    sql = """
        WITH dd_raw AS (SELECT * FROM $dudetail_table),
             dudetail AS (
                 SELECT * EXCLUDE (archive_month)
                 FROM dd_raw
                 QUALIFY row_number() OVER (
                     PARTITION BY DUID ORDER BY EFFECTIVEDATE DESC, VERSIONNO DESC
                 ) = 1
             ),
             sm_raw AS (SELECT * FROM $summary_table),
             summary AS (
                 SELECT * EXCLUDE (archive_month)
                 FROM $(_filter_latest("sm_raw"))
                 WHERE END_DATE IS NULL OR year(END_DATE) = 2999
                 QUALIFY row_number() OVER (PARTITION BY DUID ORDER BY START_DATE ASC) = 1
             ),
             op_raw AS (SELECT * FROM $op_status_table),
             st_raw AS (SELECT * FROM $station_table),
             commissioned_max AS (
                 SELECT STATIONID, max(EFFECTIVEDATE) AS EFFECTIVEDATE, max(archive_month) AS archive_month
                 FROM op_raw
                 WHERE STATUS = 'COMMISSIONED'
                 GROUP BY STATIONID
             ),
             station_names AS (
                 -- One row per STATIONID: a station's name/postcode can change across
                 -- archive_month partitions, so without this the LEFT JOIN below would
                 -- fan out and duplicate DUID rows in the final result.
                 SELECT STATIONID, STATIONNAME, POSTCODE
                 FROM st_raw
                 QUALIFY row_number() OVER (PARTITION BY STATIONID ORDER BY archive_month DESC) = 1
             ),
             op_status AS (
                 SELECT DISTINCT o.STATIONID, o.STATUS, s.STATIONNAME, s.POSTCODE
                 FROM op_raw o
                 INNER JOIN commissioned_max m
                   ON o.STATIONID = m.STATIONID AND o.EFFECTIVEDATE = m.EFFECTIVEDATE AND o.archive_month = m.archive_month
                 LEFT JOIN station_names s ON o.STATIONID = s.STATIONID
             ),
             gu_raw AS (SELECT * FROM $gen_units_table),
             genunits_raw AS (
                 SELECT GENSETID, first(CO2E_ENERGY_SOURCE) AS CO2E_ENERGY_SOURCE, first(CO2E_EMISSIONS_FACTOR) AS CO2E_EMISSIONS_FACTOR
                 FROM $(_filter_latest("gu_raw"))
                 GROUP BY GENSETID
             ),
             dl_raw AS (SELECT * FROM $dualloc_table),
             dualloc AS (
                 SELECT GENSETID, DUID
                 FROM $(_filter_latest("dl_raw"))
                 QUALIFY row_number() OVER (
                     PARTITION BY GENSETID ORDER BY DUID DESC, LASTCHANGED DESC, VERSIONNO DESC
                 ) = 1
             ),
             genunits AS (
                 SELECT d.DUID, g.CO2E_ENERGY_SOURCE, g.CO2E_EMISSIONS_FACTOR
                 FROM genunits_raw g
                 INNER JOIN dualloc d ON g.GENSETID = d.GENSETID
             )
        SELECT dudetail.*, summary.* EXCLUDE (DUID), op_status.* EXCLUDE (STATIONID),
               genunits.CO2E_ENERGY_SOURCE, genunits.CO2E_EMISSIONS_FACTOR
        FROM dudetail
        INNER JOIN genunits ON dudetail.DUID = genunits.DUID
        INNER JOIN summary ON dudetail.DUID = summary.DUID
        INNER JOIN op_status ON summary.STATIONID = op_status.STATIONID
        WHERE op_status.STATUS = 'COMMISSIONED'
        ORDER BY dudetail.DUID
    """
    dudetail = _query(db, sql)

    # PowerSystems.jl enum lookups: inherently a Julia-side step, applied to
    # the small, already-fully-joined/filtered result.
    transform!(
        dudetail,
        :CO2E_ENERGY_SOURCE => ByRow(x -> AEMO_PM_MAPPING[x]) => :TECHNOLOGY,
        :CO2E_ENERGY_SOURCE => ByRow(x -> AEMO_FUEL_MAPPING[x]) => :FUELTYPE,
    )
    return dudetail
end


"""
    set_demand!(sys, db, date_range; kwargs...)

Adds load time series data to the system from the database.

This function reads demand data for a specified date range, processes it into a time series,
and attaches it to the `PowerLoad` components in the system.

# Arguments
- `sys`: The `PowerSystems.System` object.
- `db`: The database connection.
- `date_range`: A range of dates for which to fetch demand data.
- `kwargs`: Additional keyword arguments passed to `read_demand`.
"""
function set_demand!(sys, db, date_range; kwargs...)
    demand = read_demand(db; kwargs...)
    ts = @chain demand begin
        transform!(:REGIONID => ByRow(x -> x * " Load") => :name)
        subset!(:SETTLEMENTDATE => ByRow(x -> first(date_range) <= x < last(date_range)))
        _as_timearray(:SETTLEMENTDATE, :name, :TOTALDEMAND)
    end
    return _add_demand_ts_to_components!(sys, ts, PowerLoad)
end

"""
    set_renewable_pv!(sys, db, date_range; kwargs...)

Adds photovoltaic (PV) renewable generation time series data to the system.

This function reads solar availability data for a specified date range from the database,
processes it into a time series, and attaches it to the `RenewableDispatch` components
representing PV generators.

# Arguments
- `sys`: The `PowerSystems.System` object.
- `db`: The database connection.
- `date_range`: A range of dates for which to fetch the data.
- `kwargs`: Additional keyword arguments passed to `read_demand`.
"""
function set_renewable_pv!(sys, db, date_range; kwargs...)
    demand = read_demand(db; kwargs...)
    ts = @chain demand begin
        subset!(:SETTLEMENTDATE => ByRow(x -> first(date_range) <= x < last(date_range)))
        select!(:SETTLEMENTDATE, :REGIONID, :SS_SOLAR_AVAILABILITY)
        disallowmissing!
        _as_timearray(:SETTLEMENTDATE, :REGIONID, :SS_SOLAR_AVAILABILITY)
    end
    @info "Setting PV power time series"
    return _add_renewable_ts_to_components!(sys, ts, PrimeMovers.PVe)
end

"""
    set_renewable_wind!(sys, db, date_range; kwargs...)

Adds wind turbine renewable generation time series data to the system.

This function reads wind availability data for a specified date range from the database,
processes it into a time series, and attaches it to the `RenewableDispatch` components
representing wind turbines.

# Arguments
- `sys`: The `PowerSystems.System` object.
- `db`: The database connection.
- `date_range`: A range of dates for which to fetch the data.
- `kwargs`: Additional keyword arguments passed to `read_demand`.
"""
function set_renewable_wind!(sys, db, date_range; kwargs...)
    demand = read_demand(db; kwargs...)
    ts = @chain demand begin
        subset!(:SETTLEMENTDATE => ByRow(x -> first(date_range) <= x < last(date_range)))
        select!(:SETTLEMENTDATE, :REGIONID, :SS_WIND_AVAILABILITY)
        disallowmissing!
        _as_timearray(:SETTLEMENTDATE, :REGIONID, :SS_WIND_AVAILABILITY)
    end
    @info "Setting wind power time series"
    return _add_renewable_ts_to_components!(sys, ts, PrimeMovers.WT)
end

function set_hydro_limits!(sys, db, date_range; kwargs...)
    energy_bids = read_energy_bids(db, date_range; kwargs...)
    ts = @chain energy_bids begin
        subset!(:DIRECTION => ByRow(==("GEN")))
        select!(:INTERVAL_DATETIME, :DUID, :MAXAVAIL)
        unstack(:INTERVAL_DATETIME, :DUID, :MAXAVAIL; combine = maximum)
        disallowmissing!
        TimeArray(timestamp = :INTERVAL_DATETIME)
    end
    return _add_demand_ts_to_components!(sys, ts, HydroDispatch)
end


"""
    _as_timearray(df, index, col, value)

Converts a DataFrame to a TimeArray.

# Arguments
- `df`: The input `DataFrame`.
- `index`: The column to use as the timestamp.
- `col`: The column to use for the column names of the `TimeArray`.
- `value`: The column to use for the values of the `TimeArray`.
"""
function _as_timearray(df, index, col, value)
    out = TimeArray(unstack(df, index, col, value); timestamp = index)
    return Float64.(out)
end

"""
    _add_demand_ts_to_components!(sys, ts, type)

Adds demand time series data to the system components.

# Arguments
- `sys`: The `PowerSystems.System` object.
- `ts`: A `TimeArray` of demand data.
- `type`: The type of component to add the time series to.
"""
function _add_demand_ts_to_components!(sys, ts, type)
    loads = colnames(ts)
    for component in get_components(type, sys)
        name = Symbol(get_name(component))
        if !in(name, loads)
            @info "Setting loads to 0 for $name"
            ts_component = ts[first(loads)] .* 0.0
        else
            ts_component = ts[name]
        end
        max_active_power = get_max_active_power(component)
        psy_ts = SingleTimeSeries(;
            name = "max_active_power",
            data = Float64.(ts_component ./ max_active_power ./ get_base_power(sys)),
            scaling_factor_multiplier = get_max_active_power,
        )
        add_time_series!(sys, component, psy_ts)
    end
    return
end

"""
    _add_renewable_ts_to_components!(sys, ts, prime_mover)

Adds renewable generation time series data to the system components.

# Arguments
- `sys`: The `PowerSystems.System` object.
- `ts`: A `TimeArray` of renewable generation data.
- `prime_mover`: The prime mover type of the renewable generator.
"""
function _add_renewable_ts_to_components!(sys, ts, prime_mover)
    for area in get_components(area -> get_name(area) in string.(colnames(ts)), Area, sys)
        area_symbol = Symbol(get_name(area))
        components_in_area = get_components(
            x -> get_area(get_bus(x)) == area && get_prime_mover_type(x) == prime_mover,
            RenewableDispatch,
            sys,
        )
        psy_ts = SingleTimeSeries(;
            name = "max_active_power",
            data = ts[area_symbol] ./ values(maximum(ts[area_symbol]))[1],
            scaling_factor_multiplier = get_max_active_power,
        )
        add_time_series!(sys, components_in_area, psy_ts)
    end
    return
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
    )
    set_incremental_variable_cost!(sys, gen, time_series_data, UnitSystem.NATURAL_UNITS)
    time_series_incremental_initial_input = Deterministic(;
        name = "incremental_initial_input",
        data = Dict(start_date => zeros(size(psd))),
        resolution = resolution,
    )
    set_incremental_initial_input!(sys, gen, time_series_incremental_initial_input)
    return
end

"""
    set_market_bids!(sys, db, date_range; kwargs...)

Adds market bid cost time series data to the system.

This function reads energy and price bid data for a specified date range from the
database, converts it into piecewise `MarketBidCost` variable cost time series, and
attaches it to `Generator` and `EnergyReservoirStorage` components (the latter also
gets decremental/load-side bid costs).

# Arguments
- `sys`: The `PowerSystems.System` object.
- `db`: The database connection.
- `date_range`: A range of dates for which to fetch the data.
- `kwargs`: Additional keyword arguments passed to `_massage_bids` (e.g. `resolution`).
"""
function set_market_bids!(sys, db, date_range; kwargs...)
    start_date = first(date_range)
    end_date = last(date_range)
    resolution = get(kwargs, :resolution, Minute(5))

    energy_bids_table = read_hive(db, :BIDPEROFFER_D)
    pricebids_table = read_hive(db, :BIDDAYOFFER_D)
    bids = _massage_bids(db, energy_bids_table, pricebids_table, start_date, end_date; resolution = get(kwargs, :resolution, nothing))

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

            # Load bids as decremental inputs
            psd = load_bids.piecewise_step_data
            time_series_data = Deterministic(;
                name = "decremental_variable_cost",
                data = Dict(start_date => psd),
                resolution = resolution,
            )
            set_decremental_variable_cost!(sys, gen, time_series_data, UnitSystem.NATURAL_UNITS)
            time_series_decremental_initial_input = Deterministic(;
                name = "decremental_initial_input",
                data = Dict(start_date => (first ∘ get_y_coords).(psd)),
                resolution = resolution,
            )
            set_decremental_initial_input!(sys, gen, time_series_decremental_initial_input)
        end
    end
end

function read_bids(db, date_range; kwargs...)
    energy_bids_table = read_hive(db, :BIDPEROFFER_D)
    pricebids_table = read_hive(db, :BIDDAYOFFER_D)
    start_date = first(date_range)
    end_date = last(date_range)
    bids = _massage_bids(db, energy_bids_table, pricebids_table, start_date, end_date; resolution = get(kwargs, :resolution, nothing))
    return bids
end

function read_energy_bids(db, date_range; kwargs...)
    start_datetime = first(date_range)
    end_datetime = last(date_range)
    sd = Date(start_datetime) - Day(1)
    ed = Date(end_datetime) + Day(1)
    source = read_hive(db, :BIDPEROFFER_D)
    band_cols = join(_prefixed_columns(db, source, "BANDAVAIL"), ", ")

    energy_bids = _query(
        db,
        """
        SELECT SETTLEMENTDATE, INTERVAL_DATETIME, DUID, DIRECTION, MAXAVAIL, $band_cols
        FROM $source
        WHERE BIDTYPE = 'ENERGY' AND SETTLEMENTDATE BETWEEN ? AND ?
        QUALIFY row_number() OVER (
            PARTITION BY SETTLEMENTDATE, INTERVAL_DATETIME, DUID, DIRECTION ORDER BY VERSIONNO DESC
        ) = 1
        ORDER BY SETTLEMENTDATE, INTERVAL_DATETIME
        """,
        [sd, ed],
    )

    if :resolution in keys(kwargs)
        resolution = get(kwargs, :resolution, Minute(5))
        energy_bids[!, :INTERVAL_DATETIME] = ceil.(energy_bids[!, :INTERVAL_DATETIME], resolution)
        energy_bids = @chain energy_bids begin
            groupby([:SETTLEMENTDATE, :INTERVAL_DATETIME, :DUID, :DIRECTION])
            combine(_, valuecols(_) .=> maximum ∘ skipmissing; renamecols = false)
        end
    end
    subset!(
        energy_bids,
        :INTERVAL_DATETIME => ByRow(x -> (start_datetime <= x < end_datetime))
    )
    return energy_bids
end

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

function _massage_bids(db, energy_bids_table, pricebids_table, start_date, end_date; resolution = nothing)
    sd = Date(start_date) - Day(1)
    ed = Date(end_date) + Day(1)
    energy_band_cols = join(_prefixed_columns(db, energy_bids_table, "BANDAVAIL"), ", ")
    energy_bids = _query(
        db,
        """
        SELECT SETTLEMENTDATE, INTERVAL_DATETIME, DUID, DIRECTION, MAXAVAIL, $energy_band_cols
        FROM $energy_bids_table
        WHERE BIDTYPE = 'ENERGY' AND SETTLEMENTDATE BETWEEN ? AND ?
        QUALIFY row_number() OVER (
            PARTITION BY SETTLEMENTDATE, INTERVAL_DATETIME, DUID, DIRECTION ORDER BY VERSIONNO DESC
        ) = 1
        ORDER BY SETTLEMENTDATE, INTERVAL_DATETIME
        """,
        [sd, ed],
    )

    priceband_cols = join(_prefixed_columns(db, pricebids_table, "PRICEBAND"), ", ")
    pricebids = _query(
        db,
        """
        SELECT SETTLEMENTDATE, DUID, DIRECTION, MINIMUMLOAD, DAILYENERGYCONSTRAINT, $priceband_cols
        FROM $pricebids_table
        WHERE BIDTYPE = 'ENERGY' AND SETTLEMENTDATE BETWEEN ? AND ?
        QUALIFY row_number() OVER (
            PARTITION BY SETTLEMENTDATE, DUID, DIRECTION ORDER BY VERSIONNO DESC
        ) = 1
        ORDER BY SETTLEMENTDATE
        """,
        [sd, ed],
    )

    if !isnothing(resolution)
        energy_bids = @chain energy_bids begin
            transform(
                :INTERVAL_DATETIME => ByRow(x -> ceil.(x, resolution)),
                Cols(r"^BANDAVAIL") .=> ByRow(x -> x * Minute(5) / resolution)
                ;
                renamecols = false
            )
            groupby([:SETTLEMENTDATE, :INTERVAL_DATETIME, :DUID, :DIRECTION])
            combine(
                _,
                :MAXAVAIL => sum ∘ skipmissing,
                Cols(r"^BANDAVAIL") .=> sum,
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
            AsTable(:) => ByRow(_extract_power_bids) => :piecewise_step_data
        )
    end
    return prep_for_psy
end
