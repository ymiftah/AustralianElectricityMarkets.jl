using Dates
using TidierDB
using DataFrames
using Statistics

# AEMO BIDTYPE string -> FCASResponseTime for the 6 contingency FCAS markets in scope.
# RAISE1SEC/LOWER1SEC are deferred (see FCASResponseTime.SEC1 docstring).
const FCAS_CONTINGENCY_MARKETS = Dict(
    "RAISE6SEC" => FCASResponseTime.SEC6,
    "LOWER6SEC" => FCASResponseTime.SEC6,
    "RAISE60SEC" => FCASResponseTime.SEC60,
    "LOWER60SEC" => FCASResponseTime.SEC60,
    "RAISE5MIN" => FCASResponseTime.MIN5,
    "LOWER5MIN" => FCASResponseTime.MIN5,
)
const FCAS_REGULATION_MARKETS = ("RAISEREG", "LOWERREG")
const FCAS_BID_TYPES = (keys(FCAS_CONTINGENCY_MARKETS)..., FCAS_REGULATION_MARKETS...)

_fcas_direction(bid_type::AbstractString) = startswith(bid_type, "RAISE") ? ReserveUp : ReserveDown


"""
    read_hive(db::TidierDB.DBInterface.Connection,table_name::Symbol; config::HiveConfiguration=CONFIG[])

Read a hive-partitioned parquet dataset into a TidierDB table.

# Arguments
- `db::TidierDB.DBInterface.Connection`: The database connection to use.
- `table_name::Symbol`: The name of the table to read.
- `config::HiveConfiguration`: The configuration to use. Defaults to `CONFIG[]`.
"""
function read_hive(
        db::AEMDB,
        table_name::Symbol,
    )
    hive_root = _parse_hive_root(db.config)
    hive_path = """
    read_parquet(
        "$hive_root/$table_name/**/*.parquet",
        hive_partitioning=true
    )
    """
    return TidierDB.dt(db.db, hive_path)
end

"""
    _parse_hive_root(config::PyHiveConfiguration)

Construct the correct path to the Hive dataset based on the specified filesystem.

# Arguments
- `config::PyHiveConfiguration`: The configuration object containing filesystem and location details.
"""
function _parse_hive_root(config::HiveConfiguration)
    if islocal(config)
        return config.hive_location
    else
        prefix = get_filesystem(config)
        return "$(prefix)://" * config.hive_location
    end
    throw("Not a known filesystem")
end

