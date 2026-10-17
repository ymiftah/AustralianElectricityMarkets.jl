"""
    read_energy_limits(db, date_range; intervention = 0) -> DataFrame

Reads energy bid `MAXAVAIL`, the separate dispatch `UIGF`, and the effective schedule type
for each offered unit, direction and interval in the half-open `date_range`.

# Returns
A `DataFrame` with `SETTLEMENTDATE`, `DUID`, `DIRECTION`, `MAXAVAIL`, `UIGF` and
`SCHEDULE_TYPE`. Unmatched dispatch or registration data remain `missing`.
"""
function read_energy_limits(db, date_range; intervention::Integer = 0)
    offers = select(read_energy_bids(db, date_range), :INTERVAL_DATETIME, :DUID, :DIRECTION, :MAXAVAIL)
    dispatch = read_hive(db, :DISPATCHLOAD)
    summary = read_hive(db, :DUDETAILSUMMARY)
    schema = names(_query(db, "SELECT * FROM $dispatch LIMIT 0"))
    forecast = "UIGF" in schema ? "TRY_CAST(UIGF AS DOUBLE)" : "CAST(NULL AS DOUBLE)"
    params = Any[first(date_range), last(date_range)]
    _push_intervention!(params, schema, intervention)
    DuckDB.register_data_frame(db.db, offers, "nem_energy_offers")
    try
        return _query(
            db,
            """
            WITH dl AS (
                SELECT SETTLEMENTDATE, DUID, $forecast AS UIGF
                FROM $dispatch
                WHERE SETTLEMENTDATE >= ? AND SETTLEMENTDATE < ? $(_intervention_where(schema))
                QUALIFY row_number() OVER (
                    PARTITION BY SETTLEMENTDATE, DUID ORDER BY archive_month DESC
                ) = 1
            ), sm AS (
                SELECT * FROM $summary
                WHERE archive_month = (SELECT max(archive_month) FROM $summary)
            )
            SELECT o.INTERVAL_DATETIME AS SETTLEMENTDATE, o.DUID, o.DIRECTION,
                   TRY_CAST(o.MAXAVAIL AS DOUBLE) AS MAXAVAIL, dl.UIGF, sm_at.SCHEDULE_TYPE
            FROM nem_energy_offers o
            LEFT JOIN dl ON dl.DUID = o.DUID AND dl.SETTLEMENTDATE = o.INTERVAL_DATETIME
            LEFT JOIN LATERAL (
                SELECT SCHEDULE_TYPE FROM sm
                WHERE sm.DUID = o.DUID AND sm.START_DATE <= o.INTERVAL_DATETIME
                  AND (sm.END_DATE IS NULL OR sm.END_DATE > o.INTERVAL_DATETIME)
                ORDER BY START_DATE DESC LIMIT 1
            ) sm_at ON true
            ORDER BY o.DUID, o.DIRECTION, o.INTERVAL_DATETIME
            """, params,
        )
    finally
        DuckDB.unregister_table(db.db, "nem_energy_offers")
    end
end
