using PythonCall
using Dates
using TidierDB
using DataFrames
using Statistics

"""
    read_hive(db::TidierDB.DBInterface.Connection,table_name::Symbol; config::PyHiveConfiguration=CONFIG[])

Read a hive-partitioned parquet dataset into a TidierDB table.

# Arguments
- `db::TidierDB.DBInterface.Connection`: The database connection to use.
- `table_name::Symbol`: The name of the table to read.
- `config::PyHiveConfiguration`: The configuration to use. Defaults to `CONFIG[]`.
"""
function read_hive(
    db::TidierDB.DBInterface.Connection,
    table_name::Symbol;
    config::PyHiveConfiguration=CONFIG[],
)
    hive_root = _parse_hive_root(config)
    hive_path = """
    read_parquet(
        "$hive_root/$table_name/**/*.parquet",
        hive_partitioning=true
    )
    """
    return TidierDB.dt(db, hive_path)
end

"""
    _parse_hive_root(config::PyHiveConfiguration)

Construct the correct path to the Hive dataset based on the specified filesystem.

# Arguments
- `config::PyHiveConfiguration`: The configuration object containing filesystem and location details.
"""
function _parse_hive_root(config::PyHiveConfiguration)
    if config.filesystem == "local"
        return config.hive_location
    elseif config.filesystem == "gs"
        return "gs://" * hive_location
    end
    throw("Not a known filesystem")
end

"""
    fetch_table_data(table::Symbol, time_range::Any; location::String=CONFIG[].hive_location, filesystem=CONFIG[].filesystem)

Download and cache data for a given `table` and `time_range`.

# Arguments
- `table::Symbol`: The table to populate.
- `time_range::Any`: The time range to populate data for. (e.g. `Date(2023,1,1):Date(2023,3,1)`)
- `location::String`: The directory to cache data in. Defaults to `~/.nemweb_cache`.
- `filesystem::String`: The filesystem to use for the cache. Defaults to `local`.
"""
function fetch_table_data(
    table::Symbol,
    time_range::Any;
    location::String=CONFIG[].hive_location,
    filesystem=CONFIG[].filesystem,
)
    dbs = _get_pydb_manager(location, filesystem)
    dbItem = pygetattr(dbs, String(table), nothing)
    if isnothing(dbItem)
        available_tables = list_available_tables()
        throw("No such table exists. Available tables are $available_tables")
    end
    from_date = first(time_range)
    to_date = last(time_range)
    return dbItem.populate(pyslice(Py(from_date), Py(to_date)))
end

"""
    list_available_tables()::Array{String}

List the available tables to fetch data for.
"""
function list_available_tables()::Array{Symbol}
    nemdb = pyimport("nemdb")
    config = nemdb.Config
    dbs = nemdb.NEMWEBManager(config)
    return Symbol.(pyconvert(Array, dbs.active_tables()))
end