"""
    read_interconnectors(db)

Reads and processes interconnector data from the database.

# Arguments
- `db`: The database connection.

# Returns
A `DataFrame` containing the latest interconnector constraint data.

# Example
```julia
db = aem_connect(duckdb())
interconnectors_df = read_interconnectors(db)
println(interconnectors_df)
```
"""
function read_interconnectors(db)
    t_interconnector = read_hive(db, :INTERCONNECTOR)
    t_interconnector_constraint = read_hive(db, :INTERCONNECTORCONSTRAINT)
    interconnector_ids = @chain t_interconnector begin
        AustralianElectricityMarkets._filter_latest
    end

    return @chain t_interconnector_constraint begin
        @inner_join(interconnector_ids, INTERCONNECTORID, archive_month)
        @arrange(INTERCONNECTORID, desc(EFFECTIVEDATE), desc(VERSIONNO))
        @collect
        unique(:INTERCONNECTORID, keep = :first)
        select(Not(:archive_month))
    end
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
db = aem_connect(duckdb())
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
    dudetail_table = read_hive(db, :DISPATCHREGIONSUM)
    df = @chain dudetail_table begin
        @select(
            SETTLEMENTDATE,
            REGIONID,
            TOTALDEMAND,
            # DISPATCHABLEGENERATION,
            # DISPATCHABLELOAD,
            # NETINTERCHANGE,
            SS_SOLAR_AVAILABILITY,
            SS_WIND_AVAILABILITY,
        )
        @collect
    end
    dropmissing!(df)
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
db = aem_connect(duckdb())
units_df = read_units(db)
println(units_df)
```
"""
function read_units(db)

    # READ THE LIST OF UNITS
    dudetail_table = read_hive(db, :DUDETAIL)
    dudetail = @chain dudetail_table begin
        @group_by(DUID)
        @summarise(
            EFFECTIVEDATE = maximum(EFFECTIVEDATE), archive_month = maximum(archive_month)
        )
        @inner_join(
            dudetail_table,
            DUID == DUID,
            EFFECTIVEDATE == EFFECTIVEDATE,
            archive_month == archive_month
        )
        @collect
    end
    dudetail = @chain dudetail begin
        groupby([:DUID, :EFFECTIVEDATE])
        combine(:VERSIONNO => maximum => :VERSIONNO)
        innerjoin(dudetail; on = [:DUID, :EFFECTIVEDATE, :VERSIONNO])
        sort(:DUID)
        select(Not([:archive_month]))
        unique
    end

    # # JOIN THE SUMMARY Table to match station (among other info)
    summary_table = read_hive(db, :DUDETAILSUMMARY)
    summary = @chain summary_table begin
        _filter_latest
        @filter(ismissing(END_DATE) || (year(END_DATE) == 2999))  # AEMO specifies the latest version with a 2999-12-31 or a missing date in nemdb.py
        @arrange(DUID, START_DATE)
        @collect
        unique(:DUID)
        select!(Not(:archive_month))
    end

    station_names = @chain read_hive(db, :STATION) begin
        @select(STATIONID, STATIONNAME, POSTCODE)
        @collect
        unique
    end
    op_status_table = read_hive(db, :STATIONOPERATINGSTATUS)
    max_eff_date = @chain op_status_table begin
        @filter STATUS == "COMMISSIONED"
        @group_by(STATIONID)
        @summarise(
            EFFECTIVEDATE = maximum(EFFECTIVEDATE), archive_month = maximum(archive_month)
        )
    end
    op_status = @chain op_status_table begin
        @inner_join(
            max_eff_date,
            STATIONID == STATIONID,
            EFFECTIVEDATE == EFFECTIVEDATE,
            archive_month == archive_month
        )
        @arrange(STATIONID, EFFECTIVEDATE, VERSIONNO)
        @collect
        select(Not([:archive_month]))
        unique
        leftjoin(station_names; on = :STATIONID)
        select!(:STATIONID, :STATUS, :STATIONNAME, :POSTCODE)
        unique!(; keep = :last)
    end

    # GENSET / DUID mapping
    gen_units = read_hive(db, :GENUNITS)
    genunits = @chain gen_units begin
        _filter_latest(:archive_month)
        @collect
        select!(:GENSETID, :CO2E_ENERGY_SOURCE, :CO2E_EMISSIONS_FACTOR)
        groupby(:GENSETID)
        combine(
            :CO2E_ENERGY_SOURCE => first,
            :CO2E_EMISSIONS_FACTOR => first,
            ;
            renamecols = false,
        )
        transform(
            :CO2E_ENERGY_SOURCE => ByRow(x -> AEMO_PM_MAPPING[x]) => :TECHNOLOGY,
            :CO2E_ENERGY_SOURCE => ByRow(x -> AEMO_FUEL_MAPPING[x]) => :FUELTYPE,
        )
        unique!
    end
    dualloc = @chain read_hive(db, :DUALLOC) begin
        _filter_latest
        @select(DUID, GENSETID, LASTCHANGED, VERSIONNO)
        @collect
        sort!([:DUID, :GENSETID, :LASTCHANGED, :VERSIONNO])
        unique!([:GENSETID]; keep = :last)
        select!(:GENSETID, :DUID)
    end
    genunits = @chain innerjoin(genunits, dualloc; on = :GENSETID) begin
        select!(Not(:GENSETID))
        unique
    end

    # # Joins
    dudetail = innerjoin(dudetail, genunits; on = :DUID)
    dudetail = innerjoin(dudetail, summary; on = :DUID, makeunique = true)
    dudetail = innerjoin(dudetail, op_status; on = :STATIONID)
    # # Keep commisioned and scheduled / semischeduled
    subset!(dudetail, :STATUS => ByRow(==("COMMISSIONED")))
    # TODO address duplicated columnz explicitly
    select!(dudetail, Not(r"_[\d]"))
    return dudetail
end

"""
    _filter_latest(table, key=:archive_month)

Helper function to filter for the most recent records in a table.

# Arguments
- `table`: The table to filter.
- `key`: The column to use for determining the latest records. Defaults to `:archive_month`.
"""
function _filter_latest(table)
    return _filter_latest(table, :archive_month)
end

"""
    _filter_latest(table, key)

Helper function to filter for the most recent records in a table based on a given key.

# Arguments
- `table`: The TidierDB table to filter.
- `key`: The column (as a Symbol) to use for determining the latest records.
"""
function _filter_latest(table, key)
    # NOTE DuckDB.jl seem to have issues with queries on the hive partition
    # keys, so find the value first, use it to filter
    max_eff_date = @eval @chain $table begin
        @select($key)
        @distinct
        @collect
    end
    max_eff_date = maximum(max_eff_date[!, key])
    return @eval @chain $table begin
        @filter($key == $max_eff_date)
    end
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
    set_renewable_pv!(sys, db, date_range; kwargs...)

Adds Market bids time series data to the system.

This function reads solar availability data for a specified date range from the database,
processes it into a time series, and attaches it to the `RenewableDispatch` components
representing PV generators.

# Arguments
- `sys`: The `PowerSystems.System` object.
- `db`: The database connection.
- `date_range`: A range of dates for which to fetch the data.
- `kwargs`: Additional keyword arguments passed to `read_demand`.
"""
function set_market_bids!(sys, db, date_range; kwargs...)
    start_date = first(date_range)
    end_date = last(date_range)

    energy_bids_table = read_hive(db, :BIDPEROFFER_D)
    pricebids_table = read_hive(db, :BIDDAYOFFER_D)
    bids = _massage_bids(energy_bids_table, pricebids_table, start_date, end_date; resolution = get(kwargs, :resolution, nothing))

    # Sets all generator subtype first
    foreach(get_components(Generator, sys)) do gen
        gen_id = get_name(gen)
        start_date = first(date_range)
        gen_bids = subset(bids, :DUID => ByRow(==(gen_id)), :DIRECTION => ByRow(==("GEN")))
        if DataFrames.isempty(gen_bids)
            @warn "No bid data for generator $(gen_id), setting to unavailable."
            set_available!(gen, false)
        else
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
            data = Dict(
                start_date => psd,
            )
            time_series_data = Deterministic(;
                name = "variable_cost",
                data = data,
                resolution = get(kwargs, :resolution, Minute(5)),
                interval = get(kwargs, :resolution, Minute(5)),
            )
            set_incremental_variable_cost!(sys, gen, time_series_data, UnitSystem.NATURAL_UNITS)
            time_series_incremental_initial_input = Deterministic(;
                name = "incremental_initial_input",
                data = Dict(
                    start_date => zeros(size(psd))
                ),
                resolution = get(kwargs, :resolution, Minute(5)),
                interval = get(kwargs, :resolution, Minute(5)),
            )
            set_incremental_initial_input!(sys, gen, time_series_incremental_initial_input)
        end
    end

    # Then sets the batteries
    return foreach(get_components(EnergyReservoirStorage, sys)) do gen
        gen_id = get_name(gen)
        start_date = first(date_range)
        gen_bids = subset(bids, :DUID => ByRow(==(gen_id)), :DIRECTION => ByRow(==("GEN")))
        load_bids = subset(bids, :DUID => ByRow(==(gen_id)), :DIRECTION => ByRow(==("LOAD")))

        if DataFrames.isempty(gen_bids) || DataFrames.isempty(load_bids)
            @warn "No bid data for generator $(gen_id), setting to unavailable."
            set_available!(gen, false)
        else
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
            data = Dict(
                start_date => psd,
            )
            time_series_data = Deterministic(;
                name = "variable_cost",
                data = data,
                resolution = get(kwargs, :resolution, Minute(5)),
                interval = get(kwargs, :resolution, Minute(5)),
            )
            set_incremental_variable_cost!(sys, gen, time_series_data, UnitSystem.NATURAL_UNITS)
            time_series_incremental_initial_input = Deterministic(;
                name = "incremental_initial_input",
                data = Dict(
                    start_date => zeros(size(psd))
                ),
                resolution = get(kwargs, :resolution, Minute(5)),
                interval = get(kwargs, :resolution, Minute(5)),
            )
            set_incremental_initial_input!(sys, gen, time_series_incremental_initial_input)

            # Load bids as decremental inputs
            psd = load_bids.piecewise_step_data
            data = Dict(
                start_date => psd,
            )
            time_series_data = Deterministic(;
                name = "decremental_variable_cost",
                data = data,
                resolution = get(kwargs, :resolution, Minute(5)),
                interval = get(kwargs, :resolution, Minute(5)),
            )
            set_decremental_variable_cost!(sys, gen, time_series_data, UnitSystem.NATURAL_UNITS)
            time_series_decremental_initial_input = Deterministic(;
                name = "decremental_initial_input",
                data = Dict(
                    start_date => (first ∘ get_y_coords).(psd)
                ),
                resolution = get(kwargs, :resolution, Minute(5)),
                interval = get(kwargs, :resolution, Minute(5)),
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
    bids = _massage_bids(energy_bids_table, pricebids_table, start_date, end_date; resolution = get(kwargs, :resolution, nothing))
    return bids
end

function read_energy_bids(db, date_range; bid_type::AbstractString = "ENERGY", kwargs...)
    start_datetime = first(date_range)
    end_datetime = last(date_range)
    sd = Date(start_datetime) - Day(1)
    ed = Date(end_datetime) + Day(1)
    table = read_hive(db, :BIDPEROFFER_D)
    energy_bids = @eval @chain $table begin
        @select(SETTLEMENTDATE, BIDTYPE, INTERVAL_DATETIME, VERSIONNO, DUID, DIRECTION, MAXAVAIL, starts_with("BANDAVAIL"))
        @filter($sd <= SETTLEMENTDATE, SETTLEMENTDATE <= $ed, BIDTYPE == $bid_type)
        # Only select the version no that are the latest for each interval and duid
        @group_by(SETTLEMENTDATE, INTERVAL_DATETIME, DUID, DIRECTION)
        @mutate(max_version = maximum(VERSIONNO))
        @filter(VERSIONNO == max_version)
        @arrange(SETTLEMENTDATE, INTERVAL_DATETIME)
        @select(SETTLEMENTDATE, INTERVAL_DATETIME, DUID, DIRECTION, MAXAVAIL, starts_with("BANDAVAIL"))
        @collect
    end

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

function _massage_bids(energy_bids_table, pricebids_table, start_date, end_date; resolution = nothing, bid_type::AbstractString = "ENERGY")
    sd = Date(start_date) - Day(1)
    ed = Date(end_date) + Day(1)
    energy_bids = @eval @chain $energy_bids_table begin
        @filter($sd <= SETTLEMENTDATE, SETTLEMENTDATE <= $ed, BIDTYPE == $bid_type)
        # Only select the version no that are the latest for each interval and duid
        @group_by(SETTLEMENTDATE, INTERVAL_DATETIME, DUID, DIRECTION)
        @mutate(max_version = maximum(VERSIONNO))
        @filter(VERSIONNO == max_version)
        @select(SETTLEMENTDATE, INTERVAL_DATETIME, DUID, DIRECTION, MAXAVAIL, starts_with("BANDAVAIL"))
        @arrange(SETTLEMENTDATE, INTERVAL_DATETIME)
        @collect
    end

    pricebids = @eval @chain $pricebids_table begin
        @filter(BIDTYPE == $bid_type)
        @filter($sd <= SETTLEMENTDATE, SETTLEMENTDATE <= $ed)
        # Only select the version no that are the latest for each interval and duid
        @group_by(SETTLEMENTDATE, DUID, DIRECTION)
        @mutate(max_version = maximum(VERSIONNO))
        @filter(VERSIONNO == max_version)
        @select(SETTLEMENTDATE, DUID, DIRECTION, MINIMUMLOAD, DAILYENERGYCONSTRAINT, starts_with("PRICEBAND"))
        @arrange(SETTLEMENTDATE)
        @collect
    end

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

"""
    read_fcas_bids(db, date_range, bid_type; kwargs...)

Like [`read_bids`](@ref), but for an AEMO FCAS `bid_type` (e.g. `"RAISE6SEC"`,
`"RAISEREG"` — see `FCAS_BID_TYPES`). Reuses `_massage_bids` for the 10-band offer curve
(same shape as the energy bid path), and additionally reads the AEMO FCAS trapezium
columns from `BIDPEROFFER_D` (`ENABLEMENTMIN/MAX`, `LOWBREAKPOINT`, `HIGHBREAKPOINT`,
`ROCUP`, `ROCDOWN` — already present in that table, just never selected by the
energy-only bid path).
"""
function read_fcas_bids(db, date_range, bid_type::AbstractString; kwargs...)
    start_date = first(date_range)
    end_date = last(date_range)
    energy_bids_table = read_hive(db, :BIDPEROFFER_D)
    pricebids_table = read_hive(db, :BIDDAYOFFER_D)

    bids = _massage_bids(
        energy_bids_table, pricebids_table, start_date, end_date;
        bid_type = bid_type, resolution = get(kwargs, :resolution, nothing),
    )
    trapezium = _read_fcas_trapezium(energy_bids_table, bid_type, start_date, end_date)
    return innerjoin(
        bids, trapezium; on = [:SETTLEMENTDATE, :INTERVAL_DATETIME, :DUID, :DIRECTION],
    )
end

function _read_fcas_trapezium(energy_bids_table, bid_type::AbstractString, start_date, end_date)
    sd = Date(start_date) - Day(1)
    ed = Date(end_date) + Day(1)
    trapezium = @eval @chain $energy_bids_table begin
        @select(
            SETTLEMENTDATE, BIDTYPE, INTERVAL_DATETIME, VERSIONNO, DUID, DIRECTION,
            ENABLEMENTMIN, LOWBREAKPOINT, HIGHBREAKPOINT, ENABLEMENTMAX, MAXAVAIL,
            ROCUP, ROCDOWN,
        )
        @filter($sd <= SETTLEMENTDATE, SETTLEMENTDATE <= $ed, BIDTYPE == $bid_type)
        # Only select the version no that are the latest for each interval and duid
        @group_by(SETTLEMENTDATE, INTERVAL_DATETIME, DUID, DIRECTION)
        @mutate(max_version = maximum(VERSIONNO))
        @filter(VERSIONNO == max_version)
        @select(
            SETTLEMENTDATE, INTERVAL_DATETIME, DUID, DIRECTION,
            ENABLEMENTMIN, LOWBREAKPOINT, HIGHBREAKPOINT, ENABLEMENTMAX, MAXAVAIL,
            ROCUP, ROCDOWN,
        )
        @collect
    end
    subset!(trapezium, :INTERVAL_DATETIME => ByRow(x -> start_date <= x < end_date))
    return trapezium
end

"""
    _extract_fcas_offer(row)

Mirrors [`_extract_power_bids`](@ref), additionally building an [`FCASTrapezium`](@ref).
Expects `row` to have the same `PRICEBANDARRAY`/`BANDAVAILARRAY` columns as
`_extract_power_bids`, the trapezium columns from [`_read_fcas_trapezium`](@ref), and a
`reserve_name` column (the target [`NEMFCASReserve`](@ref)'s name, e.g. `"RAISE6SEC_NSW1"`).
"""
function _extract_fcas_offer(row)
    curve_data = _extract_power_bids(row)
    offer_curve = make_market_bid_curve(curve_data, 0.0)
    trapezium = FCASTrapezium(;
        enablement_min = row.ENABLEMENTMIN,
        low_breakpoint = row.LOWBREAKPOINT,
        high_breakpoint = row.HIGHBREAKPOINT,
        enablement_max = row.ENABLEMENTMAX,
        max_avail = row.MAXAVAIL,
        ramp_up_rate = ismissing(row.ROCUP) ? nothing : Float64(row.ROCUP),
        ramp_down_rate = ismissing(row.ROCDOWN) ? nothing : Float64(row.ROCDOWN),
    )
    return FCASOffer(row.reserve_name, offer_curve, trapezium)
end

"""
    add_fcas_reserves!(sys, regions; bid_types = FCAS_BID_TYPES, requirement = 0.0)

Adds one [`ContingencyFCASReserve`](@ref)/[`RegulationFCASReserve`](@ref) service to `sys`
per (FCAS market, region) pair, matching how AEMO settles regional FCAS requirements
(mainland-vs-local contingency splits, e.g. SA islanding, are out of scope — see plan §4).
`regions` is an iterable of NEM region names (e.g. `["NSW1", "QLD1", ...]`) already present
as `PowerSystems.Area`s in `sys` (see `region_model.jl`).

Returns a `Dict{String, PowerSystems.Reserve}` keyed by reserve name (e.g.
`"RAISE6SEC_NSW1"`), for use by [`set_fcas_offers!`](@ref).
"""
function add_fcas_reserves!(sys, regions; bid_types = FCAS_BID_TYPES, requirement = 0.0)
    reserves = Dict{String, Reserve}()
    for region in regions
        area = get_component(Area, sys, region)
        for bid_type in bid_types
            direction = _fcas_direction(bid_type)
            name = "$(bid_type)_$(region)"
            reserve = if haskey(FCAS_CONTINGENCY_MARKETS, bid_type)
                ContingencyFCASReserve{direction}(;
                    name = name, available = true, region = area,
                    response_time = FCAS_CONTINGENCY_MARKETS[bid_type],
                    requirement = Float64(requirement),
                )
            else
                RegulationFCASReserve{direction}(;
                    name = name, available = true, region = area,
                    requirement = Float64(requirement),
                )
            end
            # No contributing devices yet - those attach incrementally in set_fcas_offers!
            # via add_service!(device, reserve, sys). PSY has no add_service!(sys, service)
            # two-arg form; every documented form takes a (possibly empty) devices arg too.
            add_service!(sys, reserve, Device[])
            reserves[name] = reserve
        end
    end
    return reserves
end

"""
    set_fcas_offers!(sys, db, date_range, region_reserves; kwargs...)

Adds FCAS bid data to the system, mirroring [`set_market_bids!`](@ref) for the energy bid
path. For every (market, device) combination with bid data in `date_range`:
- links the device to its regional [`NEMFCASReserve`](@ref) as a contributing device, via
  `PowerSystems.add_service!(device, reserve, sys)` (so `get_contributing_devices(sys,
  reserve)` finds it, same as any other PSY reserve);
- stores the priced [`FCASOffer`](@ref) (10-band offer curve + [`FCASTrapezium`](@ref)) in
  the device's `ext["fcas_offers"]::Vector{FCASOffer}`.

`ext` is used rather than swapping the device's `operation_cost` to a
[`NEMMarketBidCost`](@ref): confirmed directly (not just by reading the schema) that PSY's
auto-generated device structs declare `operation_cost` as a *closed* `Union` of specific
concrete cost types (e.g. `ThermalStandard.operation_cost::Union{ThermalGenerationCost,
MarketBidCost}`), not the abstract `OperationalCost`/`OfferCurveCost` supertype — so no
externally-defined `OfferCurveCost` subtype can ever be assigned there without modifying
PowerSystems' generated structs, which would violate the zero-core-changes goal this plan
is built on. `ext` is PSY's own sanctioned extension point for exactly this situation
("metadata that [isn't] used in simulation" — e.g. `region_model.jl`'s existing
`ext["station_name"]`/`ext["postcode"]` usage). The tradeoff: values stored there round-trip
through `to_json`/`System(path)` as plain `Dict`s, not reconstructed `FCASOffer` structs —
acceptable since simulation-time consumption of this data isn't in scope here (see plan §4).

Unlike energy bids (attached as a full `Deterministic` time series across `date_range` by
[`set_market_bids!`](@ref)), this attaches a single snapshot offer per device per market,
taken from the first interval in `date_range` — full time-varying FCAS bid ingestion is
deferred; see the NEMDE co-optimization scope note in the FCAS types plan.

# Arguments
- `sys`: The `PowerSystems.System` object. Should already have FCAS reserves added via
  [`add_fcas_reserves!`](@ref).
- `db`: The database connection.
- `date_range`: A range of dates for which to fetch FCAS bid data.
- `region_reserves::Dict{String, <:Reserve}`: FCAS reserves already added to `sys`, keyed
  by name (e.g. `"RAISE6SEC_NSW1"`) — see [`add_fcas_reserves!`](@ref).
"""
function set_fcas_offers!(sys, db, date_range, region_reserves::Dict{String, <:Reserve}; kwargs...)
    units = read_units(db)
    duid_region = Dict(zip(units.DUID, units.REGIONID))

    for bid_type in FCAS_BID_TYPES
        bids = read_fcas_bids(db, date_range, bid_type; kwargs...)
        DataFrames.isempty(bids) && continue
        transform!(bids, :DUID => ByRow(x -> get(duid_region, x, missing)) => :REGIONID)
        dropmissing!(bids, :REGIONID)
        DataFrames.isempty(bids) && continue
        transform!(bids, :REGIONID => ByRow(region -> "$(bid_type)_$(region)") => :reserve_name)
        transform!(bids, AsTable(:) => ByRow(_extract_fcas_offer) => :fcas_offer)

        foreach(get_components(Generator, sys)) do gen
            gen_id = get_name(gen)
            gen_bids = subset(bids, :DUID => ByRow(==(gen_id)), :DIRECTION => ByRow(==("GEN")))
            DataFrames.isempty(gen_bids) && return
            reserve_name = first(gen_bids.reserve_name)
            haskey(region_reserves, reserve_name) || return
            _add_fcas_offer!(sys, gen, region_reserves[reserve_name], first(gen_bids.fcas_offer))
        end
    end
    return
end

function _add_fcas_offer!(sys, gen, reserve::Reserve, offer::FCASOffer)
    add_service!(gen, reserve, sys)
    offers = get(get_ext(gen), "fcas_offers", FCASOffer[])
    push!(offers, offer)
    get_ext(gen)["fcas_offers"] = offers
    return
end

"""
    read_fcas_requirements(db, date_range)

Reads per-interval, per-region FCAS requirement quantities (MW) from the `RESERVE` table
(consumed nowhere else in this repo today), long-format: one row per
`(SETTLEMENTDATE, REGIONID, BIDTYPE, REQUIREMENT)`.

Note: as of this writing, `RESERVE`'s column set covers `LOWER5MIN, RAISE5MIN, RAISEREG,
LOWERREG` — the 6SEC/60SEC contingency markets need the corresponding columns added
(`AustralianElectricityMarketsData/nemweb_load/tables.jl` in the main branch's ingestion
restructuring); the query below reads whichever `FCAS_BID_TYPES` columns are present.
"""
function read_fcas_requirements(db, date_range)
    start_date = first(date_range)
    end_date = last(date_range)
    sd = Date(start_date) - Day(1)
    ed = Date(end_date) + Day(1)
    table = read_hive(db, :RESERVE)
    df = @eval @chain $table begin
        @filter($sd <= SETTLEMENTDATE, SETTLEMENTDATE <= $ed)
        @group_by(SETTLEMENTDATE, REGIONID)
        @mutate(max_version = maximum(VERSIONNO))
        @filter(VERSIONNO == max_version)
        @collect
    end
    subset!(df, :SETTLEMENTDATE => ByRow(x -> start_date <= x < end_date))
    bid_type_cols = intersect(names(df), collect(FCAS_BID_TYPES))
    isempty(bid_type_cols) && return DataFrame(SETTLEMENTDATE = DateTime[], REGIONID = String[], BIDTYPE = String[], REQUIREMENT = Float64[])
    long = stack(
        select(df, :SETTLEMENTDATE, :REGIONID, bid_type_cols...), bid_type_cols;
        variable_name = :BIDTYPE, value_name = :REQUIREMENT,
    )
    return long
end
