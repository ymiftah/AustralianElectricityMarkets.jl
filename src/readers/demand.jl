"""
    read_demand(db, date_range; resolution::Dates.Period = Dates.Minute(5), intervention::Integer = 0)

Reads regional demand aggregated at `resolution`, over the aggregate timestamps in
`[first(date_range), last(date_range))`.

# Arguments
- `db`: The database connection.
- `date_range`: Range of aggregate timestamps, with an inclusive start and exclusive end.
- `resolution::Dates.Period`: The time resolution to which timestamps are rounded up. Defaults to 5 minutes.
- `intervention::Integer`: `0` for the pricing run. `1` for the physical run where the interval has
  one, else the pricing run. Each of `DISPATCHREGIONSUM` and `DISPATCHLOAD` decides its run per
  interval.

# Returns
A `DataFrame` with `SETTLEMENTDATE`, `REGIONID`, `TOTALDEMAND` and `LOSSDEMAND`, aggregated by the
specified resolution. `LOSSDEMAND` is `INITIALSUPPLY + DEMANDFORECAST` plus the initial charging
load of the region's `BIDIRECTIONAL` units (`DISPATCHLOAD.INITIALMW` where negative), with unit
type and region resolved as of the interval.

# Example
```julia
db = aem_connect()
demand = read_demand(db, DateTime(2025, 1, 1):Minute(5):DateTime(2025, 1, 2); resolution = Hour(1))
```
"""
function read_demand(db, date_range; resolution::Dates.Period = Dates.Minute(5), intervention::Integer = 0)
    _check_intervention(intervention)
    start_date, end_date = DateTime(first(date_range)), DateTime(last(date_range))
    # Each rounded-up timestamp includes the raw bin ending at it, even before the requested start.
    lower = ceil(start_date, resolution) - resolution
    upper = ceil(end_date, resolution) - resolution
    window = (lower, end_date)
    summary = read_hive(db, :DUDETAILSUMMARY)
    bucket = _ceil_timestamp_sql("r.SETTLEMENTDATE", resolution)
    return _query(
        db,
        """
        WITH bdu AS (
            SELECT DUID, REGIONID, START_DATE, END_DATE
            FROM $summary
            WHERE DISPATCHTYPE = 'BIDIRECTIONAL'
              AND archive_month = (SELECT max(archive_month) FROM $summary)
        ),
        load_run AS (
            SELECT * FROM $(read_hive(db, :DISPATCHLOAD, window))
            WHERE SETTLEMENTDATE > ? AND SETTLEMENTDATE <= ?
            QUALIFY COALESCE(INTERVENTION, 0) = CASE WHEN ? = 0 THEN 0
                ELSE max(COALESCE(INTERVENTION, 0)) OVER (PARTITION BY SETTLEMENTDATE) END
        ),
        initial_mw AS (
            SELECT DUID, SETTLEMENTDATE, INITIALMW
            FROM load_run
            QUALIFY row_number() OVER (PARTITION BY DUID, SETTLEMENTDATE ORDER BY archive_month DESC) = 1
        ),
        charging AS (
            SELECT d.SETTLEMENTDATE, bdu.REGIONID, sum(least(d.INITIALMW, 0.0)) AS INITIALCHARGE
            FROM initial_mw d
            JOIN bdu ON d.DUID = bdu.DUID
                AND bdu.START_DATE <= d.SETTLEMENTDATE
                AND (bdu.END_DATE IS NULL OR bdu.END_DATE > d.SETTLEMENTDATE)
            GROUP BY ALL
        ),
        demand_run AS (
            SELECT * FROM $(read_hive(db, :DISPATCHREGIONSUM, window))
            WHERE SETTLEMENTDATE > ? AND SETTLEMENTDATE <= ?
            QUALIFY COALESCE(INTERVENTION, 0) = CASE WHEN ? = 0 THEN 0
                ELSE max(COALESCE(INTERVENTION, 0)) OVER (PARTITION BY SETTLEMENTDATE) END
        ),
        raw_demand AS (
            SELECT $bucket AS SETTLEMENTDATE, r.REGIONID, r.TOTALDEMAND,
                   r.INITIALSUPPLY + r.DEMANDFORECAST + COALESCE(c.INITIALCHARGE, 0.0) AS LOSSDEMAND
            FROM demand_run r
            LEFT JOIN charging c ON c.SETTLEMENTDATE = r.SETTLEMENTDATE AND c.REGIONID = r.REGIONID
            WHERE r.SETTLEMENTDATE IS NOT NULL AND r.REGIONID IS NOT NULL AND r.TOTALDEMAND IS NOT NULL
        )
        SELECT SETTLEMENTDATE, REGIONID, avg(TOTALDEMAND) AS TOTALDEMAND,
               COALESCE(avg(LOSSDEMAND), 'NaN'::DOUBLE) AS LOSSDEMAND
        FROM raw_demand
        WHERE SETTLEMENTDATE >= ? AND SETTLEMENTDATE < ?
        GROUP BY SETTLEMENTDATE, REGIONID
        ORDER BY SETTLEMENTDATE, REGIONID
        """,
        [lower, upper, intervention, lower, upper, intervention, start_date, end_date],
    )
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
    _check_intervention(intervention)
    start_date, end_date = DateTime(first(date_range)), DateTime(last(date_range))
    # Each rounded-up timestamp includes the raw bin ending at it, even before the requested start.
    lower = ceil(start_date, resolution) - resolution
    upper = ceil(end_date, resolution) - resolution
    bucket = _ceil_timestamp_sql("SETTLEMENTDATE", resolution)
    return _query(
        db,
        """
        WITH demand_run AS (
            SELECT * FROM $(read_hive(db, :DISPATCHREGIONSUM, (lower, end_date)))
            WHERE SETTLEMENTDATE > ? AND SETTLEMENTDATE <= ?
            QUALIFY COALESCE(INTERVENTION, 0) = CASE WHEN ? = 0 THEN 0
                ELSE max(COALESCE(INTERVENTION, 0)) OVER (PARTITION BY SETTLEMENTDATE) END
        ),
        raw_regional AS (
            SELECT $bucket AS SETTLEMENTDATE, REGIONID, SS_SOLAR_UIGF, SS_WIND_UIGF
            FROM demand_run
            WHERE SETTLEMENTDATE IS NOT NULL AND REGIONID IS NOT NULL
        )
        SELECT SETTLEMENTDATE, REGIONID,
               avg(SS_SOLAR_UIGF) AS SS_SOLAR_UIGF,
               avg(SS_WIND_UIGF) AS SS_WIND_UIGF
        FROM raw_regional
        WHERE SETTLEMENTDATE >= ? AND SETTLEMENTDATE < ?
        GROUP BY SETTLEMENTDATE, REGIONID
        ORDER BY SETTLEMENTDATE, REGIONID
        """,
        [lower, upper, intervention, start_date, end_date],
    )
end
