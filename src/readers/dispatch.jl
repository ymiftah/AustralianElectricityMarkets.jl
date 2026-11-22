"""
    read_dispatch_limits(db, date_range; intervention = 0, resolution = Minute(5))

Reads per-unit dispatch limits from `DISPATCHLOAD`: `INITIALMW`, `RAMPUPRATE`, `RAMPDOWNRATE` and
`AVAILABILITY`, the ramp rates and dispatch envelope NEMDE applied for each 5-minute interval.
`AVAILABILITY` is the `MAXAVAIL` bid availability of a scheduled unit, or the lower of `MAXAVAIL`
and `UIGF` for a semi-scheduled unit.

With a `resolution` coarser than five minutes, the intervals are ceiled onto it and each bucket keeps
the `INITIALMW` at its first interval (the metered MW at the start of the period) and the minimum of
each ramp rate and `AVAILABILITY` across its intervals.

!!! warning
    Coarse buckets aggregate the available rows without checking five-minute coverage. An
    incomplete bucket can shift `INITIALMW` away from the period start and omit more restrictive
    ramp rates or availability limits. Ensure the cache covers every five-minute interval.

# Arguments
- `db`: an `AEMDB` connection.
- `date_range`: the dispatch intervals to read (half-open: `start <= t < stop`).
- `intervention`: `0` for the pricing run. `1` for the physical run where the interval has one, else the pricing run.
- `resolution`: the `Dates.Period` to aggregate onto. Defaults to 5 minutes.

# Returns
A `DataFrame` with `SETTLEMENTDATE`, `DUID`, `INITIALMW`, `RAMPUPRATE`, `RAMPDOWNRATE`,
`AVAILABILITY`. Throws an `ArgumentError` when `DISPATCHLOAD` has no cached partition for the range.
"""
function read_dispatch_limits(db, date_range; intervention::Integer = 0, resolution::Dates.Period = Minute(5))
    _check_intervention(intervention)
    start_date, end_date = first(date_range), last(date_range)
    # A row ceiled into the range has its raw stamp in [start - resolution, end).
    source = read_hive(db, :DISPATCHLOAD, (start_date - resolution, end_date))
    bucket = _ceil_timestamp_sql("SETTLEMENTDATE", resolution)
    return _query(
        db,
        """
        WITH run AS (
            SELECT * FROM $source
            WHERE SETTLEMENTDATE >= ? AND SETTLEMENTDATE < ?
            QUALIFY COALESCE(INTERVENTION, 0) = CASE WHEN ? = 0 THEN 0
                ELSE max(COALESCE(INTERVENTION, 0)) OVER (PARTITION BY SETTLEMENTDATE) END
        ),
        limits AS (
            SELECT SETTLEMENTDATE, DUID,
                   TRY_CAST(INITIALMW AS DOUBLE) AS INITIALMW,
                   TRY_CAST(RAMPUPRATE AS DOUBLE) AS RAMPUPRATE,
                   TRY_CAST(RAMPDOWNRATE AS DOUBLE) AS RAMPDOWNRATE,
                   TRY_CAST(AVAILABILITY AS DOUBLE) AS AVAILABILITY
            FROM run
            QUALIFY row_number() OVER (PARTITION BY SETTLEMENTDATE, DUID ORDER BY archive_month DESC) = 1
        ),
        buckets AS (
            SELECT $bucket AS SETTLEMENTDATE, DUID,
                   first(INITIALMW ORDER BY SETTLEMENTDATE) AS INITIALMW,
                   min(RAMPUPRATE) AS RAMPUPRATE,
                   min(RAMPDOWNRATE) AS RAMPDOWNRATE,
                   min(AVAILABILITY) AS AVAILABILITY
            FROM limits
            GROUP BY ALL
        )
        SELECT * FROM buckets
        WHERE SETTLEMENTDATE >= ? AND SETTLEMENTDATE < ?
        ORDER BY DUID, SETTLEMENTDATE
        """,
        [start_date - resolution, end_date, intervention, start_date, end_date],
    )
