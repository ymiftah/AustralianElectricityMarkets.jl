"""
    read_units(db; as_of = nothing)

Reads commissioned unit metadata, one row per `DUID` including scheduled loads. Scheduled loads
have no `GENUNITS` row, so their `CO2E_ENERGY_SOURCE` is `missing`.

# Arguments
- `db`: the database connection.
- `as_of`: when a `Date` or `DateTime`, resolves `DUDETAIL` (latest `EFFECTIVEDATE <= as_of`, then
  highest `VERSIONNO`) and `DUDETAILSUMMARY` (the row with `START_DATE <= as_of < END_DATE`) as of
  that instant, omitting units with no such row. `nothing` keeps the open, latest cached version.

# Returns
A `DataFrame` with one row per commissioned `DUID`, including `CO2E_ENERGY_SOURCE`.

# Example
```julia
db = aem_connect()
units_df = read_units(db)
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
