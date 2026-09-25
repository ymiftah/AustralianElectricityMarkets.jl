"""
    read_fcas_dispatch(db, date_range; intervention = 0)

Reads per-interval, per-unit FCAS dispatch outcomes from `DISPATCHLOAD`, long-format: one
row per `(SETTLEMENTDATE, DUID, BIDTYPE::BidType, TARGET, ACTUALAVAILABILITY)`, plus the
unit's energy context columns `INITIALMW`, `TOTALCLEARED`, `AVAILABILITY`, `AGCSTATUS`. This
is the cleared counterpart to [`read_fcas_bids`](@ref)'s offered trapezium - comparing
`TARGET`/`ACTUALAVAILABILITY` against the offer's trapezium shows how much of what a unit
offered was actually deliverable at its dispatched energy level (see [`FCASTrapezium`](@ref)).

`ACTUALAVAILABILITY` is `missing` for the two regulation markets (`RAISEREG`/`LOWERREG`) -
AEMO does not publish a trapezium-adjusted availability for regulation, only the raw offer
availability (`RAISEREGAVAILABILITY`/`LOWERREGAVAILABILITY`).

`intervention` selects the dispatch run: `0` is the normal (non-intervention) run
(`INTERVENTION` is compared via `COALESCE(INTERVENTION, 0)` for partitions predating that
column - see [`read_fcas_requirements`](@ref)).
"""
function read_fcas_dispatch(db, date_range; intervention::Integer = 0)
    start_date = first(date_range)
    end_date = last(date_range)
    sd = Date(start_date) - Day(1)
    ed = Date(end_date) + Day(1)
    table = read_hive(db, :DISPATCHLOAD)
    dispatch_schema = names(_query(db, "SELECT * FROM $table LIMIT 0"))
    params = Any[sd, ed]
    _push_intervention!(params, dispatch_schema, intervention)

    bidtype_cols = String[]
    for bid_type in FCAS_BID_TYPES
        bid_type_str = string(bid_type)
        bid_type_str in dispatch_schema || continue
        push!(bidtype_cols, _cast_double(bid_type_str))
        avail_col = "$(bid_type_str)ACTUALAVAILABILITY"
        avail_col in dispatch_schema && push!(bidtype_cols, _cast_double(avail_col))
    end
    select_list = join(
        [
            "SETTLEMENTDATE", "DUID",
            _cast_double("INITIALMW"), _cast_double("TOTALCLEARED"), _cast_double("AVAILABILITY"),
            "TRY_CAST(AGCSTATUS AS INTEGER) AS AGCSTATUS",
            bidtype_cols...,
        ],
        ", ",
    )
    df = _query(
        db,
        """
        SELECT $select_list
        FROM $table
        WHERE SETTLEMENTDATE BETWEEN ? AND ? $(_intervention_where(dispatch_schema))
        QUALIFY row_number() OVER (
            PARTITION BY SETTLEMENTDATE, DUID ORDER BY archive_month DESC
        ) = 1
        """,
        params,
    )
    subset!(df, :SETTLEMENTDATE => ByRow(x -> start_date <= x < end_date))

    long = DataFrame()
    for bid_type in FCAS_BID_TYPES
        bid_type_str = string(bid_type)
        target_col = bid_type_str
        avail_col = "$(bid_type_str)ACTUALAVAILABILITY"
        target_col in names(df) || continue
        block = select(
            df,
            :SETTLEMENTDATE, :DUID, :INITIALMW, :TOTALCLEARED, :AVAILABILITY, :AGCSTATUS,
            target_col => :TARGET,
        )
        block[!, :ACTUALAVAILABILITY] = avail_col in names(df) ? df[!, avail_col] : fill(missing, nrow(block))
        block[!, :BIDTYPE] = fill(bid_type, nrow(block))
        append!(long, block; promote = true)
    end
    return long
end

