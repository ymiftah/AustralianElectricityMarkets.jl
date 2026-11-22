"""
    read_fcas_requirements(db, date_range; intervention = 0)

Reads the FCAS requirement constraints enforced in dispatch, one row per
`(SETTLEMENTDATE, REGIONID, BIDTYPE::BidType, GENCONID)`, with `REQUIREMENT` and `LHS` from
`DISPATCHCONSTRAINT`, `MARGINALVALUE`, and `DESCRIPTION`/`CONSTRAINTTYPE` from `GENCONDATA`
(`missing` when the defining archive month is not cached).

Each row is the constraint `LHS CONSTRAINTTYPE REQUIREMENT`. A disarmed variant has a
`REQUIREMENT` offset by a large negative multiple of 10,000 and a `MARGINALVALUE` of `0.0`.
Summing `MARGINALVALUE` per `(REGIONID, BIDTYPE)` gives the regional FCAS price
([`read_fcas_prices`](@ref)).

`intervention` is `0` for the pricing run, or `1` for the physical run where the interval has one,
else the pricing run. Throws an `ArgumentError` when neither `DISPATCH_FCAS_REQ` nor
`DISPATCH_FCAS_REQ_CONSTRAINT` is cached.
"""
function read_fcas_requirements(db, date_range; intervention::Integer = 0)
    start_date, end_date = first(date_range), last(date_range)
    requirements = _fcas_requirement_rows(db, start_date, end_date, intervention)
    constraints = read_hive(db, :DISPATCHCONSTRAINT, (start_date, end_date))
    gencon = read_hive(db, :GENCONDATA)
    df = _with_registered(db, requirements, "fcas_requirement_rows") do
        return _query(
            db,
            """
            WITH req AS (
                SELECT * FROM fcas_requirement_rows
                QUALIFY row_number() OVER (
                    PARTITION BY SETTLEMENTDATE, GENCONID, REGIONID, BIDTYPE
                    ORDER BY GENCONEFFECTIVEDATE DESC NULLS LAST
                ) = 1
            ),
            run AS (
                SELECT * FROM $constraints
                WHERE SETTLEMENTDATE >= ? AND SETTLEMENTDATE < ?
                QUALIFY COALESCE(INTERVENTION, 0) = CASE WHEN ? = 0 THEN 0
                    ELSE max(COALESCE(INTERVENTION, 0)) OVER (PARTITION BY SETTLEMENTDATE) END
            ),
            constraint_rhs AS (
                SELECT SETTLEMENTDATE, CONSTRAINTID, RHS, LHS
                FROM run
                QUALIFY row_number() OVER (PARTITION BY SETTLEMENTDATE, CONSTRAINTID ORDER BY archive_month DESC) = 1
            ),
            gencon AS (
                SELECT GENCONID, EFFECTIVEDATE, VERSIONNO, DESCRIPTION, CONSTRAINTTYPE
                FROM $gencon
                QUALIFY row_number() OVER (
                    PARTITION BY GENCONID, EFFECTIVEDATE, VERSIONNO ORDER BY archive_month DESC
                ) = 1
            )
            SELECT
                req.SETTLEMENTDATE, req.REGIONID, req.BIDTYPE, req.GENCONID,
                TRY_CAST(c.RHS AS DOUBLE) AS REQUIREMENT, TRY_CAST(c.LHS AS DOUBLE) AS LHS,
                req.MARGINALVALUE, g.DESCRIPTION, g.CONSTRAINTTYPE
            FROM req
            INNER JOIN constraint_rhs c
                ON c.SETTLEMENTDATE = req.SETTLEMENTDATE AND c.CONSTRAINTID = req.GENCONID
            -- DISPATCH_FCAS_REQ rows join their exact GENCONDATA version; DISPATCH_FCAS_REQ_CONSTRAINT
            -- rows carry none, so they take the latest version effective at the interval.
            LEFT JOIN gencon g
                ON g.GENCONID = req.GENCONID
                   AND (
                       (req.GENCONEFFECTIVEDATE IS NOT NULL
                            AND g.EFFECTIVEDATE = req.GENCONEFFECTIVEDATE
                            AND g.VERSIONNO = req.GENCONVERSIONNO)
                       OR (req.GENCONEFFECTIVEDATE IS NULL AND g.EFFECTIVEDATE <= req.SETTLEMENTDATE)
                   )
            QUALIFY row_number() OVER (
                PARTITION BY req.SETTLEMENTDATE, req.GENCONID, req.REGIONID, req.BIDTYPE
                ORDER BY g.EFFECTIVEDATE DESC NULLS LAST, g.VERSIONNO DESC NULLS LAST
            ) = 1
            ORDER BY req.SETTLEMENTDATE, req.REGIONID, req.BIDTYPE, req.GENCONID
            """,
            [start_date, end_date, intervention],
        )
    end
    return transform!(df, :BIDTYPE => ByRow(BidType) => :BIDTYPE)
