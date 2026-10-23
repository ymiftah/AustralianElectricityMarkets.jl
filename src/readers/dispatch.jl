"""
    read_dispatch_limits(db, date_range; intervention = 0)

Reads per-interval, per-unit dispatch limits from `DISPATCHLOAD`: one row per
`(SETTLEMENTDATE, DUID)` with `INITIALMW`, `RAMPUPRATE`, `RAMPDOWNRATE` and `AVAILABILITY`, the
ramp rates and dispatch envelope NEMDE applied for that interval. `AVAILABILITY` is the `MAXAVAIL`
bid availability of a scheduled unit, or the lower of `MAXAVAIL` and `UIGF` for a semi-scheduled
unit.

# Arguments
- `db`: an `AEMDB` connection.
- `date_range`: the dispatch intervals to read (half-open: `start <= t < stop`).
- `intervention`: `0` for the pricing run, `1` for the physical run.

# Returns
A `DataFrame` with `SETTLEMENTDATE`, `DUID`, `INITIALMW`, `RAMPUPRATE`, `RAMPDOWNRATE`,
`AVAILABILITY`. Throws an `ArgumentError` when `DISPATCHLOAD` is not cached or lacks a column.
"""
function read_dispatch_limits(db, date_range; intervention::Integer = 0)
    columns = ("INITIALMW", "RAMPUPRATE", "RAMPDOWNRATE", "AVAILABILITY")
    return _read_dispatch_table(db, :DISPATCHLOAD, "DUID", date_range; intervention) do schema
        _require_columns(:DISPATCHLOAD, schema, columns[2:end])
        return [_cast_double(c) for c in columns]
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
