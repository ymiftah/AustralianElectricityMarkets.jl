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
    read_interconnectors(db; as_of = nothing)

Reads and processes interconnector data from the database.

# Arguments
- `db`: The database connection.
- `as_of`: when a `Date` or `DateTime`, resolves each `INTERCONNECTORCONSTRAINT` row as of that
  instant (latest `EFFECTIVEDATE <= as_of`, then highest `VERSIONNO`). `nothing` keeps the latest
  version in the cache.

# Returns
A `DataFrame` containing the interconnector constraint data, latest or as of `as_of`. Interconnectors with an
endpoint region absent from the cached `DISPATCHREGIONSUM` are dropped with a warning, so that
table must be populated; an `ArgumentError` is thrown when it is missing or empty.

# Example
```julia
db = aem_connect()
interconnectors_df = read_interconnectors(db)
println(interconnectors_df)
```
"""
function read_interconnectors(db; as_of::Union{Nothing, Date, DateTime} = nothing)
    t_interconnector = read_hive(db, :INTERCONNECTOR)
    t_interconnector_constraint = read_hive(db, :INTERCONNECTORCONSTRAINT)

    # Each monthly archive holds the full history, so only the latest archive is read.
    as_of_filter = isnothing(as_of) ? "" : "WHERE c.EFFECTIVEDATE <= ?"
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
        $as_of_filter
        QUALIFY row_number() OVER (
            PARTITION BY c.INTERCONNECTORID ORDER BY c.EFFECTIVEDATE DESC, c.VERSIONNO DESC
        ) = 1
    """
    df = isnothing(as_of) ? _query(db, sql) : _query(db, sql, [as_of])
    current_regions = _current_regions(db)
    retired = filter(
        row -> !(row.REGIONFROM in current_regions) || !(row.REGIONTO in current_regions), df,
    )
    isempty(retired) ||
        @warn "read_interconnectors: dropping $(nrow(retired)) interconnector(s) with a retired endpoint region not present in DISPATCHREGIONSUM" interconnectors = retired.INTERCONNECTORID
    return filter(
        row -> row.REGIONFROM in current_regions && row.REGIONTO in current_regions, df,
    )
end

"""
    _current_regions(db) -> Set{String}

Every `REGIONID` present in the cached `DISPATCHREGIONSUM`, the authoritative source of which
regions are currently active - `INTERCONNECTOR`/`INTERCONNECTORCONSTRAINT` retain rows for
long-retired interconnectors (e.g. `SNOWY1`/`V-SN`, abolished 2008) that a naive
`REGIONFROM`/`REGIONTO` union would otherwise resurrect as a phantom, zero-demand region.
"""
function _current_regions(db)
    df = try
        table = read_hive(db, :DISPATCHREGIONSUM)
        _query(db, "SELECT DISTINCT REGIONID FROM $table WHERE REGIONID IS NOT NULL")
    catch err
        throw(
            ArgumentError(
                "read_interconnectors needs a cached DISPATCHREGIONSUM to identify the active regions; " *
                    "run `populate(db, :DISPATCHREGIONSUM, start_date, end_date)` first ($(sprint(showerror, err)))",
            ),
        )
    end
    isempty(df) && throw(
        ArgumentError(
            "read_interconnectors found no REGIONID in the cached DISPATCHREGIONSUM; " *
                "populate it with `populate(db, :DISPATCHREGIONSUM, start_date, end_date)`",
        ),
    )
    return Set(df.REGIONID)
end

