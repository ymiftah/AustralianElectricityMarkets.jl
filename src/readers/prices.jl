"""
    read_prices(db, date_range; intervention = 0)

Reads per-interval, per-region **energy** spot prices from `DISPATCHPRICE`: one row per
`(SETTLEMENTDATE, REGIONID)` with `RRP`, `ROP`, `APCFLAG`. `RRP` is the settlement price and `ROP`
the price before scaling, capping or VoLL override; they differ exactly when `APCFLAG != 0` (an
administered price cap event). See [`read_fcas_prices`](@ref) for the FCAS markets.

# Arguments
- `db`: an `AEMDB` connection.
- `date_range`: the dispatch intervals to read (half-open: `start <= t < stop`).
- `intervention`: `0` for the pricing run. `1` for the physical run where the interval has one, else the pricing run.

# Returns
A `DataFrame` with `SETTLEMENTDATE`, `REGIONID`, `RRP`, `ROP` and `APCFLAG`, sorted by
`SETTLEMENTDATE` and `REGIONID`.
"""
function read_prices(db, date_range; intervention::Integer = 0)
    _check_intervention(intervention)
    source = read_hive(db, :DISPATCHPRICE, date_range)
    return _query(
        db,
        """
        WITH run AS (
            SELECT * FROM $source
            WHERE SETTLEMENTDATE >= ? AND SETTLEMENTDATE < ?
            QUALIFY COALESCE(INTERVENTION, 0) = CASE WHEN ? = 0 THEN 0
                ELSE max(COALESCE(INTERVENTION, 0)) OVER (PARTITION BY SETTLEMENTDATE) END
        )
        SELECT SETTLEMENTDATE, REGIONID,
               TRY_CAST(RRP AS DOUBLE) AS RRP,
               TRY_CAST(ROP AS DOUBLE) AS ROP,
               TRY_CAST(APCFLAG AS INTEGER) AS APCFLAG
        FROM run
        QUALIFY row_number() OVER (PARTITION BY SETTLEMENTDATE, REGIONID ORDER BY archive_month DESC) = 1
        ORDER BY SETTLEMENTDATE, REGIONID
        """,
        [first(date_range), last(date_range), intervention],
    )
end


"""
    read_fcas_prices(db, date_range; intervention = 0)

Reads per-interval, per-region FCAS clearing prices from `DISPATCHPRICE`, long-format: one row per
`(SETTLEMENTDATE, REGIONID, BIDTYPE::BidType)` with `RRP`, `ROP`, `APCFLAG`. Summing
[`read_fcas_requirements`](@ref)'s `MARGINALVALUE` per `(REGIONID, BIDTYPE)` reproduces `ROP` for
that interval (not `RRP`, which may additionally be capped).

# Arguments
- `db`: an `AEMDB` connection.
- `date_range`: the dispatch intervals to read (half-open: `start <= t < stop`).
- `intervention`: `0` for the pricing run. `1` for the physical run where the interval has one, else the pricing run.

# Returns
A `DataFrame` with `SETTLEMENTDATE`, `REGIONID`, `RRP`, `ROP`, `APCFLAG` and `BIDTYPE`, one row per
FCAS market in `FCAS_BID_TYPES`, sorted by `SETTLEMENTDATE`, `REGIONID` and `BIDTYPE`.
"""
function read_fcas_prices(db, date_range; intervention::Integer = 0)
    _check_intervention(intervention)
    source = read_hive(db, :DISPATCHPRICE, date_range)
    prices = _query(
        db,
        """
        WITH run AS (
            SELECT * FROM $source
            WHERE SETTLEMENTDATE >= ? AND SETTLEMENTDATE < ?
            QUALIFY COALESCE(INTERVENTION, 0) = CASE WHEN ? = 0 THEN 0
                ELSE max(COALESCE(INTERVENTION, 0)) OVER (PARTITION BY SETTLEMENTDATE) END
        ),
        wide AS (
            SELECT * EXCLUDE (RRP, ROP, APCFLAG) FROM run
            QUALIFY row_number() OVER (PARTITION BY SETTLEMENTDATE, REGIONID ORDER BY archive_month DESC) = 1
        )
        SELECT SETTLEMENTDATE, REGIONID,
               TRY_CAST(RRP AS DOUBLE) AS RRP,
               TRY_CAST(ROP AS DOUBLE) AS ROP,
               TRY_CAST(APCFLAG AS INTEGER) AS APCFLAG,
               BIDTYPE
        FROM wide
        UNPIVOT INCLUDE NULLS (
            (RRP, ROP, APCFLAG) FOR BIDTYPE IN (
                (RAISE1SECRRP, RAISE1SECROP, RAISE1SECAPCFLAG) AS RAISE1SEC,
                (LOWER1SECRRP, LOWER1SECROP, LOWER1SECAPCFLAG) AS LOWER1SEC,
                (RAISE6SECRRP, RAISE6SECROP, RAISE6SECAPCFLAG) AS RAISE6SEC,
                (LOWER6SECRRP, LOWER6SECROP, LOWER6SECAPCFLAG) AS LOWER6SEC,
                (RAISE60SECRRP, RAISE60SECROP, RAISE60SECAPCFLAG) AS RAISE60SEC,
                (LOWER60SECRRP, LOWER60SECROP, LOWER60SECAPCFLAG) AS LOWER60SEC,
                (RAISE5MINRRP, RAISE5MINROP, RAISE5MINAPCFLAG) AS RAISE5MIN,
                (LOWER5MINRRP, LOWER5MINROP, LOWER5MINAPCFLAG) AS LOWER5MIN,
                (RAISEREGRRP, RAISEREGROP, RAISEREGAPCFLAG) AS RAISEREG,
                (LOWERREGRRP, LOWERREGROP, LOWERREGAPCFLAG) AS LOWERREG
            )
        )
        ORDER BY SETTLEMENTDATE, REGIONID, BIDTYPE
        """,
        [first(date_range), last(date_range), intervention],
    )
    return transform!(prices, :BIDTYPE => ByRow(BidType) => :BIDTYPE)
end