"""
    read_dispatch_limits(db, date_range; intervention = 0)

Reads per-interval, per-unit dispatch limits from `DISPATCHLOAD`: one row per
`(SETTLEMENTDATE, DUID)` with `INITIALMW`, `RAMPUPRATE`, `RAMPDOWNRATE` and `AVAILABILITY` —
the ramp rate and dispatch envelope NEMDE actually applied for that interval.

`AVAILABILITY` is the per-interval upper bound NEMDE applied: the `MAXAVAIL` bid availability
for a scheduled unit, or the lower of `MAXAVAIL` bid availability and `UIGF` for a
semi-scheduled unit.

`intervention` selects the dispatch run: `0` is the normal (non-intervention) run
(`INTERVENTION` is compared via `COALESCE(INTERVENTION, 0)` for partitions predating that
column — see [`read_fcas_requirements`](@ref)).

# Arguments
- `db`: an `AEMDB` connection.
- `date_range`: the dispatch intervals to read (half-open: `start <= t < stop`).
- `intervention`: `0` for the pricing run, `1` for the physical run.

# Returns
A `DataFrame` with `SETTLEMENTDATE`, `DUID`, `INITIALMW`, `RAMPUPRATE`, `RAMPDOWNRATE`,
`AVAILABILITY`.
"""
function read_dispatch_limits(db, date_range; intervention::Integer = 0)
    start_date = first(date_range)
    end_date = last(date_range)
    sd = Date(start_date) - Day(1)
    ed = Date(end_date) + Day(1)

    _table_is_cached(db, :DISPATCHLOAD) || throw(
        ArgumentError(
            "DISPATCHLOAD is not cached — run `populate(db, :DISPATCHLOAD, <from>, <to>)` first.",
        ),
    )
    table = read_hive(db, :DISPATCHLOAD)
    schema = names(_query(db, "SELECT * FROM $table LIMIT 0"))
    for col in ("RAMPUPRATE", "RAMPDOWNRATE", "AVAILABILITY")
        col in schema || throw(
            ArgumentError(
                "DISPATCHLOAD's cached partitions have no $col column at all — they predate " *
                    "AEMO publishing it. Run `populate(db, :DISPATCHLOAD, <from>, <to>; force_new = true)` " *
                    "to re-download.",
            ),
        )
    end

    params = Any[sd, ed]
    _push_intervention!(params, schema, intervention)
    df = _query(
        db,
        """
        SELECT SETTLEMENTDATE, DUID,
               $(_cast_double("INITIALMW")), $(_cast_double("RAMPUPRATE")), $(_cast_double("RAMPDOWNRATE")),
               $(_cast_double("AVAILABILITY"))
        FROM $table
        WHERE SETTLEMENTDATE BETWEEN ? AND ? $(_intervention_where(schema))
        QUALIFY row_number() OVER (
            PARTITION BY SETTLEMENTDATE, DUID ORDER BY archive_month DESC
        ) = 1
        """,
        params,
    )
    subset!(df, :SETTLEMENTDATE => ByRow(x -> start_date <= x < end_date))
    return df
end