"""
    read_demand(db; resolution::Dates.Period=Dates.Minute(5))

Read and process regional demand data from the database.

# Arguments
- `db`: The database connection.
- `resolution::Dates.Period`: The time resolution to which the data should be floored. Defaults to 5 minutes.

# Returns
A `DataFrame` with demand and renewable availability data, aggregated by the specified resolution.
`LOSSDEMAND` is `INITIALSUPPLY + DEMANDFORECAST`, the regional demand NEMDE feeds the interconnector
loss equations; it falls back to `TOTALDEMAND` where either term is missing.

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
        SELECT SETTLEMENTDATE, REGIONID, TOTALDEMAND,
               COALESCE(INITIALSUPPLY + DEMANDFORECAST, TOTALDEMAND) AS LOSSDEMAND,
               SS_SOLAR_AVAILABILITY, SS_WIND_AVAILABILITY
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
    read_units(db; as_of = nothing)

Gathers and processes unit data from the database: one row per commissioned `DUID`, including
scheduled loads, which have no `GENUNITS` row, so their `CO2E_ENERGY_SOURCE` is `missing`.

# Arguments
- `db`: The database connection.
- `as_of`: when a `Date` or `DateTime`, resolves `DUDETAIL` (latest `EFFECTIVEDATE <= as_of`,
  then highest `VERSIONNO`) and `DUDETAILSUMMARY` (the row with `START_DATE <= as_of < END_DATE`,
  so the loss factors in force then) as of that instant; units with no such row are omitted.
  `nothing` keeps the open, latest version in the cache.

# Returns
A `DataFrame` containing detailed information about each generation unit.

# Example
```julia
db = aem_connect()
units_df = read_units(db)
println(units_df)
```
"""
function read_units(db; as_of::Union{Nothing, Date, DateTime} = nothing)
    dudetail_table = read_hive(db, :DUDETAIL)
    summary_table = read_hive(db, :DUDETAILSUMMARY)
    op_status_table = read_hive(db, :STATIONOPERATINGSTATUS)
    station_table = read_hive(db, :STATION)
    gen_units_table = read_hive(db, :GENUNITS)
    dualloc_table = read_hive(db, :DUALLOC)

    # `as_of` is a DuckDB-bound parameter. Each monthly archive holds the full history, so both
    # as-of CTEs read the latest archive only; stale open rows live in older ones.
    dudetail_as_of = if isnothing(as_of)
        ""
    else
        "WHERE archive_month = (SELECT max(archive_month) FROM dd_raw) AND EFFECTIVEDATE <= ?"
    end
    summary_filter = if isnothing(as_of)
        """
        WHERE archive_month = (SELECT max(archive_month) FROM sm_raw)
          AND (END_DATE IS NULL OR year(END_DATE) = 2999)
        QUALIFY row_number() OVER (PARTITION BY DUID ORDER BY START_DATE ASC) = 1
        """
    else
        """
        WHERE archive_month = (SELECT max(archive_month) FROM sm_raw)
          AND START_DATE <= ? AND (END_DATE IS NULL OR END_DATE > ?)
        QUALIFY row_number() OVER (PARTITION BY DUID ORDER BY START_DATE DESC) = 1
        """
    end

    # All filtering, latest-partition/version resolution, and joins are pushed
    # into DuckDB via CTEs.
    sql = """
        WITH dd_raw AS (SELECT * FROM $dudetail_table),
             dudetail AS (
                 SELECT * EXCLUDE (archive_month)
                 FROM dd_raw
                 $dudetail_as_of
                 QUALIFY row_number() OVER (
                     PARTITION BY DUID ORDER BY EFFECTIVEDATE DESC, VERSIONNO DESC
                 ) = 1
             ),
             sm_raw AS (SELECT * FROM $summary_table),
             summary AS (
                 SELECT * EXCLUDE (archive_month)
                 FROM sm_raw
                 $summary_filter
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
                 SELECT DISTINCT GENSETID, DUID
                 FROM dl_raw
                 WHERE archive_month = (SELECT max(archive_month) FROM dl_raw)
             ),
             -- One row per DUID: DUALLOC lists legacy GENSETID-named DUIDs and multi-genset DUIDs.
             genunits AS (
                 SELECT d.DUID, first(g.CO2E_ENERGY_SOURCE ORDER BY g.GENSETID) AS CO2E_ENERGY_SOURCE,
                        first(g.CO2E_EMISSIONS_FACTOR ORDER BY g.GENSETID) AS CO2E_EMISSIONS_FACTOR
                 FROM genunits_raw g
                 INNER JOIN dualloc d ON g.GENSETID = d.GENSETID
                 GROUP BY d.DUID
             )
        SELECT dudetail.*, summary.* EXCLUDE (DUID), op_status.* EXCLUDE (STATIONID),
               genunits.CO2E_ENERGY_SOURCE, genunits.CO2E_EMISSIONS_FACTOR
        FROM dudetail
        LEFT JOIN genunits ON dudetail.DUID = genunits.DUID
        INNER JOIN summary ON dudetail.DUID = summary.DUID
        INNER JOIN op_status ON summary.STATIONID = op_status.STATIONID
        WHERE op_status.STATUS = 'COMMISSIONED'
        ORDER BY dudetail.DUID
    """
    dudetail = isnothing(as_of) ? _query(db, sql) : _query(db, sql, [as_of, as_of, as_of])
    if !isnothing(as_of)
        current = _query(
            db,
            """
            SELECT DISTINCT DUID FROM $summary_table
            WHERE archive_month = (SELECT max(archive_month) FROM $summary_table)
              AND (END_DATE IS NULL OR year(END_DATE) = 2999)
            """,
        ).DUID
        dropped = setdiff(current, dudetail.DUID)
        isempty(dropped) ||
            @warn "read_units: $(length(dropped)) currently registered unit(s) are not in force as of $as_of and were omitted" first_dropped = first(dropped, 5)
    end
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

