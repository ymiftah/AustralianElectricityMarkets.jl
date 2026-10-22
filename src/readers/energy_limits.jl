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
`SCHEDULE_TYPE`. Unmatched dispatch or registration data remain `missing`. A cached `DISPATCHLOAD` without
a `UIGF` column raises an error.
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
            LEFT JOIN LATERAL (
                SELECT SCHEDULE_TYPE FROM sm
                WHERE sm.DUID = o.DUID AND sm.START_DATE <= o.INTERVAL_DATETIME
                  AND (sm.END_DATE IS NULL OR sm.END_DATE > o.INTERVAL_DATETIME)
                ORDER BY START_DATE DESC LIMIT 1
            ) sm_at ON true
            ORDER BY o.DUID, o.DIRECTION, o.INTERVAL_DATETIME
            """,
        )
    end
end
