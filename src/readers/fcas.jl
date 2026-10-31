"""
    read_fcas_requirements(db, date_range; intervention = 0)

Reads per-interval, per-region FCAS requirement constraints actually enforced in dispatch,
long-format: one row per `(SETTLEMENTDATE, REGIONID, BIDTYPE::BidType, GENCONID)`.

AEMO stopped populating the `RESERVE` table (and `DISPATCHREGIONSUM`'s `*REQ` columns) in
Dec 2003 - confirmed directly, both URL patterns 404 for every month tried. The modern
mechanism is generic-constraint-based: `DISPATCH_FCAS_REQ` maps each
`(region, service, interval)` to the `GENCONID` of the generic constraint governing it (a
region/service can be governed by more than one constraint at once - e.g. a regulation
market's target also appears on a contingency constraint's LHS - so this is joined, not
aggregated, to one row per governing constraint).

Each row is a linear constraint `LHS CONSTRAINTTYPE REQUIREMENT` (`CONSTRAINTTYPE` is
`<=`/`>=`/`=`), not a standalone MW quantity - `REQUIREMENT` (`DISPATCHCONSTRAINT.RHS`) is
only meaningful together with `LHS` (`DISPATCHCONSTRAINT.LHS`, the FCAS-and-related dispatch
terms NEMDE actually summed) and `CONSTRAINTTYPE`. Two regimes are common in practice:

- **Disarmed**: AEMO switches an inapplicable constraint variant off by offsetting its
  `REQUIREMENT` by a large negative multiple of 10,000 so it can never bind regardless of
  `LHS` - a `REQUIREMENT` far below any plausible FCAS quantity (in the thousands or tens of
  thousands negative) is this, not a literal deficit. `MARGINALVALUE` is always `0.0` for
  these rows.
- **Armed**: `REQUIREMENT` is the real bound. It can still be negative here - the same
  region/service is often governed by more than one constraint variant (e.g. one that nets
  FCAS against an interconnector flow term on `LHS`), and only one variant is armed at a
  time. Compare `LHS` to `REQUIREMENT` under `CONSTRAINTTYPE` to see whether the constraint
  is satisfied or violated; `MARGINALVALUE != 0.0` confirms it is binding.

`MARGINALVALUE` is the constraint's shadow price, and summing it per `(REGIONID, BIDTYPE)`
reproduces the regional FCAS price (see [`read_fcas_prices`](@ref)). `GENCONDATA` is joined
in only for its human-readable `DESCRIPTION`/`CONSTRAINTTYPE` - `GENCONDATA` is a
change-only table (a constraint version appears only in the archive month it was published),
so a `missing` `DESCRIPTION`/`CONSTRAINTTYPE` usually means the defining archive month isn't
in the local cache, not that AEMO never published one.

`intervention` selects the dispatch run: `0` is the normal (non-intervention) run, which is
the right choice for almost all uses.

Throws an `ArgumentError` when neither `DISPATCH_FCAS_REQ` nor `DISPATCH_FCAS_REQ_CONSTRAINT`
is cached.
"""
function read_fcas_requirements(db, date_range; intervention::Integer = 0)
    start_date = first(date_range)
    end_date = last(date_range)
    constraint_table = read_hive(db, :DISPATCHCONSTRAINT)
    gencon_table = read_hive(db, :GENCONDATA)
    constraint_schema = _table_schema(db, constraint_table)
    req_union_sql, params = _fcas_req_union_sql(db, start_date, end_date, intervention)
    append!(params, [start_date, end_date])
    _push_intervention!(params, constraint_schema, intervention)
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
            FROM $constraint_table
            WHERE SETTLEMENTDATE BETWEEN ? AND ? $(_intervention_where(constraint_schema))
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

Like [`read_bids`](@ref), but for an AEMO FCAS `bid_type` (e.g. `BidType.RAISE6SEC`,
`BidType.RAISEREG` — see `FCAS_BID_TYPES`). Reuses `_massage_bids` for the 10-band offer
(same columns as the energy bid path), and additionally reads the AEMO FCAS trapezium
columns from `BIDPEROFFER_D` (`ENABLEMENTMIN/MAX`, `LOWBREAKPOINT`, `HIGHBREAKPOINT`,
`ROCUP`, `ROCDOWN` — already present in that table, just never selected by the
energy-only bid path).

