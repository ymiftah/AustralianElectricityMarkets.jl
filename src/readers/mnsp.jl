"""
    read_mnsp_offers(db, date_range)

Reads the MNSP link offers NEMDE applied in each dispatch interval of `date_range`.

Each interval's offer is the one named by `DISPATCH_MNSPBIDTRK` (dispatch run 1), joined to its
`MNSP_DAYOFFER` price bands and its `MNSP_BIDOFFERPERIOD` availability for that interval's
five-minute period of the trading day. The tables cover trading days from the five-minute
settlement start; earlier days live in `MNSP_PEROFFER`.

# Arguments
- `db`: The database connection.
- `date_range`: Interval-ending timestamps; intervals `t` with `first(date_range) <= t < last(date_range)` are returned.

# Returns
A `DataFrame` with one row per `(INTERVAL_DATETIME, LINKID)`: `PARTICIPANTID`, `MAXAVAIL`,
`FIXEDLOAD` (`missing` when no fixed load), `RAMPUPRATE`, `BANDAVAIL1`-`BANDAVAIL10` and
`PRICEBAND1`-`PRICEBAND10`.

# Example
```julia
db = aem_connect()
offers = read_mnsp_offers(db, DateTime(2026, 6, 15, 12):Minute(5):DateTime(2026, 6, 15, 13))
```
"""
function read_mnsp_offers(db, date_range)
    band_cols = join(("o.PRICEBAND$i" for i in 1:10), ", ") * ", " *
        join(("p.BANDAVAIL$i" for i in 1:10), ", ")
    # Interval t ending at `t` belongs to the trading day starting 04:00 of CAST(t - 5 min - 4 h); its
    # period is the number of five-minute steps since that 04:00.
    df = _query(
        db,
        """
        WITH trk AS (
            SELECT SETTLEMENTDATE AS INTERVAL_DATETIME, LINKID, PARTICIPANTID, OFFERSETTLEMENTDATE,
                   OFFEREFFECTIVEDATE, OFFERVERSIONNO,
                   CAST(SETTLEMENTDATE - INTERVAL 5 MINUTE - INTERVAL 4 HOUR AS DATE) AS TRADINGDATE
            FROM $(read_hive(db, :DISPATCH_MNSPBIDTRK))
            WHERE RUNNO = 1 AND SETTLEMENTDATE >= ? AND SETTLEMENTDATE < ?
        )
        SELECT trk.INTERVAL_DATETIME, trk.LINKID, trk.PARTICIPANTID, p.MAXAVAIL, p.FIXEDLOAD, p.RAMPUPRATE,
               $band_cols
        FROM trk
        INNER JOIN $(read_hive(db, :MNSP_DAYOFFER)) AS o
            ON o.SETTLEMENTDATE = trk.OFFERSETTLEMENTDATE AND o.LINKID = trk.LINKID
           AND o.PARTICIPANTID = trk.PARTICIPANTID AND o.OFFERDATE = trk.OFFEREFFECTIVEDATE
           AND o.VERSIONNO = trk.OFFERVERSIONNO
        INNER JOIN $(read_hive(db, :MNSP_BIDOFFERPERIOD)) AS p
            ON p.TRADINGDATE = trk.TRADINGDATE AND p.LINKID = trk.LINKID
           AND p.OFFERDATETIME = trk.OFFEREFFECTIVEDATE
           AND p.PERIODID = date_diff('minute', CAST(trk.TRADINGDATE AS TIMESTAMP) + INTERVAL 4 HOUR, trk.INTERVAL_DATETIME) / 5
        ORDER BY trk.INTERVAL_DATETIME, trk.LINKID
        """,
        [first(date_range), last(date_range)],
    )
    return df
end


"""
    read_mnsp_links(db, as_of)

Reads the registered MNSP links as of `as_of`: the latest `MNSP_INTERCONNECTOR` version of each
`LINKID` whose `EFFECTIVEDATE` is on or before `as_of`.

The table still carries superseded rows for interconnectors that are no longer MNSPs, so a caller
pairs it with [`read_mnsp_offers`](@ref), which names the links that offer in an interval.

# Arguments
- `db`: The database connection.
- `as_of`: A `Date` or `DateTime`.

# Returns
A `DataFrame` with one row per link: `LINKID`, `INTERCONNECTORID`, `FROMREGION`, `TOREGION`,
`FROM_REGION_TLF`, `TO_REGION_TLF`, `LHSFACTOR` and `MAXCAPACITY`. A link's flow runs from
`FROMREGION` to `TOREGION`.

# Example
```julia
db = aem_connect()
links = read_mnsp_links(db, DateTime(2026, 6, 15))
```
"""
function read_mnsp_links(db, as_of::Union{Date, DateTime})
    return _query(
        db,
        """
        SELECT LINKID, INTERCONNECTORID, FROMREGION, TOREGION, FROM_REGION_TLF, TO_REGION_TLF,
               LHSFACTOR, MAXCAPACITY
        FROM $(read_hive(db, :MNSP_INTERCONNECTOR))
        WHERE EFFECTIVEDATE <= ?
        QUALIFY row_number() OVER (PARTITION BY LINKID ORDER BY EFFECTIVEDATE DESC, VERSIONNO DESC) = 1
        ORDER BY INTERCONNECTORID, LINKID
        """,
        [as_of],
    )
end
