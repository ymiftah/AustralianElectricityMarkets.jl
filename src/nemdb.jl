using Dates
using TidierDB
using DataFrames
using Statistics
import TidierVest as TV
using ZipArchives: ZipReader, zip_names, zip_readentry
using Mmap: mmap
using QuackIO: write_table


"""
    read_hive(db::TidierDB.DBInterface.Connection,table_name::Symbol; config::HiveConfiguration=CONFIG[])

Read a hive-partitioned parquet dataset into a TidierDB table.

# Arguments
- `db::TidierDB.DBInterface.Connection`: The database connection to use.
- `table_name::Symbol`: The name of the table to read.
- `config::HiveConfiguration`: The configuration to use. Defaults to `CONFIG[]`.
"""
function read_hive(
        db::TidierDB.DBInterface.Connection,
        table_name::Symbol;
        config::HiveConfiguration = CONFIG[],
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
function _parse_hive_root(config::HiveConfiguration)
    if islocal(config)
        return config.hive_location
    else
        prefix = get_backend(config)
        return "$(prefix)://" * hive_location
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
db = connect(duckdb())
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
    df[!, :SETTLEMENTDATE] = floor.(df[!, :SETTLEMENTDATE], resolution)
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
        innerjoin(dudetail; on = [:DUID, :EFFECTIVEDATE, :VERSIONNO])
        sort(:DUID)
        select(Not([:archive_month]))
        unique
    end

    # # JOIN THE SUMMARY Table to match station (among other info)
    summary_table = read_hive(db, :DUDETAILSUMMARY)
    summary = @chain summary_table begin
        _filter_latest
        @filter(year(END_DATE) == 2999)  # AEMO specifies the latest version with a 2999-12-31 date
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
    max_eff_date = @eval @chain $table begin
        @summarise(max_key = maximum($key))
    end
    return @eval @chain $table begin
        @inner_join($max_eff_date, $key == max_key)
    end
end

"""
    fetch_table_data(table::Symbol, time_range; config::HiveConfiguration=CONFIG[])

Fetches data for a specified table over a given time range and populates the local cache.

It iterates through the months in the `time_range` and calls `populate` for each month to download and cache the data.

# Arguments
- `table::Symbol`: The name of the table to fetch data for (e.g., `:DISPATCHREGIONSUM`).
- `time_range`: A range of dates (e.g., `Date(2023, 1):Month(1):Date(2023, 3)`).
- `config::HiveConfiguration`: The configuration to use. Defaults to `CONFIG[]`.
"""
function fetch_table_data(table::Symbol, time_range; config::HiveConfiguration = CONFIG[])
    from_date = first(time_range)
    end_date = last(time_range)
    for date in from_date:Month(1):end_date
        populate(table, year(date), month(date); config = config)
    end
    return
end

"""
    populate(key::Symbol, year::Integer, month::Integer; config::HiveConfiguration=CONFIG[])

Downloads and caches a month of data for a given table from the AEMO NEMWEB data source.

If the data for the specified month and table already exists in the local cache, it does nothing. 
Otherwise, it constructs the URL, downloads the zipped CSV data, reads it, and writes it to the 
local hive-partitioned parquet cache.

# Arguments
- `key::Symbol`: The name of the table to populate (e.g., `:DISPATCHREGIONSUM`).
- `year::Integer`: The year of the data to fetch.
- `month::Integer`: The month of the data to fetch.
- `config::HiveConfiguration`: The configuration to use. Defaults to `CONFIG[]`.
"""
function populate(
        key::Symbol, year::Integer, month::Integer;
        config::HiveConfiguration = CONFIG[],
    )
    cols = get(NEMWEB_TABLE_SCHEMA, key) do
        throw("Key $key is not an option")
    end
    date = Date(year, month, 1)
    # Check whether the partition already exists
    cache_location = joinpath(config.hive_location, "$(string(key))")

    if islocal(config) && !isdir(config.hive_location)
        mkdir(config.hive_location)
    elseif islocal(config) && isdir(joinpath(cache_location, "archive_month=$(string(date))"))
        @info "Partition already exists for table $key, skipping download."
        return nothing
    end


    # No existing files, get them from AEMO website
    urls = get_data_url(string(key), year, month)

    tmpdir = mktempdir()
    frames = []
    for (i, url) in enumerate(urls)
        file_path = joinpath(tmpdir, "$key-$year-$month-$i.zip")
        if !isfile(file_path)
            @info "Downloading file from $url"
            download(url, file_path)
        end
        push!(frames, read_zip_csv(file_path; cols = cols))
    end
    df = vcat(frames...)
    insertcols!(df, :archive_month => date)

    return write_table(
        cache_location,
        df;
        format = :parquet,
        partition_by = :archive_month,
        filename_pattern = "$(string(key))-{i}",
        overwrite_or_ignore = true,
    )
end


"""
    read_zip_csv(path::String; select::Union{Nothing, Vector{Symbol}}=nothing)::DataFrame

Reads the first CSV file from a zip archive into a DataFrame.

This function is designed to handle the specific format of AEMO's zipped data files, 
which often contain a header section. It skips the initial metadata lines and only reads 
the data rows, identified by a value of "D" in the 'I' column, which is then dropped.

# Arguments
- `path::String`: The file path to the zip archive.
- `select::Union{Nothing, Vector{Symbol}}`: An optional vector of column names (as Symbols) to select from the CSV file. If `nothing`, all columns are read.

# Returns
- `DataFrame`: A DataFrame containing the data from the CSV file.
"""
function read_zip_csv(
        path::String;
        cols::Union{Nothing, Dict{Symbol, DataType}} = nothing,
    )::DataFrame
    select = keys(cols) |> collect
    if !isnothing(select)
        push!(select, :I)
    end
    csv = open(path) do archive
        zip = ZipReader(mmap(archive))
        file = first(zip_names(zip))
        entry = zip_readentry(zip, file)
        CSV.File(entry; header = 2, select = select, types = cols, dateformat = "yyyy/mm/dd HH:MM:SS")
    end
    df = DataFrame(csv)
    subset!(df, :I => ByRow(==("D")))
    select!(df, Not(:I))
    return df
end

"""
    get_data_url(data::String, year::Int, month::Int)

Constructs the URL(s) for downloading a specific AEMO NEMWEB dataset for a given year and month.

It scrapes the NEMWEB data archive page to find the correct link(s) to the zipped data file(s).

# Arguments
- `data::String`: The name of the dataset table (e.g., "DISPATCHREGIONSUM").
- `year::Int`: The year of the data.
- `month::Int`: The month of the data.

# Returns
- `Vector{String}`: A vector of full URL strings for the requested data files. Throws an error if no files are found.
"""
function get_data_url(data::String, year::Int, month::Int)
    year = string(year)
    month = lpad(month, 2, "0")
    files = @chain begin
        TV.read_html(
            "https://nemweb.com.au/Data_Archive/Wholesale_Electricity/MMSDM/$(year)/MMSDM_$(year)_$(month)/MMSDM_Historical_Data_SQLLoader/DATA/",
        )
        TV.html_elements("a")
        TV.html_attrs("href")
    end
    filtered_files = filter(
        x -> occursin(Regex("[%23]$(data)[%23]"), x),
        files
    )
    if isempty(filtered_files)
        filtered_files = filter(
            x -> occursin(Regex("PUBLIC_DVD_$(data)_"), x),
            files
        )
    end
    isempty(filtered_files) && throw("No files found for $(data), year:$year month:$month")
    return "https://nemweb.com.au" .* filtered_files
end