end


"""
    read_uigf(db, date_range; resolution = Minute(5), intervention = 0)

Reads the per-unit Unconstrained Intermittent Generation Forecast (`DISPATCHLOAD.UIGF`), the
upper limit NEMDE applies to each semi-scheduled unit in each dispatch interval. Only DUIDs that
`DUDETAILSUMMARY` lists as `SEMI-SCHEDULED` at the interval appear. Rows are ceiled onto
`resolution` and averaged within each bucket, as [`read_demand`](@ref) does.

# Arguments
- `db`: an `AEMDB` connection.
- `date_range`: the range of interval timestamps to read (half-open: `start <= t < stop`).
- `resolution`: the resolution to aggregate onto. Defaults to 5 minutes.
- `intervention`: `0` for the pricing run. `1` for the physical run where the interval has one, else the pricing run.

# Returns
A `DataFrame` with `SETTLEMENTDATE`, `DUID` and `UIGF` (MW). Throws an `ArgumentError` when
`DISPATCHLOAD` has no cached partition for the range or `DUDETAILSUMMARY` is not cached.

# Example
```julia
uigf = read_uigf(db, Date(2025, 1, 1):Date(2025, 1, 2); resolution = Minute(30))
```
"""
function read_uigf(db, date_range; resolution::Dates.Period = Minute(5), intervention::Integer = 0)
    _check_intervention(intervention)
    start_date, end_date = DateTime(first(date_range)), DateTime(last(date_range))
    # A row ceiled into the range has its raw stamp in [start - resolution, end).
    source = read_hive(db, :DISPATCHLOAD, (start_date - resolution, end_date))
    _require_cached(db, :DUDETAILSUMMARY)
    summary = read_hive(db, :DUDETAILSUMMARY)
    bucket = _ceil_timestamp_sql("SETTLEMENTDATE", resolution)
    return _query(
        db,
        """
        WITH run AS (
            SELECT * FROM $source
            WHERE SETTLEMENTDATE >= ? AND SETTLEMENTDATE < ?
            QUALIFY COALESCE(INTERVENTION, 0) = CASE WHEN ? = 0 THEN 0
                ELSE max(COALESCE(INTERVENTION, 0)) OVER (PARTITION BY SETTLEMENTDATE) END
        ),
        semi_scheduled AS (
            SELECT SETTLEMENTDATE, DUID, TRY_CAST(UIGF AS DOUBLE) AS UIGF
            FROM run AS src
            WHERE UIGF IS NOT NULL AND EXISTS (
                SELECT 1 FROM $summary AS dus
                WHERE dus.DUID = src.DUID AND dus.SCHEDULE_TYPE = 'SEMI-SCHEDULED'
                  AND dus.START_DATE <= src.SETTLEMENTDATE
                  AND (dus.END_DATE IS NULL OR dus.END_DATE > src.SETTLEMENTDATE)
            )
            QUALIFY row_number() OVER (PARTITION BY SETTLEMENTDATE, DUID ORDER BY archive_month DESC) = 1
        ),
        buckets AS (
            SELECT $bucket AS SETTLEMENTDATE, DUID, avg(UIGF) AS UIGF
            FROM semi_scheduled
            WHERE UIGF IS NOT NULL
            GROUP BY ALL
        )
        SELECT * FROM buckets
        WHERE SETTLEMENTDATE >= ? AND SETTLEMENTDATE < ?
        ORDER BY DUID, SETTLEMENTDATE
        """,
        [start_date - resolution, end_date, intervention, start_date, end_date],
    )
end

