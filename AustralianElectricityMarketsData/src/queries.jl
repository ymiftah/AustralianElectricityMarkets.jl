"""
    read_hive(db::AEMDB, table_name::Symbol)

Builds the SQL `read_parquet(...)` source fragment for a hive-partitioned
parquet dataset, for use as a `FROM` source in a larger query.

Uses `union_by_name=true`: a table's `_TABLE_SPECS` entry can grow new columns over time
(AEMO widens NEMWEB tables, or this repo starts ingesting a column it previously skipped)
without invalidating partitions already on disk under the old, narrower schema - those
partitions just read back with `NULL` in the new columns instead of the glob raising a
schema-mismatch error.

# Arguments
- `db::AEMDB`: The database connection wrapper to use.
- `table_name::Symbol`: The name of the table to read.
"""
function read_hive(
        db::AEMDB,
        table_name::Symbol,
    )
    hive_root = _parse_hive_root(db.config)
    return "read_parquet('$hive_root/$table_name/**/*.parquet', hive_partitioning=true, union_by_name=true)"
end

"""
    _query(db::AEMDB, sql::String, params = ())

Executes `sql` against `db`'s connection and materializes the result as a `DataFrame`.
`params` are bound as positional `?` placeholders when provided.
"""
_query(db::AEMDB, sql::String) = DataFrame(DuckDB.execute(db.db, sql))
_query(db::AEMDB, sql::String, params) = DataFrame(DuckDB.execute(db.db, sql, params))

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
                 FROM ic
                 WHERE archive_month = (SELECT max(archive_month) FROM ic)
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
    # into DuckDB via CTEs.
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
                 FROM sm_raw
                 WHERE archive_month = (SELECT max(archive_month) FROM sm_raw)
                   AND (END_DATE IS NULL OR year(END_DATE) = 2999)
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
                 FROM gu_raw
                 WHERE archive_month = (SELECT max(archive_month) FROM gu_raw)
                 GROUP BY GENSETID
             ),
             dl_raw AS (SELECT * FROM $dualloc_table),
             dualloc AS (
                 SELECT GENSETID, DUID
                 FROM dl_raw
                 WHERE archive_month = (SELECT max(archive_month) FROM dl_raw)
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
    return dudetail
end

function read_energy_bids(db, date_range; kwargs...)
    start_datetime = first(date_range)
    end_datetime = last(date_range)
    sd = Date(start_datetime) - Day(1)
    ed = Date(end_datetime) + Day(1)
    source = read_hive(db, :BIDPEROFFER_D)
    # Discovered dynamically rather than hardcoded, since the number of bid bands
    # isn't fixed in application code.
    schema = names(_query(db, "SELECT * FROM $source LIMIT 0"))
    band_cols = join(filter(startswith("BANDAVAIL"), schema), ", ")

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
