"""
    read_prices(db, date_range; intervention = 0)

Reads per-interval, per-region **energy** spot prices from `DISPATCHPRICE`: one row per
`(SETTLEMENTDATE, REGIONID)` with `RRP`, `ROP`, `APCFLAG`.

`RRP` is the settlement price; `ROP` is the price before scaling, capping, or VoLL
override - they differ exactly when `APCFLAG != 0` (an administered price cap event). See
[`read_fcas_prices`](@ref) for the FCAS-market equivalent.

`intervention` selects the dispatch run: `0` is the normal (non-intervention) run.

`APCFLAG` is `missing` for cached partitions that predate its addition to `_TABLE_SPECS`
(and `INTERVENTION` is compared via `COALESCE(INTERVENTION, 0)` for the same reason).
"""
function read_prices(db, date_range; intervention::Integer = 0)
    start_date = first(date_range)
    end_date = last(date_range)
    sd = Date(start_date) - Day(1)
    ed = Date(end_date) + Day(1)
    table = read_hive(db, :DISPATCHPRICE)
    schema = names(_query(db, "SELECT * FROM $table LIMIT 0"))
    params = Any[sd, ed]
    _push_intervention!(params, schema, intervention)

    select_cols = ["SETTLEMENTDATE", "REGIONID", _cast_double("RRP"), _cast_double("ROP")]
    "APCFLAG" in schema && push!(select_cols, "TRY_CAST(APCFLAG AS INTEGER) AS APCFLAG")
    select_list = join(select_cols, ", ")
    df = _query(
        db,
        """
        SELECT $select_list
        FROM $table
        WHERE SETTLEMENTDATE BETWEEN ? AND ? $(_intervention_where(schema))
        QUALIFY row_number() OVER (
            PARTITION BY SETTLEMENTDATE, REGIONID ORDER BY archive_month DESC
        ) = 1
        """,
        params,
    )
    subset!(df, :SETTLEMENTDATE => ByRow(x -> start_date <= x < end_date))
    "APCFLAG" in names(df) || (df[!, :APCFLAG] = fill(missing, nrow(df)))
    return df
end
