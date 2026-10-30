"""
    _registration_window_sql() -> String

The `DUDETAILSUMMARY` predicate for a row registered at some instant of `[as_of, through]`, with
the bound parameters `(through, as_of)`: a registration covers `START_DATE < t <= END_DATE`, and an
interval-ending `t` is in the window when it lies after `START_DATE` and at or before `END_DATE`.
"""
function _registration_window_sql()
    return "START_DATE < ? AND (END_DATE IS NULL OR END_DATE >= ?)"
end


"""
    read_units(db; as_of = nothing, through = nothing)

Reads commissioned unit metadata, one row per `DUID` including scheduled loads. Scheduled loads
have no `GENUNITS` row, so their `CO2E_ENERGY_SOURCE` is `missing`. Every row carries the registration
span `REGISTERED_FROM` and `REGISTERED_UNTIL` (`2999-12-31` while open).

# Arguments
- `db`: the database connection.
- `as_of`: when a `Date` or `DateTime`, resolves `DUDETAIL` (latest `EFFECTIVEDATE <= as_of`, then
  highest `VERSIONNO`) and `DUDETAILSUMMARY` (the row with `START_DATE <= as_of < END_DATE`) as of
  that instant, omitting units with no such row. `nothing` keeps the open, latest cached version.
- `through`: with `as_of`, the end of a window. Selects every unit registered at some instant of
  `[as_of, through]`, takes its attributes from its earliest overlapping `DUDETAILSUMMARY` row and
  its `DUDETAIL` version in force at the later of `as_of` and that row's `START_DATE`, and spans
  `REGISTERED_FROM` and `REGISTERED_UNTIL` over all overlapping rows. Throws `ArgumentError` if a
  unit's `REGIONID`, `DISPATCHTYPE` or `SCHEDULE_TYPE` changes inside the window.

# Returns
A `DataFrame` with one row per commissioned `DUID`, including `CO2E_ENERGY_SOURCE`.

# Example
```julia
db = aem_connect()
units_df = read_units(db)
```
"""
function read_units(
        db; as_of::Union{Nothing, Date, DateTime} = nothing,
        through::Union{Nothing, Date, DateTime} = nothing,
    )
    isnothing(through) || !isnothing(as_of) || throw(ArgumentError("read_units: through requires as_of"))
    windowed = !isnothing(through)
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
    elseif windowed
        # The version in force depends on each unit's registration start, so it is chosen after the join.
        "WHERE archive_month = (SELECT max(archive_month) FROM dd_raw)"
    else
        "WHERE archive_month = (SELECT max(archive_month) FROM dd_raw) AND EFFECTIVEDATE <= ?"
    end
    summary_filter = if isnothing(as_of)
        """
        WHERE archive_month = (SELECT max(archive_month) FROM sm_raw)
          AND (END_DATE IS NULL OR year(END_DATE) = 2999)
        QUALIFY row_number() OVER (PARTITION BY DUID ORDER BY START_DATE ASC) = 1
        """
    elseif windowed
        # Window columns span every overlapping row, so they are computed before the QUALIFY keeps the earliest.
        """
        WHERE archive_month = (SELECT max(archive_month) FROM sm_raw) AND $(_registration_window_sql())
        QUALIFY row_number() OVER (PARTITION BY DUID ORDER BY START_DATE ASC) = 1
        """
    else
        """
        WHERE archive_month = (SELECT max(archive_month) FROM sm_raw)
          AND START_DATE <= ? AND (END_DATE IS NULL OR END_DATE > ?)
        QUALIFY row_number() OVER (PARTITION BY DUID ORDER BY START_DATE DESC) = 1
        """
    end
    window_columns = if windowed
        """
        , min(START_DATE) OVER (PARTITION BY DUID) AS REGISTERED_FROM,
        max(coalesce(END_DATE, TIMESTAMP '2999-12-31 00:00:00')) OVER (PARTITION BY DUID) AS REGISTERED_UNTIL,
        coalesce(min(REGIONID) OVER (PARTITION BY DUID) <> max(REGIONID) OVER (PARTITION BY DUID), false) AS _REGION_CHANGES,
        coalesce(min(DISPATCHTYPE) OVER (PARTITION BY DUID) <> max(DISPATCHTYPE) OVER (PARTITION BY DUID), false) AS _DISPATCHTYPE_CHANGES,
        coalesce(min(SCHEDULE_TYPE) OVER (PARTITION BY DUID) <> max(SCHEDULE_TYPE) OVER (PARTITION BY DUID), false) AS _SCHEDULE_CHANGES
        """
    else
        ", START_DATE AS REGISTERED_FROM, coalesce(END_DATE, TIMESTAMP '2999-12-31 00:00:00') AS REGISTERED_UNTIL"
    end
    # Windowed rows take the registration in force at the later of as_of and the summary row's start.
    dudetail_join = windowed ? "AND dudetail.EFFECTIVEDATE <= greatest(CAST(? AS TIMESTAMP), summary.START_DATE)" : ""
    dudetail_qualify = windowed ? "QUALIFY row_number() OVER (PARTITION BY dudetail.DUID ORDER BY dudetail.EFFECTIVEDATE DESC, dudetail.VERSIONNO DESC) = 1" : ""
    dudetail_latest = windowed ? "" : """
                     QUALIFY row_number() OVER (
                         PARTITION BY DUID ORDER BY EFFECTIVEDATE DESC, VERSIONNO DESC
                     ) = 1
        """

    # All filtering, latest-partition/version resolution, and joins are pushed
    # into DuckDB via CTEs.
    sql = """
        WITH dd_raw AS (SELECT * FROM $dudetail_table),
             dudetail AS (
                 SELECT * EXCLUDE (archive_month)
                 FROM dd_raw
                 $dudetail_as_of
                 $dudetail_latest
             ),
             sm_raw AS (SELECT * FROM $summary_table),
             summary AS (
                 SELECT * EXCLUDE (archive_month)$window_columns
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
        INNER JOIN summary ON dudetail.DUID = summary.DUID $dudetail_join
        INNER JOIN op_status ON summary.STATIONID = op_status.STATIONID
        WHERE op_status.STATUS = 'COMMISSIONED'
        $dudetail_qualify
        ORDER BY dudetail.DUID
    """
    params = if isnothing(as_of)
        []
    elseif windowed
        [through, as_of, as_of]
    else
        [as_of, as_of, as_of]
    end
    dudetail = isnothing(as_of) ? _query(db, sql) : _query(db, sql, params)
    if windowed
        changed = dudetail.DUID[dudetail._REGION_CHANGES .| dudetail._DISPATCHTYPE_CHANGES .| dudetail._SCHEDULE_CHANGES]
        isempty(changed) || throw(
            ArgumentError(
                "read_units: $(join(changed, ", ")) change REGIONID/DISPATCHTYPE/SCHEDULE_TYPE inside [$as_of, $through]; " *
                    "a single-chunk system cannot represent it",
            ),
        )
        select!(dudetail, Not([:_REGION_CHANGES, :_DISPATCHTYPE_CHANGES, :_SCHEDULE_CHANGES]))
    end
    if !isnothing(as_of)
        current = _query(
            db,
            """
            SELECT DISTINCT DUID FROM $summary_table
            WHERE archive_month = (SELECT max(archive_month) FROM $summary_table)
              AND (END_DATE IS NULL OR year(END_DATE) = 2999)
              $(windowed ? "AND START_DATE < ?" : "")
            """,
            windowed ? [through] : [],
        ).DUID
        dropped = setdiff(current, dudetail.DUID)
        isempty(dropped) ||
            @warn "read_units: $(length(dropped)) currently registered unit(s) are not in force as of $as_of and were omitted" first_dropped = first(dropped, 5)
    end
    return dudetail
end