end


# The FCAS rows of `DISPATCH_FCAS_REQ` (to 2025-05) and `DISPATCH_FCAS_REQ_CONSTRAINT` (from 2025-06)
# with `start_date <= SETTLEMENTDATE < end_date`, under the old table's column names.
function _fcas_requirement_rows(db, start_date, end_date, intervention::Integer)
    _check_intervention(intervention)
    window = (start_date, end_date)
    fcas_bid_types = _bid_type_list(FCAS_BID_TYPES)
    tables = DataFrame[]
    if _cached_in_range(db, :DISPATCH_FCAS_REQ, window)
        rows = _query(
            db,
            """
            SELECT SETTLEMENTDATE, GENCONID, REGIONID, BIDTYPE,
                   TRY_CAST(MARGINALVALUE AS DOUBLE) AS MARGINALVALUE,
                   CAST(GENCONEFFECTIVEDATE AS TIMESTAMP) AS GENCONEFFECTIVEDATE,
                   CAST(GENCONVERSIONNO AS INTEGER) AS GENCONVERSIONNO
            FROM $(read_hive(db, :DISPATCH_FCAS_REQ, window))
            WHERE SETTLEMENTDATE >= ? AND SETTLEMENTDATE < ? AND BIDTYPE IN ($fcas_bid_types)
            QUALIFY COALESCE(INTERVENTION, 0) = CASE WHEN ? = 0 THEN 0
                ELSE max(COALESCE(INTERVENTION, 0)) OVER (PARTITION BY SETTLEMENTDATE) END
            ORDER BY SETTLEMENTDATE, GENCONID, REGIONID, BIDTYPE
            """,
            [start_date, end_date, intervention],
        )
        push!(tables, rows)
    end
    if _cached_in_range(db, :DISPATCH_FCAS_REQ_CONSTRAINT, window)
        rows = _query(
            db,
            """
            SELECT INTERVAL_DATETIME AS SETTLEMENTDATE, CONSTRAINTID AS GENCONID, REGIONID, BIDTYPE,
                   TRY_CAST(MARGINALVALUE AS DOUBLE) AS MARGINALVALUE,
                   CAST(NULL AS TIMESTAMP) AS GENCONEFFECTIVEDATE,
                   CAST(NULL AS INTEGER) AS GENCONVERSIONNO
            FROM $(read_hive(db, :DISPATCH_FCAS_REQ_CONSTRAINT, window))
            WHERE INTERVAL_DATETIME >= ? AND INTERVAL_DATETIME < ? AND BIDTYPE IN ($fcas_bid_types)
            ORDER BY SETTLEMENTDATE, GENCONID, REGIONID, BIDTYPE
            """,
            [start_date, end_date],
        )
        push!(tables, rows)
    end
    isempty(tables) && throw(
        ArgumentError(
            "Neither DISPATCH_FCAS_REQ nor DISPATCH_FCAS_REQ_CONSTRAINT is cached: run " *
                "`populate(db, :DISPATCH_FCAS_REQ, ...)` or `populate(db, :DISPATCH_FCAS_REQ_CONSTRAINT, ...)` " *
                "first (AEMO switched tables at the 2025-05/2025-06 boundary; which one you need depends on the date range).",
        ),
    )
    return reduce(vcat, tables)
end

"""
    read_fcas_bids(db, date_range, bid_type::BidType; resolution = nothing)
    read_fcas_bids(db, date_range, bid_types::AbstractVector{BidType}; resolution = nothing)

Like [`read_bids`](@ref), for the FCAS markets in `FCAS_BID_TYPES`, adding the trapezium columns
`ENABLEMENTMIN`, `ENABLEMENTMAX`, `LOWBREAKPOINT`, `HIGHBREAKPOINT`, `ROCUP` and `ROCDOWN` from
`BIDPEROFFER_D`. With a vector of `bid_types` the result carries a `BIDTYPE` column (`BidType`).
With a `resolution` above five minutes, each bucket's trapezium is that of its last interval and its
`ROCUP` and `ROCDOWN` are averaged.
"""
function read_fcas_bids(db, date_range, bid_type::BidType; resolution::Union{Nothing, Dates.Period} = nothing)
    return select!(read_fcas_bids(db, date_range, [bid_type]; resolution), Not(:BIDTYPE))
end