"""
    read_unit_conditions(db, date_range; intervention = 0) -> DataFrame

Reads each unit's operating condition from one `DISPATCHLOAD` read: the metered and dispatch
state (`INITIALMW`, `AVAILABILITY`, `RAMPUPRATE`, `RAMPDOWNRATE`, `UIGF`, `DISPATCHMODE`,
`DISPATCHMODETIME`, `AGCSTATUS`), the regulation enablement limits and the regulation availabilities, for each
interval of the half-open `date_range`. Rates are as published: MW/h, and the ramp rates are
the lesser of bid and telemetered rate.

# Arguments
- `db`: an `AEMDB` connection.
- `date_range`: the five-minute dispatch intervals to read (half-open: `start <= t < stop`).
- `intervention`: `0` for the pricing run. `1` for the physical run where the interval has one, else the pricing run.

# Returns
A `DataFrame` with `SETTLEMENTDATE`, `DUID`, `INITIALMW`, `AVAILABILITY`, `RAMPUPRATE`,
`RAMPDOWNRATE`, `UIGF`, `DISPATCHMODE`, `DISPATCHMODETIME`, `AGCSTATUS`, `RAISEREGENABLEMENTMIN`, `RAISEREGENABLEMENTMAX`,
`LOWERREGENABLEMENTMIN`, `LOWERREGENABLEMENTMAX`, `RAISEREGAVAILABILITY` and `LOWERREGAVAILABILITY`,
sorted by `DUID` and `SETTLEMENTDATE`. Throws an `ArgumentError` when `DISPATCHLOAD` has no cached
partition for the range.
"""
function read_unit_conditions(db, date_range; intervention::Integer = 0)
    _check_intervention(intervention)
    source = read_hive(db, :DISPATCHLOAD, date_range)
    return _query(
        db,
        """
        WITH run AS (
            SELECT * FROM $source
            WHERE SETTLEMENTDATE >= ? AND SETTLEMENTDATE < ?
            QUALIFY COALESCE(INTERVENTION, 0) = CASE WHEN ? = 0 THEN 0
                ELSE max(COALESCE(INTERVENTION, 0)) OVER (PARTITION BY SETTLEMENTDATE) END
        )
        SELECT SETTLEMENTDATE, DUID,
               TRY_CAST(INITIALMW AS DOUBLE) AS INITIALMW,
               TRY_CAST(AVAILABILITY AS DOUBLE) AS AVAILABILITY,
               TRY_CAST(RAMPUPRATE AS DOUBLE) AS RAMPUPRATE,
               TRY_CAST(RAMPDOWNRATE AS DOUBLE) AS RAMPDOWNRATE,
               TRY_CAST(UIGF AS DOUBLE) AS UIGF,
               TRY_CAST(DISPATCHMODE AS DOUBLE) AS DISPATCHMODE,
               TRY_CAST(DISPATCHMODETIME AS DOUBLE) AS DISPATCHMODETIME,
               TRY_CAST(AGCSTATUS AS DOUBLE) AS AGCSTATUS,
               TRY_CAST(RAISEREGENABLEMENTMIN AS DOUBLE) AS RAISEREGENABLEMENTMIN,
               TRY_CAST(RAISEREGENABLEMENTMAX AS DOUBLE) AS RAISEREGENABLEMENTMAX,
               TRY_CAST(LOWERREGENABLEMENTMIN AS DOUBLE) AS LOWERREGENABLEMENTMIN,
               TRY_CAST(LOWERREGENABLEMENTMAX AS DOUBLE) AS LOWERREGENABLEMENTMAX,
               TRY_CAST(RAISEREGAVAILABILITY AS DOUBLE) AS RAISEREGAVAILABILITY,
               TRY_CAST(LOWERREGAVAILABILITY AS DOUBLE) AS LOWERREGAVAILABILITY
        FROM run
        QUALIFY row_number() OVER (PARTITION BY SETTLEMENTDATE, DUID ORDER BY archive_month DESC) = 1
        ORDER BY DUID, SETTLEMENTDATE
        """,
        [first(date_range), last(date_range), intervention],
    )
end