With a vector of `bid_types` the tables are read once for all of them and the result carries
an extra `BIDTYPE` column (`BidType`).
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

Reads per-interval, per-unit FCAS dispatch outcomes from `DISPATCHLOAD`, long-format: one
row per `(SETTLEMENTDATE, DUID, BIDTYPE::BidType, TARGET, ACTUALAVAILABILITY)`, plus the
unit's energy context columns `INITIALMW`, `TOTALCLEARED`, `AVAILABILITY`, `AGCSTATUS`. This
is the cleared counterpart to [`read_fcas_bids`](@ref)'s offered trapezium - comparing
`TARGET`/`ACTUALAVAILABILITY` against the offer's trapezium shows how much of what a unit
offered was actually deliverable at its dispatched energy level (see [`AustralianElectricityMarkets.FCASTrapezium`](@ref)).

`ACTUALAVAILABILITY` is `missing` for the two regulation markets (`RAISEREG`/`LOWERREG`) -
AEMO does not publish a trapezium-adjusted availability for regulation, only the raw offer
availability (`RAISEREGAVAILABILITY`/`LOWERREGAVAILABILITY`).

`intervention` selects the dispatch run: `0` is the normal (non-intervention) run
(`INTERVENTION` is compared via `COALESCE(INTERVENTION, 0)` for partitions predating that
column - see [`read_fcas_requirements`](@ref)).
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


"""
    read_fcas_scaling_inputs(db, date_range; intervention = 0)

Reads per-interval, per-unit AEMO *FCAS Model in NEMDE* §4.1/§4.2/§5 scaling and pre-condition
inputs from `DISPATCHLOAD`: one row per `(SETTLEMENTDATE, DUID)` with `RAISEREGENABLEMENTMIN/MAX`,
`LOWERREGENABLEMENTMIN/MAX` (the telemetered AGC enablement limits, already the more
restrictive of bid and telemetered per AEMO's data model), `RAMPUPRATE`/`RAMPDOWNRATE`
(MW/h, the bid-capped ramp rate that [`read_dispatch_limits`](@ref) also reads for energy ramping),
`RAISEREGAVAILABILITY`/`LOWERREGAVAILABILITY` (the regulation availability, MW), and `AGCSTATUS`
(`1` while the unit is under AGC control, `0` otherwise).

`intervention` selects the dispatch run: `0` is the normal (non-intervention) run
(`INTERVENTION` is compared via `COALESCE(INTERVENTION, 0)` for partitions predating that
column - see [`read_fcas_requirements`](@ref)).

# Arguments
- `db`: an `AEMDB` connection.
- `date_range`: the dispatch intervals to read (half-open: `start <= t < stop`).
- `intervention`: `0` for the pricing run, `1` for the physical run.

# Returns
A `DataFrame` with `SETTLEMENTDATE`, `DUID`, `RAISEREGENABLEMENTMIN`, `RAISEREGENABLEMENTMAX`,
`LOWERREGENABLEMENTMIN`, `LOWERREGENABLEMENTMAX`, `RAMPUPRATE`, `RAMPDOWNRATE`,
`RAISEREGAVAILABILITY`, `LOWERREGAVAILABILITY`, `AGCSTATUS`.
"""
function read_fcas_scaling_inputs(db, date_range; intervention::Integer = 0)
    scaling_cols = (
        "RAISEREGENABLEMENTMIN", "RAISEREGENABLEMENTMAX",
        "LOWERREGENABLEMENTMIN", "LOWERREGENABLEMENTMAX", "RAMPUPRATE", "RAMPDOWNRATE",
        "RAISEREGAVAILABILITY", "LOWERREGAVAILABILITY", "AGCSTATUS",
    )
    return _read_dispatch_table(db, :DISPATCHLOAD, "DUID", date_range; intervention) do schema
        _require_columns(:DISPATCHLOAD, schema, scaling_cols)
        return [_cast_double(c) for c in scaling_cols]
    end
end