"""
    read_mnsp_offers(db, date_range)

Reads the MNSP link offers NEMDE applied in each dispatch interval of `date_range`.

Each interval's offer is the one named by `DISPATCH_MNSPBIDTRK` (dispatch run 1), joined to its
`MNSP_DAYOFFER` price bands and its `MNSP_BIDOFFERPERIOD` availability for that interval's
five-minute period of the trading day. The tables cover trading days from the five-minute
settlement start; earlier days live in `MNSP_PEROFFER`.

# Arguments
- `db`: The database connection.
- `date_range`: Interval-ending timestamps; intervals `t` with `first(date_range) <= t < last(date_range)` are returned.

# Returns
A `DataFrame` with one row per `(INTERVAL_DATETIME, LINKID)`: `PARTICIPANTID`, `MAXAVAIL`,
`FIXEDLOAD` (`missing` when no fixed load), `RAMPUPRATE`, `BANDAVAIL1`-`BANDAVAIL10` and
`PRICEBAND1`-`PRICEBAND10`.

# Example
```julia
db = aem_connect()
offers = read_mnsp_offers(db, DateTime(2026, 6, 15, 12):Minute(5):DateTime(2026, 6, 15, 13))
```
"""
function read_mnsp_offers(db, date_range)
    band_cols = join(("o.PRICEBAND$i" for i in 1:10), ", ") * ", " *
        join(("p.BANDAVAIL$i" for i in 1:10), ", ")
    # Interval t ending at `t` belongs to the trading day starting 04:00 of CAST(t - 5 min - 4 h); its
    # period is the number of five-minute steps since that 04:00.
    df = _query(
        db,
        """
        WITH trk AS (
            SELECT SETTLEMENTDATE AS INTERVAL_DATETIME, LINKID, PARTICIPANTID, OFFERSETTLEMENTDATE,
                   OFFEREFFECTIVEDATE, OFFERVERSIONNO,
                   CAST(SETTLEMENTDATE - INTERVAL 5 MINUTE - INTERVAL 4 HOUR AS DATE) AS TRADINGDATE
            FROM $(read_hive(db, :DISPATCH_MNSPBIDTRK))
            WHERE RUNNO = 1 AND SETTLEMENTDATE >= ? AND SETTLEMENTDATE < ?
        )
        SELECT trk.INTERVAL_DATETIME, trk.LINKID, trk.PARTICIPANTID, p.MAXAVAIL, p.FIXEDLOAD, p.RAMPUPRATE,
               $band_cols
        FROM trk
        INNER JOIN $(read_hive(db, :MNSP_DAYOFFER)) AS o
            ON o.SETTLEMENTDATE = trk.OFFERSETTLEMENTDATE AND o.LINKID = trk.LINKID
           AND o.PARTICIPANTID = trk.PARTICIPANTID AND o.OFFERDATE = trk.OFFEREFFECTIVEDATE
           AND o.VERSIONNO = trk.OFFERVERSIONNO
        INNER JOIN $(read_hive(db, :MNSP_BIDOFFERPERIOD)) AS p
            ON p.TRADINGDATE = trk.TRADINGDATE AND p.LINKID = trk.LINKID
           AND p.OFFERDATETIME = trk.OFFEREFFECTIVEDATE
           AND p.PERIODID = date_diff('minute', CAST(trk.TRADINGDATE AS TIMESTAMP) + INTERVAL 4 HOUR, trk.INTERVAL_DATETIME) / 5
        ORDER BY trk.INTERVAL_DATETIME, trk.LINKID
        """,
        [first(date_range), last(date_range)],
    )
    return df
end

"""
    read_mnsp_links(db, as_of)

Reads the registered MNSP links as of `as_of`: the latest `MNSP_INTERCONNECTOR` version of each
`LINKID` whose `EFFECTIVEDATE` is on or before `as_of`.

The table still carries superseded rows for interconnectors that are no longer MNSPs, so a caller
pairs it with [`read_mnsp_offers`](@ref), which names the links that offer in an interval.

# Arguments
- `db`: The database connection.
- `as_of`: A `Date` or `DateTime`.

# Returns
A `DataFrame` with one row per link: `LINKID`, `INTERCONNECTORID`, `FROMREGION`, `TOREGION`,
`FROM_REGION_TLF`, `TO_REGION_TLF`, `LHSFACTOR` and `MAXCAPACITY`. A link's flow runs from
`FROMREGION` to `TOREGION`.

# Example
```julia
db = aem_connect()
links = read_mnsp_links(db, DateTime(2026, 6, 15))
```
"""
function read_mnsp_links(db, as_of::Union{Date, DateTime})
    return _query(
        db,
        """
        SELECT LINKID, INTERCONNECTORID, FROMREGION, TOREGION, FROM_REGION_TLF, TO_REGION_TLF,
               LHSFACTOR, MAXCAPACITY
        FROM $(read_hive(db, :MNSP_INTERCONNECTOR))
        WHERE EFFECTIVEDATE <= ?
        QUALIFY row_number() OVER (PARTITION BY LINKID ORDER BY EFFECTIVEDATE DESC, VERSIONNO DESC) = 1
        ORDER BY INTERCONNECTORID, LINKID
        """,
        [as_of],
    )
end
