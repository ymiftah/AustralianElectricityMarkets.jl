"""
    read_demand(db; resolution::Dates.Period=Dates.Minute(5), intervention::Integer=0)
    read_demand(db, date_range; resolution::Dates.Period=Dates.Minute(5), intervention::Integer=0)

Read regional demand and aggregate it at `resolution`. When `date_range` is provided,
read only the raw intervals contributing to aggregate timestamps in `[first(date_range), last(date_range))`.

# Arguments
- `db`: The database connection.
- `date_range`: Optional range of aggregate timestamps, with an inclusive start and exclusive end.
- `resolution::Dates.Period`: The time resolution to which timestamps are rounded up. Defaults to 5 minutes.
- `intervention::Integer`: `0` for the pricing run. `1` for the physical run where the interval has
  one, else the pricing run. Each of `DISPATCHREGIONSUM` and `DISPATCHLOAD` decides its run per
  interval; AEMO publishes both runs for an intervention interval, so region sums and unit loads
  come from the same run. Ignored where the cached partitions predate the `INTERVENTION` column.

# Returns
A `DataFrame` with regional demand, aggregated by the specified resolution.
`LOSSDEMAND` is `INITIALSUPPLY + DEMANDFORECAST` plus the initial charging load of the region's
`BIDIRECTIONAL` units (`DISPATCHLOAD.INITIALMW` where negative), with unit type and region resolved
as of the interval.

# Example
```julia
db = aem_connect()
demand_df = read_demand(db; resolution=Dates.Hour(1))
println(demand_df)
```
"""
function read_demand(db, date_range = nothing; resolution::Dates.Period = Dates.Minute(5), intervention::Integer = 0)
    summary = read_hive(db, :DUDETAILSUMMARY)
    if isnothing(date_range)
        source = read_hive(db, :DISPATCHREGIONSUM)
        dispatchload = read_hive(db, :DISPATCHLOAD)
        interval_bounds = "TRUE"
        interval_params = Any[]
    else
        # Each rounded-up timestamp includes the raw bin ending at it, even before the requested start.
        lower = ceil(DateTime(first(date_range)), resolution) - resolution
        upper = ceil(DateTime(last(date_range)), resolution) - resolution
        window = (lower, DateTime(last(date_range)))
        source = read_hive(db, :DISPATCHREGIONSUM, window)
        dispatchload = read_hive(db, :DISPATCHLOAD, window)
        interval_bounds = "SETTLEMENTDATE > ? AND SETTLEMENTDATE <= ?"
        interval_params = Any[lower, upper]
    end
    source_schema = _table_schema(db, source)
    dispatchload_schema = _table_schema(db, dispatchload)
    # Each table decides its run per interval. AEMO publishes both runs for an intervention interval,
    # so the region sums and the unit loads agree.
    charging_rows, charging_params = _run_rows(
        dispatchload, dispatchload_schema, intervention, "SETTLEMENTDATE", interval_bounds, interval_params,
    )
    demand_rows, demand_params = _run_rows(
        source, source_schema, intervention, "SETTLEMENTDATE", interval_bounds, interval_params,
    )
    # Parameters bind in the order of the `?` placeholders: charging, then demand, then bounds.
    params = Any[]
    append!(params, charging_params)
    append!(params, demand_params)
    bucket = _ceil_timestamp_sql("r.SETTLEMENTDATE", resolution)
    bounds = isnothing(date_range) ? "" : "WHERE SETTLEMENTDATE >= ? AND SETTLEMENTDATE < ?"
    isnothing(date_range) || append!(params, (first(date_range), last(date_range)))
    return _query(
        db,
        """
        WITH sm_raw AS (SELECT * FROM $summary),
             bdu AS (
                 SELECT DUID, REGIONID, START_DATE, END_DATE
                 FROM sm_raw
                 WHERE DISPATCHTYPE = 'BIDIRECTIONAL'
                   AND archive_month = (SELECT max(archive_month) FROM sm_raw)
             ),
             charging AS (
                 SELECT d.SETTLEMENTDATE, bdu.REGIONID, sum(least(d.INITIALMW, 0.0)) AS INITIALCHARGE
                 FROM (
                     SELECT DUID, SETTLEMENTDATE, INITIALMW
                     FROM $charging_rows AS dl
                     QUALIFY row_number() OVER (
                         PARTITION BY DUID, SETTLEMENTDATE ORDER BY archive_month DESC
                     ) = 1
                 ) d
                 JOIN bdu ON d.DUID = bdu.DUID
                     AND bdu.START_DATE <= d.SETTLEMENTDATE
                     AND (bdu.END_DATE IS NULL OR bdu.END_DATE > d.SETTLEMENTDATE)
                 GROUP BY ALL
             ),
             raw_demand AS (
                 SELECT $bucket AS SETTLEMENTDATE, r.REGIONID, r.TOTALDEMAND,
                        r.INITIALSUPPLY + r.DEMANDFORECAST + COALESCE(c.INITIALCHARGE, 0.0) AS LOSSDEMAND
                 FROM $demand_rows r
                 LEFT JOIN charging c ON c.SETTLEMENTDATE = r.SETTLEMENTDATE AND c.REGIONID = r.REGIONID
                 WHERE r.SETTLEMENTDATE IS NOT NULL AND r.REGIONID IS NOT NULL
                   AND r.TOTALDEMAND IS NOT NULL
             )
        SELECT SETTLEMENTDATE, REGIONID, avg(TOTALDEMAND) AS TOTALDEMAND,
               COALESCE(avg(LOSSDEMAND), 'NaN'::DOUBLE) AS LOSSDEMAND
        FROM raw_demand
        $bounds
        GROUP BY SETTLEMENTDATE, REGIONID
        ORDER BY SETTLEMENTDATE, REGIONID
        """,
        params,
    )