function read_fcas_bids(
        db, date_range, bid_types::AbstractVector{BidType}; resolution::Union{Nothing, Dates.Period} = nothing,
    )
    resolution = something(resolution, Minute(5))
    start, stop = DateTime(first(date_range)), DateTime(last(date_range))
    return @chain read_offers(db, (start - (resolution - Minute(5)), stop); markets = bid_types) begin
        _aggregate_offers(resolution, (start, stop))
        select(
            :SETTLEMENTDATE, :DUID, :DIRECTION, :INTERVAL_DATETIME, :PRICEBANDARRAY, :BANDAVAILARRAY,
            :MAXAVAIL, :MINIMUMLOAD, :DAILYENERGYCONSTRAINT, :BIDTYPE,
            :ENABLEMENTMIN, :LOWBREAKPOINT, :HIGHBREAKPOINT, :ENABLEMENTMAX, :ROCUP, :ROCDOWN,
        )
    end
end


# Every FCAS target and availability column of DISPATCHLOAD as an empty relation. A union by name with it
# reads a column as NULL in months AEMO did not publish it (the 1-second markets before October 2023).
const _FCAS_DISPATCH_COLUMNS = "(SELECT " *
    join(("NULL AS $(m)$(c)" for m in string.(FCAS_BID_TYPES) for c in ("", "ACTUALAVAILABILITY")), ", ") *
    " WHERE false)"


"""
    read_fcas_dispatch(db, date_range; intervention = 0)

Reads per-unit FCAS dispatch outcomes from `DISPATCHLOAD`: one row per
`(SETTLEMENTDATE, DUID, BIDTYPE::BidType)` with `TARGET` and `ACTUALAVAILABILITY`, plus
`INITIALMW`, `TOTALCLEARED`, `AVAILABILITY` and `AGCSTATUS`, sorted by `SETTLEMENTDATE`, `DUID` and
`BIDTYPE`.

`intervention` selects the dispatch run: `0` for the pricing run. `1` for the physical run where the
interval has one, else the pricing run.
"""
function read_fcas_dispatch(db, date_range; intervention::Integer = 0)
    _check_intervention(intervention)
    source = read_hive(db, :DISPATCHLOAD, date_range)
    dispatch = _query(
        db,
        """
        WITH run AS (
            SELECT * FROM (SELECT * FROM $source UNION ALL BY NAME SELECT * FROM $_FCAS_DISPATCH_COLUMNS)
            WHERE SETTLEMENTDATE >= ? AND SETTLEMENTDATE < ?
            QUALIFY COALESCE(INTERVENTION, 0) = CASE WHEN ? = 0 THEN 0
                ELSE max(COALESCE(INTERVENTION, 0)) OVER (PARTITION BY SETTLEMENTDATE) END
        ),
        wide AS (
            SELECT * FROM run
            QUALIFY row_number() OVER (PARTITION BY SETTLEMENTDATE, DUID ORDER BY archive_month DESC) = 1
        )
        SELECT SETTLEMENTDATE, DUID,
               TRY_CAST(INITIALMW AS DOUBLE) AS INITIALMW,
               TRY_CAST(TOTALCLEARED AS DOUBLE) AS TOTALCLEARED,
               TRY_CAST(AVAILABILITY AS DOUBLE) AS AVAILABILITY,
               TRY_CAST(AGCSTATUS AS INTEGER) AS AGCSTATUS,
               TRY_CAST(TARGET AS DOUBLE) AS TARGET,
               TRY_CAST(ACTUALAVAILABILITY AS DOUBLE) AS ACTUALAVAILABILITY,
               BIDTYPE
        FROM wide
        UNPIVOT INCLUDE NULLS (
            (TARGET, ACTUALAVAILABILITY) FOR BIDTYPE IN (
                (RAISE1SEC, RAISE1SECACTUALAVAILABILITY) AS RAISE1SEC,
                (LOWER1SEC, LOWER1SECACTUALAVAILABILITY) AS LOWER1SEC,
                (RAISE6SEC, RAISE6SECACTUALAVAILABILITY) AS RAISE6SEC,
                (LOWER6SEC, LOWER6SECACTUALAVAILABILITY) AS LOWER6SEC,
                (RAISE60SEC, RAISE60SECACTUALAVAILABILITY) AS RAISE60SEC,
                (LOWER60SEC, LOWER60SECACTUALAVAILABILITY) AS LOWER60SEC,
                (RAISE5MIN, RAISE5MINACTUALAVAILABILITY) AS RAISE5MIN,
                (LOWER5MIN, LOWER5MINACTUALAVAILABILITY) AS LOWER5MIN,
                (RAISEREG, RAISEREGACTUALAVAILABILITY) AS RAISEREG,
                (LOWERREG, LOWERREGACTUALAVAILABILITY) AS LOWERREG
            )
        )
        ORDER BY SETTLEMENTDATE, DUID, BIDTYPE
        """,
        [first(date_range), last(date_range), intervention],
    )
    return transform!(dispatch, :BIDTYPE => ByRow(BidType) => :BIDTYPE)
end