"""
    read_fcas_scaling_inputs(db, date_range; intervention = 0)

Reads per-interval, per-unit AEMO *FCAS Model in NEMDE* §4.1/§4.2 scaling inputs from
`DISPATCHLOAD`: one row per `(SETTLEMENTDATE, DUID)` with `RAISEREGENABLEMENTMIN/MAX`,
`LOWERREGENABLEMENTMIN/MAX` (the telemetered AGC enablement limits, already the more
restrictive of bid and telemetered per AEMO's data model) and `RAMPUPRATE`/`RAMPDOWNRATE`
(the telemetered AGC ramp rate, MW/h - the same column [`read_dispatch_limits`](@ref) reads
for energy ramping).

`intervention` selects the dispatch run: `0` is the normal (non-intervention) run
(`INTERVENTION` is compared via `COALESCE(INTERVENTION, 0)` for partitions predating that
column - see [`read_fcas_requirements`](@ref)).

# Arguments
- `db`: an `AEMDB` connection.
- `date_range`: the dispatch intervals to read (half-open: `start <= t < stop`).
- `intervention`: `0` for the pricing run, `1` for the physical run.

# Returns
A `DataFrame` with `SETTLEMENTDATE`, `DUID`, `RAISEREGENABLEMENTMIN`, `RAISEREGENABLEMENTMAX`,
`LOWERREGENABLEMENTMIN`, `LOWERREGENABLEMENTMAX`, `RAMPUPRATE`, `RAMPDOWNRATE`.
"""
function read_fcas_scaling_inputs(db, date_range; intervention::Integer = 0)
    start_date = first(date_range)
    end_date = last(date_range)
    sd = Date(start_date) - Day(1)
    ed = Date(end_date) + Day(1)

    _table_is_cached(db, :DISPATCHLOAD) || throw(
        ArgumentError(
            "DISPATCHLOAD is not cached — run `populate(db, :DISPATCHLOAD, <from>, <to>)` first.",
        ),
    )
    table = read_hive(db, :DISPATCHLOAD)
    schema = names(_query(db, "SELECT * FROM $table LIMIT 0"))
    scaling_cols = (
        "RAISEREGENABLEMENTMIN", "RAISEREGENABLEMENTMAX",
        "LOWERREGENABLEMENTMIN", "LOWERREGENABLEMENTMAX", "RAMPUPRATE", "RAMPDOWNRATE",
    )
    for col in scaling_cols
        col in schema || throw(
            ArgumentError(
                "DISPATCHLOAD's cached partitions have no $col column at all — they predate " *
                    "AEMO publishing it. Run `populate(db, :DISPATCHLOAD, <from>, <to>; force_new = true)` " *
                    "to re-download.",
            ),
        )
    end

    params = Any[sd, ed]
    _push_intervention!(params, schema, intervention)
    select_list = join(["SETTLEMENTDATE", "DUID", (_cast_double(c) for c in scaling_cols)...], ", ")
    df = _query(
        db,
        """
        SELECT $select_list
        FROM $table
        WHERE SETTLEMENTDATE BETWEEN ? AND ? $(_intervention_where(schema))
        QUALIFY row_number() OVER (
            PARTITION BY SETTLEMENTDATE, DUID ORDER BY archive_month DESC
        ) = 1
        """,
        params,
    )
    subset!(df, :SETTLEMENTDATE => ByRow(x -> start_date <= x < end_date))
    return df
end

"""
    _uigf_rows(db, where_sql, params, intervention)

Raw `(SETTLEMENTDATE, DUID, UIGF)` rows behind both [`read_uigf`](@ref) methods, deduplicating
archive-month overlap.

`DISPATCHLOAD` carries one row per `(SETTLEMENTDATE, DUID, INTERVENTION)`, so ranking by
`archive_month` alone is enough - there is no forecast-priority dimension to break ties on
(unlike `INTERMITTENT_DS_RUN`, which publishes several forecast runs per interval).

Throws an `ArgumentError` when `DISPATCHLOAD` isn't cached at all. Warns and returns an empty
frame when it *is* cached but every cached partition predates the `UIGF` column - that is
legitimate schema evolution (`read_hive`'s `union_by_name` exists to tolerate it), not a
missing download, so it is not an error; referencing a column absent from *every* file in a
`read_hive` glob would otherwise be a hard DuckDB Binder Error.
"""
function _uigf_rows(db, where_sql::AbstractString, params::Vector{Any}, intervention::Integer)
    _table_is_cached(db, :DISPATCHLOAD) || throw(
        ArgumentError(
            "DISPATCHLOAD is not cached — run `populate(db, :DISPATCHLOAD, <from>, <to>)` first.",
        ),
    )
    table = read_hive(db, :DISPATCHLOAD)
    schema = names(_query(db, "SELECT * FROM $table LIMIT 0"))
    if !("UIGF" in schema)
        @warn "DISPATCHLOAD is cached, but none of its cached partitions have a UIGF column (they predate AEMO adding it); returning no UIGF rows."
        return DataFrame(SETTLEMENTDATE = DateTime[], DUID = String[], UIGF = Float64[])
    end
    _push_intervention!(params, schema, intervention)
    df = _query(
        db,
        """
        SELECT SETTLEMENTDATE, DUID, $(_cast_double("UIGF"))
        FROM $table
        WHERE $where_sql AND UIGF IS NOT NULL
          $(_intervention_where(schema))
        QUALIFY row_number() OVER (
            PARTITION BY SETTLEMENTDATE, DUID ORDER BY archive_month DESC
        ) = 1
        """,
        params,
    )
    dropmissing!(df, :UIGF)
    return df
