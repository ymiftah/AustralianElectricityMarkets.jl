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
- `intervention`: `0` for the pricing run, `1` for the physical run.
- `resolution`: the `Dates.Period` to aggregate onto. Defaults to 5 minutes.

# Returns
A `DataFrame` with `SETTLEMENTDATE`, `DUID`, `INITIALMW`, `RAMPUPRATE`, `RAMPDOWNRATE`,
`AVAILABILITY`. Throws an `ArgumentError` when `DISPATCHLOAD` is not cached or lacks a column.
"""
function read_dispatch_limits(db, date_range; intervention::Integer = 0, resolution::Dates.Period = Minute(5))
    columns = ("INITIALMW", "RAMPUPRATE", "RAMPDOWNRATE", "AVAILABILITY")
    start_date = first(date_range)
    end_date = last(date_range)
    # A row ceiled into the range has its raw stamp in [start - resolution, end).
    df = _read_dispatch_table(
        db, :DISPATCHLOAD, "DUID", (start_date - resolution, end_date); intervention,
    ) do schema
        _require_columns(:DISPATCHLOAD, schema, columns[2:end])
        return [_cast_double(c) for c in columns]
    end
    isempty(df) && return df
    sort!(df, [:DUID, :SETTLEMENTDATE])
    df[!, :SETTLEMENTDATE] = ceil.(df[!, :SETTLEMENTDATE], resolution)
    return @chain df begin
        groupby([:SETTLEMENTDATE, :DUID])
        combine(
            :INITIALMW => first => :INITIALMW,
            :RAMPUPRATE => minimum => :RAMPUPRATE,
            :RAMPDOWNRATE => minimum => :RAMPDOWNRATE,
            :AVAILABILITY => minimum => :AVAILABILITY,
        )
        subset(:SETTLEMENTDATE => ByRow(x -> start_date <= x < end_date))
        sort([:DUID, :SETTLEMENTDATE])
    end
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
- `intervention`: 0 for the pricing run, 1 for the physical run.

# Returns
A `DataFrame` with `SETTLEMENTDATE`, `DUID` and `UIGF` (MW). Throws an `ArgumentError` when
`DISPATCHLOAD` or `DUDETAILSUMMARY` is not cached or `DUDETAILSUMMARY` has no `SCHEDULE_TYPE`;
warns and returns an empty frame when no cached `DISPATCHLOAD` partition has a `UIGF` column.

# Example
```julia
uigf = read_uigf(db, Date(2025, 1, 1):Date(2025, 1, 2); resolution = Minute(30))
```
"""
function read_uigf(db, date_range; resolution::Dates.Period = Minute(5), intervention::Integer = 0)
    start_date = first(date_range)
    end_date = last(date_range)
    _require_cached(db, :DISPATCHLOAD)
    if !("UIGF" in _table_schema(db, read_hive(db, :DISPATCHLOAD)))
        @warn "DISPATCHLOAD is cached, but none of its cached partitions have a UIGF column (they predate AEMO adding it); returning no UIGF rows."
        return DataFrame(SETTLEMENTDATE = DateTime[], DUID = String[], UIGF = Float64[])
    end
    _require_cached(db, :DUDETAILSUMMARY)
    dudetailsummary = read_hive(db, :DUDETAILSUMMARY)
    "SCHEDULE_TYPE" in _table_schema(db, dudetailsummary) || throw(
        ArgumentError(
            "DUDETAILSUMMARY is cached without a SCHEDULE_TYPE column: re-populate it with " *
                "`populate(db, :DUDETAILSUMMARY, <from>, <to>; force_new = true)`.",
        ),
    )
    # A row ceiled into the range has its raw stamp in [start - resolution, end).
    semi_scheduled = """
        AND UIGF IS NOT NULL AND EXISTS (
            SELECT 1 FROM $dudetailsummary AS dus
            WHERE dus.DUID = src.DUID AND dus.SCHEDULE_TYPE = 'SEMI-SCHEDULED'
              AND dus.START_DATE <= src.SETTLEMENTDATE
              AND (dus.END_DATE IS NULL OR dus.END_DATE > src.SETTLEMENTDATE)
        )
    """
    df = _read_dispatch_table(
        [_cast_double("UIGF")], db, :DISPATCHLOAD, "DUID",
        (DateTime(start_date) - resolution, DateTime(end_date)); intervention, where = semi_scheduled,
    )
    dropmissing!(df, :UIGF)
    isempty(df) && return df
    # Ceil before filtering so a stamp just inside the range cannot add a bucket just outside it.
    df[!, :SETTLEMENTDATE] = ceil.(df[!, :SETTLEMENTDATE], resolution)
    return @chain df begin
        groupby([:SETTLEMENTDATE, :DUID])
        combine(:UIGF => mean => :UIGF)
        subset(:SETTLEMENTDATE => ByRow(x -> start_date <= x < end_date))
        sort([:DUID, :SETTLEMENTDATE])
    end
end

"""
    read_energy_limits(db, date_range; intervention = 0) -> DataFrame

Reads energy bid `MAXAVAIL`, the separate dispatch `UIGF`, and the effective schedule type
for each offered unit, direction and interval in the half-open `date_range`.

# Arguments
- `db`: an `AEMDB` connection with energy offers, dispatch results and registration data.
- `date_range`: the interval range, with an exclusive final timestamp.
- `intervention`: the dispatch run used for UIGF.

# Returns
A `DataFrame` with `SETTLEMENTDATE`, `DUID`, `DIRECTION`, `MAXAVAIL`, `UIGF` and
`SCHEDULE_TYPE`. Unmatched dispatch or registration data remain `missing`.
"""
function read_energy_limits(db, date_range; intervention::Integer = 0)
    offers = select(read_energy_bids(db, date_range), :INTERVAL_DATETIME, :DUID, :DIRECTION, :MAXAVAIL)
    uigf = _read_dispatch_table([_cast_double("UIGF")], db, :DISPATCHLOAD, "DUID", date_range; intervention)
    leftjoin!(offers, uigf; on = [:INTERVAL_DATETIME => :SETTLEMENTDATE, :DUID])
    summary = read_hive(db, :DUDETAILSUMMARY)
    return _with_registered(db, offers, "nem_energy_offers") do
        return _query(
            db,
            """
            WITH sm AS (
                SELECT * FROM $summary
                WHERE archive_month = (SELECT max(archive_month) FROM $summary)
            )
            SELECT o.INTERVAL_DATETIME AS SETTLEMENTDATE, o.DUID, o.DIRECTION,
                   TRY_CAST(o.MAXAVAIL AS DOUBLE) AS MAXAVAIL, o.UIGF, sm_at.SCHEDULE_TYPE
            FROM nem_energy_offers o
            -- An interval-ending stamp equal to END_DATE is still registered; a row starting at the stamp wins.
            LEFT JOIN LATERAL (
                SELECT SCHEDULE_TYPE FROM sm
                WHERE sm.DUID = o.DUID AND sm.START_DATE <= o.INTERVAL_DATETIME
                  AND (sm.END_DATE IS NULL OR sm.END_DATE >= o.INTERVAL_DATETIME)
                ORDER BY START_DATE DESC LIMIT 1
            ) sm_at ON true
            ORDER BY o.DUID, o.DIRECTION, o.INTERVAL_DATETIME
            """,
        )
    end
end
