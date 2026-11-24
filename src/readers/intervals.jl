"""
    read_published_interval(db, settlement_date; intervention = 0)
    read_published_interval(db, steps::StepRange{DateTime}; intervention = 0)

Reads AEMO's published outcome for one dispatch interval, or for every interval of `steps` in one
query per table.

# Arguments
- `db`: an `AEMDB` connection.
- `settlement_date`: the `SETTLEMENTDATE` of the interval (`DateTime`).
- `steps`: the `SETTLEMENTDATE`s of consecutive intervals, stepping by 5 minutes.
- `intervention`: `0` for the pricing run. `1` for the physical run where the interval has one, else
  the pricing run. Dispatch and interconnector flows follow this run; prices always come from the
  pricing run (run 0), since AEMO sets prices there.

# Returns
A `NamedTuple` of `DataFrame`s: `dispatch` (`DUID`, `TOTALCLEARED`), `interconnectors`
(`INTERCONNECTORID`, `MWFLOW`, `MWLOSSES`), `prices` (`REGIONID`, `RRP`, `ROP`) and `fcas_prices`
(`SETTLEMENTDATE`, `REGIONID`, `BIDTYPE`, `RRP`, `ROP`). For `steps`, every table has a leading
`SETTLEMENTDATE` column, and the rows at each interval are those of the single-interval method.
"""
function read_published_interval(db, settlement_date::DateTime; intervention::Integer = 0)
    published = read_published_interval(db, settlement_date:Minute(5):settlement_date; intervention)
    return (;
        dispatch = select(published.dispatch, Not(:SETTLEMENTDATE)),
        interconnectors = select(published.interconnectors, Not(:SETTLEMENTDATE)),
        prices = select(published.prices, Not(:SETTLEMENTDATE)),
        fcas_prices = published.fcas_prices,
    )
end

function read_published_interval(db, steps::StepRange{DateTime}; intervention::Integer = 0)
    _check_intervention(intervention)
    interval = (first(steps), last(steps) + Minute(5))
    dispatch = _query(
        db,
        """
        WITH run AS (
            SELECT * FROM $(read_hive(db, :DISPATCHLOAD, interval))
            WHERE SETTLEMENTDATE >= ? AND SETTLEMENTDATE < ?
            QUALIFY COALESCE(INTERVENTION, 0) = CASE WHEN ? = 0 THEN 0
                ELSE max(COALESCE(INTERVENTION, 0)) OVER (PARTITION BY SETTLEMENTDATE) END
        )
        SELECT SETTLEMENTDATE, DUID, TRY_CAST(TOTALCLEARED AS DOUBLE) AS TOTALCLEARED
        FROM run
        QUALIFY row_number() OVER (PARTITION BY SETTLEMENTDATE, DUID ORDER BY archive_month DESC) = 1
        ORDER BY SETTLEMENTDATE, DUID
        """,
        [interval..., intervention],
    )
    interconnectors = _query(
        db,
        """
        WITH run AS (
            SELECT * FROM $(read_hive(db, :DISPATCHINTERCONNECTORRES, interval))
            WHERE SETTLEMENTDATE >= ? AND SETTLEMENTDATE < ?
            QUALIFY COALESCE(INTERVENTION, 0) = CASE WHEN ? = 0 THEN 0
                ELSE max(COALESCE(INTERVENTION, 0)) OVER (PARTITION BY SETTLEMENTDATE) END
        )
        SELECT SETTLEMENTDATE, INTERCONNECTORID,
               TRY_CAST(MWFLOW AS DOUBLE) AS MWFLOW,
               TRY_CAST(MWLOSSES AS DOUBLE) AS MWLOSSES
        FROM run
        QUALIFY row_number() OVER (PARTITION BY SETTLEMENTDATE, INTERCONNECTORID ORDER BY archive_month DESC) = 1
        ORDER BY SETTLEMENTDATE, INTERCONNECTORID
        """,
        [interval..., intervention],
    )
    # Prices stay on the pricing run (run 0) whatever the intervention run.
    prices = select(read_prices(db, interval), :SETTLEMENTDATE, :REGIONID, :RRP, :ROP)
    fcas_prices = select(read_fcas_prices(db, interval), :SETTLEMENTDATE, :REGIONID, :BIDTYPE, :RRP, :ROP)
    return (; dispatch, interconnectors, prices, fcas_prices)
end
