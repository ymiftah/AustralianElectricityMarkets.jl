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
    start_date = first(date_range)
    end_date = last(date_range)
    constraint_table = read_hive(db, :DISPATCHCONSTRAINT, (start_date, end_date))
    gencon_table = read_hive(db, :GENCONDATA)
    constraint_schema = _table_schema(db, constraint_table)
    req_union_sql, params = _fcas_req_union_sql(db, start_date, end_date, intervention)
    constraint_rows, constraint_params = _run_rows(
        constraint_table, constraint_schema, intervention, "SETTLEMENTDATE",
        "SETTLEMENTDATE BETWEEN ? AND ?", [start_date, end_date],
    )
    append!(params, constraint_params)
    df = _query(
        db,
        """
        WITH req AS (
            SELECT *
            FROM ($req_union_sql)
            QUALIFY row_number() OVER (
                PARTITION BY SETTLEMENTDATE, GENCONID, REGIONID, BIDTYPE
                ORDER BY GENCONEFFECTIVEDATE DESC NULLS LAST
            ) = 1
        ),
        constraint_rhs AS (
            SELECT SETTLEMENTDATE, CONSTRAINTID, RHS, LHS
            FROM $constraint_rows
            QUALIFY row_number() OVER (
                PARTITION BY SETTLEMENTDATE, CONSTRAINTID
                ORDER BY archive_month DESC
            ) = 1
        ),
        gencon AS (
            SELECT GENCONID, EFFECTIVEDATE, VERSIONNO, DESCRIPTION, CONSTRAINTTYPE
            FROM $gencon_table
            QUALIFY row_number() OVER (
                PARTITION BY GENCONID, EFFECTIVEDATE, VERSIONNO ORDER BY archive_month DESC
            ) = 1
        )
        SELECT
            req.SETTLEMENTDATE, req.REGIONID, req.BIDTYPE, req.GENCONID,
            TRY_CAST(c.RHS AS DOUBLE) AS REQUIREMENT, TRY_CAST(c.LHS AS DOUBLE) AS LHS,
            TRY_CAST(req.MARGINALVALUE AS DOUBLE) AS MARGINALVALUE,
            g.DESCRIPTION, g.CONSTRAINTTYPE
        FROM req
        INNER JOIN constraint_rhs c
            ON c.SETTLEMENTDATE = req.SETTLEMENTDATE AND c.CONSTRAINTID = req.GENCONID
        -- Exact-version join on the old table's GENCONEFFECTIVEDATE/GENCONVERSIONNO pair;
        -- DISPATCH_FCAS_REQ_CONSTRAINT dropped both, so post-2025-05 rows fall back to the
        -- latest version effective at the interval. DESCRIPTION/CONSTRAINTTYPE are
        -- cosmetic enrichment, so a looser match is acceptable here - it is NOT acceptable
        -- for LHS term joins, which stay exact-equality (see read_constraint_terms).
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
        ORDER BY req.SETTLEMENTDATE, req.REGIONID, req.BIDTYPE
        """,
        params,
    )
    subset!(df, :SETTLEMENTDATE => ByRow(x -> start_date <= x < end_date))
    # Keep the FCAS markets (see FCAS_BID_TYPES), dropping any other BIDTYPE the table carries.
    subset!(df, :BIDTYPE => ByRow(in(string.(FCAS_BID_TYPES))))
    transform!(df, :BIDTYPE => ByRow(BidType) => :BIDTYPE)
    return df
end

"""
    read_fcas_bids(db, date_range, bid_type::BidType; resolution = nothing)
    read_fcas_bids(db, date_range, bid_types::AbstractVector{BidType}; resolution = nothing)

Like [`read_bids`](@ref), for the FCAS markets in `FCAS_BID_TYPES`, adding the trapezium columns
`ENABLEMENTMIN`, `ENABLEMENTMAX`, `LOWBREAKPOINT`, `HIGHBREAKPOINT`, `ROCUP` and `ROCDOWN` from
`BIDPEROFFER_D`. With a vector of `bid_types` the result carries a `BIDTYPE` column (`BidType`).
With a `resolution` above five minutes, each bucket's trapezium is that of its last interval.
"""
function read_fcas_bids(db, date_range, bid_type::BidType; resolution::Union{Nothing, Dates.Period} = nothing)
    return select!(read_fcas_bids(db, date_range, [bid_type]; resolution), Not(:BIDTYPE))