end

"""
    read_uigf(db, date_range; resolution = Minute(5), intervention = 0)
    read_uigf(db, settlement_date::DateTime; intervention = 0)

Reads the per-unit Unconstrained Intermittent Generation Forecast (`DISPATCHLOAD.UIGF`) - the
upper limit NEMDE applies to each semi-scheduled unit for each dispatch interval.

`UIGF` is `NULL` for scheduled units, so only semi-scheduled DUIDs appear in the result. Over a
`date_range`, rows are ceiled onto `resolution` and averaged within each bucket, matching
[`read_demand`](@ref)'s convention. The `DateTime` method reads exactly one interval and skips
both the widened scan and the bucketing - use it when replicating a single dispatch interval.

`intervention` selects the dispatch run: `0` is the normal (non-intervention) run
(`INTERVENTION` is compared via `COALESCE(INTERVENTION, 0)` for partitions predating that
column - see [`read_fcas_requirements`](@ref)).

# Arguments
- `db`: an `AEMDB` connection.
- `date_range`: the range of interval timestamps to read (half-open: `start <= t < stop`).
- `settlement_date`: a single interval end, read exactly.
- `resolution`: the resolution to aggregate onto. Defaults to 5 minutes.
- `intervention`: 0 for the pricing run, 1 for the physical run.

# Returns
A `DataFrame` with `SETTLEMENTDATE`, `DUID` and `UIGF` (MW).

# Example
```julia
uigf = read_uigf(db, Date(2025, 1, 1):Date(2025, 1, 2); resolution = Minute(30))
one_interval = read_uigf(db, DateTime(2025, 1, 1, 0, 5))
```
"""
function read_uigf(db, date_range; resolution::Dates.Period = Minute(5), intervention::Integer = 0)
    start_date = first(date_range)
    end_date = last(date_range)
    df = _uigf_rows(
        db,
        "SETTLEMENTDATE BETWEEN ? AND ?",
        Any[Date(start_date) - Day(1), Date(end_date) + Day(1)],
        intervention,
    )
    isempty(df) && return df
    # Ceil onto `resolution` before filtering, matching `read_demand`/`set_demand!`: filtering
    # the raw stamps first would let an interval just inside the range (e.g. 01:55) round up
    # onto a bucket just outside it (02:00) and add a spurious trailing bucket.
    df[!, :SETTLEMENTDATE] = ceil.(df[!, :SETTLEMENTDATE], resolution)
    return @chain df begin
        groupby([:SETTLEMENTDATE, :DUID])
        combine(:UIGF => mean => :UIGF)
        subset(:SETTLEMENTDATE => ByRow(x -> start_date <= x < end_date))
        sort([:DUID, :SETTLEMENTDATE])
    end
end

function read_uigf(db, settlement_date::DateTime; intervention::Integer = 0)
    return _uigf_rows(db, "SETTLEMENTDATE = ?", Any[settlement_date], intervention)
end
