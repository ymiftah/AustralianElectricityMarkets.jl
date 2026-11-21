"""
    _registered_duids(db, duids, as_of, through) -> Set{String}

The DUIDs of `duids` that `DUDETAILSUMMARY` (latest archive) registers at some instant of
`[as_of, through]`.
"""
function _registered_duids(db, duids, as_of, through)
    isempty(duids) && return Set{String}()
    summary = read_hive(db, :DUDETAILSUMMARY)
    wanted = DataFrame(DUID = unique(String.(duids)))
    registered = _with_registered(db, wanted, "wanted_duids") do
        return _query(
            db,
            """
            SELECT DISTINCT DUID FROM $summary
            WHERE archive_month = (SELECT max(archive_month) FROM $summary)
              AND DUID IN (SELECT DUID FROM wanted_duids)
              AND START_DATE < ? AND (END_DATE IS NULL OR END_DATE >= ?)
            """,
            [through, as_of],
        )
    end
    return Set{String}(registered.DUID)
end


"""
    read_units(db, date_range)

Reads the commissioned units registered at some dispatch interval of `date_range`, one row per
`DUID` including scheduled loads. A unit's attributes come from its earliest `DUDETAILSUMMARY` row
overlapping the range and its `DUDETAIL` version in force at the later of `first(date_range)` and
that row's `START_DATE`. Scheduled loads have no `GENUNITS` row, so their `CO2E_ENERGY_SOURCE` is
`missing`.

# Arguments
- `db`: the database connection.
- `date_range`: the half-open range of interval-ending stamps; the last interval is
  `last(date_range) - Minute(5)`.

# Returns
A `DataFrame` with one row per commissioned `DUID`, including `CO2E_ENERGY_SOURCE`,
`CO2E_EMISSIONS_FACTOR` and the registration span `REGISTERED_FROM` and `REGISTERED_UNTIL`
(`2999-12-31` while open) over every overlapping `DUDETAILSUMMARY` row. Throws an `ArgumentError`
if a unit's `REGIONID`, `DISPATCHTYPE` or `SCHEDULE_TYPE` changes inside the range, and warns about
currently registered units the range omits.

# Example
```julia
db = aem_connect()
units = read_units(db, DateTime(2025, 1, 1):Minute(5):DateTime(2025, 1, 2))
```
"""
function read_units(db, date_range)
    as_of, through = DateTime(first(date_range)), DateTime(last(date_range)) - Minute(5)
    dudetail = read_hive(db, :DUDETAIL)
    summary = read_hive(db, :DUDETAILSUMMARY)
    units = _query(
        db,
        """
        WITH dudetail AS (
            SELECT * EXCLUDE (archive_month) FROM $dudetail
            WHERE archive_month = (SELECT max(archive_month) FROM $dudetail)
        ),
        -- The earliest registration row overlapping the range, with the span and changes over all of them.
        summary AS (
            SELECT * EXCLUDE (archive_month),
                   CAST(min(START_DATE) OVER (PARTITION BY DUID) AS TIMESTAMP) AS REGISTERED_FROM,
                   CAST(max(coalesce(END_DATE, TIMESTAMP '2999-12-31 00:00:00')) OVER (PARTITION BY DUID) AS TIMESTAMP) AS REGISTERED_UNTIL,
                   coalesce(min(REGIONID) OVER (PARTITION BY DUID) <> max(REGIONID) OVER (PARTITION BY DUID), false) AS _REGION_CHANGES,
                   coalesce(min(DISPATCHTYPE) OVER (PARTITION BY DUID) <> max(DISPATCHTYPE) OVER (PARTITION BY DUID), false) AS _DISPATCHTYPE_CHANGES,
                   coalesce(min(SCHEDULE_TYPE) OVER (PARTITION BY DUID) <> max(SCHEDULE_TYPE) OVER (PARTITION BY DUID), false) AS _SCHEDULE_CHANGES
            FROM $summary
            WHERE archive_month = (SELECT max(archive_month) FROM $summary)
              AND START_DATE < ? AND (END_DATE IS NULL OR END_DATE >= ?)
            QUALIFY row_number() OVER (PARTITION BY DUID ORDER BY START_DATE ASC) = 1
        ),
        commissioned_max AS (
            SELECT STATIONID, max(EFFECTIVEDATE) AS EFFECTIVEDATE, max(archive_month) AS archive_month
            FROM $(read_hive(db, :STATIONOPERATINGSTATUS))
            WHERE STATUS = 'COMMISSIONED'
            GROUP BY STATIONID
        ),
        -- One row per STATIONID: a station's name or postcode can change across archive months.
        station_names AS (
            SELECT STATIONID, STATIONNAME, POSTCODE
            FROM $(read_hive(db, :STATION))
            QUALIFY row_number() OVER (PARTITION BY STATIONID ORDER BY archive_month DESC) = 1
        ),
        op_status AS (
            SELECT DISTINCT o.STATIONID, o.STATUS, s.STATIONNAME, s.POSTCODE
            FROM $(read_hive(db, :STATIONOPERATINGSTATUS)) o
            INNER JOIN commissioned_max m
              ON o.STATIONID = m.STATIONID AND o.EFFECTIVEDATE = m.EFFECTIVEDATE AND o.archive_month = m.archive_month
            LEFT JOIN station_names s ON o.STATIONID = s.STATIONID
        ),
        gu_raw AS (SELECT * FROM $(read_hive(db, :GENUNITS))),
        genunits_raw AS (
            SELECT GENSETID, first(CO2E_ENERGY_SOURCE) AS CO2E_ENERGY_SOURCE, first(CO2E_EMISSIONS_FACTOR) AS CO2E_EMISSIONS_FACTOR
            FROM gu_raw
            WHERE archive_month = (SELECT max(archive_month) FROM gu_raw)
            GROUP BY GENSETID
        ),
        dl_raw AS (SELECT * FROM $(read_hive(db, :DUALLOC))),
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
        -- The DUDETAIL version in force at the later of the range start and the registration start.
        INNER JOIN summary ON dudetail.DUID = summary.DUID
            AND dudetail.EFFECTIVEDATE <= greatest(CAST(? AS TIMESTAMP), summary.START_DATE)
        INNER JOIN op_status ON summary.STATIONID = op_status.STATIONID
        WHERE op_status.STATUS = 'COMMISSIONED'
        QUALIFY row_number() OVER (PARTITION BY dudetail.DUID ORDER BY dudetail.EFFECTIVEDATE DESC, dudetail.VERSIONNO DESC) = 1
        ORDER BY dudetail.DUID
        """,
        [through, as_of, as_of],
    )
    changed = @chain units begin
        subset([:_REGION_CHANGES, :_DISPATCHTYPE_CHANGES, :_SCHEDULE_CHANGES] => ByRow(|))
        _.DUID
    end
    isempty(changed) || throw(
        ArgumentError(
            "read_units: $(join(changed, ", ")) change REGIONID/DISPATCHTYPE/SCHEDULE_TYPE inside [$as_of, $through]; " *
                "a single-chunk system cannot represent it",
        ),
    )
    select!(units, Not([:_REGION_CHANGES, :_DISPATCHTYPE_CHANGES, :_SCHEDULE_CHANGES]))
    current = _query(
        db,
        """
        SELECT DISTINCT DUID FROM $summary
        WHERE archive_month = (SELECT max(archive_month) FROM $summary)
          AND (END_DATE IS NULL OR year(END_DATE) = 2999) AND START_DATE < ?
        """,
        [through],
    )
    dropped = setdiff(current.DUID, units.DUID)
    isempty(dropped) ||
        @warn "read_units: $(length(dropped)) currently registered unit(s) are not registered between $as_of and $through and were omitted" first_dropped = first(dropped, 5)
    return units
end