"""
    _get_pydb_manager(location::String, filesystem::String)

Get a python `nemdb.NEMWEBManager` object.

# Arguments
- `location::String`: The directory to cache data in.
- `filesystem::String`: The filesystem to use for the cache.
"""
function _get_pydb_manager(location::String, filesystem::String)
    nemdb = pyimport("nemdb")
    config = nemdb.Config
    config.set_cache_dir(location)
    config.set_filesystem(filesystem)
    return nemdb.NEMWEBManager(config)
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
db = connect(duckdb())
interconnectors_df = read_interconnectors(db)
println(interconnectors_df)
```
"""
function read_interconnectors(db)
    t_interconnector = read_hive(db, :INTERCONNECTOR)
    t_interconnector_constraint = read_hive(db, :INTERCONNECTORCONSTRAINT)
    interconnector_ids = @chain t_interconnector begin
        AustralianElectricityMarket._filter_latest
    end

    @chain t_interconnector_constraint begin
        @inner_join(interconnector_ids, INTERCONNECTORID, archive_month)
        @arrange(INTERCONNECTORID, desc(EFFECTIVEDATE), desc(VERSIONNO))
        @collect
        unique(:INTERCONNECTORID, keep=:first)
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
db = connect(duckdb())
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
function read_demand(db; resolution::Dates.Period=Dates.Minute(5))
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
    df[!, :SETTLEMENTDATE] = floor.(df[!, :SETTLEMENTDATE], resolution)
    sort!(df, :SETTLEMENTDATE)
    @chain df begin
        groupby([:SETTLEMENTDATE, :REGIONID])
        combine(_, valuecols(_) .=> mean ∘ skipmissing; renamecols=false)
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
db = connect(duckdb())
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
        innerjoin(dudetail; on=[:DUID, :EFFECTIVEDATE, :VERSIONNO])
        sort(:DUID)
        select(Not([:archive_month]))
        unique
    end

    # # JOIN THE SUMMARY Table to match station (among other info)
    summary_table = read_hive(db, :DUDETAILSUMMARY)
    summary = @chain summary_table begin
        _filter_latest
        @filter(ismissing(END_DATE))
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
        leftjoin(station_names; on=:STATIONID)
        select!(:STATIONID, :STATUS, :STATIONNAME, :POSTCODE)
        unique!(; keep=:last)
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
            renamecols=false,
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
        unique!([:GENSETID]; keep=:last)
        select!(:GENSETID, :DUID)
    end
    genunits = @chain innerjoin(genunits, dualloc; on=:GENSETID) begin
        select!(Not(:GENSETID))
        unique
    end

    # # Joins
    dudetail = innerjoin(dudetail, genunits; on=:DUID)
    dudetail = innerjoin(dudetail, summary; on=:DUID, makeunique=true)
    dudetail = innerjoin(dudetail, op_status; on=:STATIONID)
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

function _filter_latest(table, key)
    max_eff_date = @eval @chain $table begin
        @summarise(max_key = maximum($key))
    end
    @eval @chain $table begin
        @inner_join($max_eff_date, $key == max_key)
    end
end

const FUEL_MAPPING = Dict(
    "Black Coal" => ThermalFuels.COAL,
    "Brown Coal" => ThermalFuels.COAL,
    "Gas" => ThermalFuels.NATURAL_GAS,
    "Liquid Fuel" => ThermalFuels.DISTILLATE_FUEL_OIL,
    "Water" => ThermalFuels.OTHER,
    "Solar" => ThermalFuels.OTHER,
    "Wind" => ThermalFuels.OTHER,
)

const FUEL_PRICES = Dict(
    "Black Coal" => 9.0,
    "Brown Coal" => 9.0,
    "Gas" => 17.0,
    "Liquid Fuel" => 13.0,
    "Water" => 0.0,
    "Solar" => 0.0,
    "Wind" => 0.0,
)

const PM_MAPPING = Dict(
    "Steam Sub Critical" => PrimeMovers.ST,
    "Steam Super Critical" => PrimeMovers.ST,
    "CCGT" => PrimeMovers.CC,
    "CCGT Cogen" => PrimeMovers.CC,
    "CCGT - Gas Turbine" => PrimeMovers.CA,
    "CCGT - Steam Turbine" => PrimeMovers.CA,
    "OCGT" => PrimeMovers.GT,
    "Gas-powered steam turbine" => PrimeMovers.GT,
    "Reciprocating Engine" => PrimeMovers.IC,
    "Hydro" => PrimeMovers.HY,
    "Large scale Solar PV" => PrimeMovers.PVe,
    "Wind" => PrimeMovers.WT,
    "Pumped Hydro" => PrimeMovers.PS,
)

const AEMO_PM_MAPPING = Dict(
    "Natural Gas (Pipeline)" => PrimeMovers.CC,
    "Coal seam methane" => PrimeMovers.CC,
    "Coal Seam Methane" => PrimeMovers.CC,
    "Hydro" => PrimeMovers.HY,
    "Wind" => PrimeMovers.WT,
    "Solar" => PrimeMovers.PVe,
    "Brown coal" => PrimeMovers.ST,
    "Black coal" => PrimeMovers.ST,
    "Battery Storage" => PrimeMovers.BA,
    "Diesel oil" => PrimeMovers.IC,
    "Kerosene - non aviation" => PrimeMovers.GT,
    "Landfill biogas methane" => PrimeMovers.CC,
    "Other Biofuels" => PrimeMovers.CC,
    "Bagasse" => PrimeMovers.CC,
    "Coal mine waste gas" => PrimeMovers.CC,
    "Ethane" => PrimeMovers.GT,
    "Biomass and industrial materials" => PrimeMovers.IC,
    "Primary solid biomass fuels" => PrimeMovers.IC,
    "Other solid fossil fuels" => PrimeMovers.IC,
    missing => missing,
)

const AEMO_FUEL_MAPPING = Dict(
    "Black coal" => ThermalFuels.COAL,
    "Brown coal" => ThermalFuels.COAL,
    "Natural Gas (Pipeline)" => ThermalFuels.NATURAL_GAS,
    "Coal seam methane" => ThermalFuels.OTHER_GAS,
    "Coal Seam Methane" => ThermalFuels.OTHER_GAS,
    "Kerosene - non aviation" => ThermalFuels.DISTILLATE_FUEL_OIL,
    "Diesel oil" => ThermalFuels.DISTILLATE_FUEL_OIL,
    "Solar" => ThermalFuels.OTHER,
    "Wind" => ThermalFuels.OTHER,
    "Hydro" => ThermalFuels.OTHER,
    "Battery Storage" => ThermalFuels.OTHER,
    "Landfill biogas methane" => ThermalFuels.AG_BIPRODUCT,
    "Other Biofuels" => ThermalFuels.AG_BIPRODUCT,
    "Primary solid biomass fuels" => ThermalFuels.AG_BIPRODUCT,
    "Bagasse" => ThermalFuels.AG_BIPRODUCT,
    "Coal mine waste gas" => ThermalFuels.OTHER_GAS,
    "Ethane" => ThermalFuels.OTHER_GAS,
    "Biomass and industrial materials" => ThermalFuels.AG_BIPRODUCT,
    "Other solid fossil fuels" => ThermalFuels.WASTE_COAL,
    missing => missing,
)