end

function read_fcas_bids(
        db, date_range, bid_types::AbstractVector{BidType}; resolution::Union{Nothing, Dates.Period} = nothing,
    )
    start_date = first(date_range)
    end_date = last(date_range)
    if isnothing(resolution)
        bids = _massage_bids(
            db, start_date, end_date; bid_types, keep_bid_type = true,
            period_columns = _FCAS_TRAPEZIUM_COLUMNS,
        )
        transform!(bids, :BIDTYPE => ByRow(BidType) => :BIDTYPE)
        return bids
    end
    bids = _massage_bids(db, start_date, end_date; bid_types, keep_bid_type = true, resolution)
    trapezium = _read_period_offers(db, bid_types, start_date, end_date, nothing; columns = _FCAS_TRAPEZIUM_COLUMNS)
    joined = innerjoin(
        bids, trapezium; on = [:SETTLEMENTDATE, :INTERVAL_DATETIME, :DUID, :DIRECTION, :BIDTYPE],
    )
    transform!(joined, :BIDTYPE => ByRow(BidType) => :BIDTYPE)
    return joined
end


# The FCAS trapezium columns of `BIDPEROFFER_D`; `MAXAVAIL` comes with the offer bands instead.
const _FCAS_TRAPEZIUM_COLUMNS = ["ENABLEMENTMIN", "LOWBREAKPOINT", "HIGHBREAKPOINT", "ENABLEMENTMAX", "ROCUP", "ROCDOWN"]


"""
    read_fcas_dispatch(db, date_range; intervention = 0)

Reads per-unit FCAS dispatch outcomes from `DISPATCHLOAD`: one row per
`(SETTLEMENTDATE, DUID, BIDTYPE::BidType)` with `TARGET` and `ACTUALAVAILABILITY`, plus
`INITIALMW`, `TOTALCLEARED`, `AVAILABILITY` and `AGCSTATUS`. `ACTUALAVAILABILITY` is `missing` for
`RAISEREG` and `LOWERREG`.

`intervention` selects the dispatch run: `0` for the pricing run. `1` for the physical run where the
interval has one, else the pricing run. A table without an `INTERVENTION` column is read unfiltered.
"""
function read_fcas_dispatch(db, date_range; intervention::Integer = 0)
    df = _read_dispatch_table(db, :DISPATCHLOAD, "DUID", date_range; intervention) do schema
        cols = [
            _cast_double("INITIALMW"), _cast_double("TOTALCLEARED"), _cast_double("AVAILABILITY"),
            "TRY_CAST(AGCSTATUS AS INTEGER) AS AGCSTATUS",
        ]
        for bid_type in string.(FCAS_BID_TYPES)
            bid_type in schema || continue
            push!(cols, _cast_double(bid_type))
            avail_col = "$(bid_type)ACTUALAVAILABILITY"
            avail_col in schema && push!(cols, _cast_double(avail_col))
        end
        return cols
    end

    # TODO use DataFrames.jl methods: this should be a groupby combine, or a stack / unstack
    long = DataFrame()
    for bid_type in FCAS_BID_TYPES
        bid_type_str = string(bid_type)
        target_col = bid_type_str
        avail_col = "$(bid_type_str)ACTUALAVAILABILITY"
        target_col in names(df) || continue
        block = select(
            df,
            :SETTLEMENTDATE, :DUID, :INITIALMW, :TOTALCLEARED, :AVAILABILITY, :AGCSTATUS,
            target_col => :TARGET,
        )
        block[!, :ACTUALAVAILABILITY] = avail_col in names(df) ? df[!, avail_col] : fill(missing, nrow(block))
        block[!, :BIDTYPE] = fill(bid_type, nrow(block))
        append!(long, block; promote = true)
    end
    return long
end