end

"""
    _current_regions(db; as_of = nothing) -> Set{String}

Regions in the latest cached `DISPATCHREGIONSUM` snapshot at or before `as_of`.
With `as_of = nothing`, uses the latest cached snapshot. Throws `ArgumentError` when no
snapshot is available.
"""
function _current_regions(db; as_of::Union{Nothing, Date, DateTime} = nothing)
    _require_cached(db, :DISPATCHREGIONSUM; context = "read_interconnectors needs it to identify the active regions.")
    table = read_hive(db, :DISPATCHREGIONSUM)
    bound = isnothing(as_of) ? "" : "AND SETTLEMENTDATE <= ?"
    sql = """
    SELECT DISTINCT REGIONID FROM $table
    WHERE REGIONID IS NOT NULL AND SETTLEMENTDATE = (
        SELECT max(SETTLEMENTDATE) FROM $table
        WHERE REGIONID IS NOT NULL $bound
    )
    """
    df = isnothing(as_of) ? _query(db, sql) : _query(db, sql, [as_of])
    isempty(df) && throw(
        ArgumentError(
            "read_interconnectors found no DISPATCHREGIONSUM snapshot" *
                (isnothing(as_of) ? "" : " at or before $as_of") *
                "; populate it with `populate(db, :DISPATCHREGIONSUM, start_date, end_date)`",
        ),
    )
    return Set(df.REGIONID)
end


"""
    _read_regional_renewable_uigf(db, date_range; resolution, intervention)

Reads the regional semi-scheduled solar and wind UIGF from `DISPATCHREGIONSUM`, averaged
onto `resolution` as [`read_demand`](@ref) aggregates demand.

# Arguments
- `db`: an `AEMDB` connection.
- `date_range`: the range of aggregate timestamps, with an inclusive start and exclusive end.
- `resolution`: the `Dates.Period` to aggregate onto.
- `intervention`: `0` for the pricing run. `1` for the physical run where the interval has one, else
  the pricing run.

# Returns
A `DataFrame` with `SETTLEMENTDATE`, `REGIONID`, `SS_SOLAR_UIGF` and `SS_WIND_UIGF`.
"""
function _read_regional_renewable_uigf(db, date_range; resolution::Dates.Period, intervention::Integer)
    # Each rounded-up timestamp includes the raw bin ending at it, even before the requested start.
    lower = ceil(DateTime(first(date_range)), resolution) - resolution
    upper = ceil(DateTime(last(date_range)), resolution) - resolution
    source = read_hive(db, :DISPATCHREGIONSUM, (lower, DateTime(last(date_range))))
    schema = _table_schema(db, source)
    rows, params = _run_rows(
        source, schema, intervention, "SETTLEMENTDATE", "SETTLEMENTDATE > ? AND SETTLEMENTDATE <= ?", [lower, upper],
    )
    append!(params, (DateTime(first(date_range)), DateTime(last(date_range))))
    bucket = _ceil_timestamp_sql("r.SETTLEMENTDATE", resolution)
    return _query(
        db,
        """
        WITH raw_regional AS (
            SELECT $bucket AS SETTLEMENTDATE, r.REGIONID, r.SS_SOLAR_UIGF, r.SS_WIND_UIGF
            FROM $rows r
            WHERE r.SETTLEMENTDATE IS NOT NULL AND r.REGIONID IS NOT NULL
        )
        SELECT SETTLEMENTDATE, REGIONID,
               avg(SS_SOLAR_UIGF) AS SS_SOLAR_UIGF,
               avg(SS_WIND_UIGF) AS SS_WIND_UIGF
        FROM raw_regional
        WHERE SETTLEMENTDATE >= ? AND SETTLEMENTDATE < ?
        GROUP BY SETTLEMENTDATE, REGIONID
        ORDER BY SETTLEMENTDATE, REGIONID
        """,
        params,
    )
end
