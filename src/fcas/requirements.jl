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
    sd = Date(start_date) - Day(1)
    ed = Date(end_date) + Day(1)
    constraint_table = read_hive(db, :DISPATCHCONSTRAINT)
    gencon_table = read_hive(db, :GENCONDATA)
    constraint_schema = names(_query(db, "SELECT * FROM $constraint_table LIMIT 0"))
    req_union_sql, req_param_spec = _fcas_req_union_sql(db, intervention)
    if isnothing(req_union_sql)
        throw(
            ArgumentError(
                "Neither DISPATCH_FCAS_REQ nor DISPATCH_FCAS_REQ_CONSTRAINT is cached — run " *
                    "`populate(db, :DISPATCH_FCAS_REQ, ...)` or `populate(db, :DISPATCH_FCAS_REQ_CONSTRAINT, ...)` " *
                    "first (AEMO switched tables at the 2025-05/2025-06 boundary; which one you need depends on the date range).",
            ),
        )
    end
    params = _expand_fcas_req_params(req_param_spec, sd, ed)
    append!(params, [sd, ed])
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
    # Restrict to the 8 in-scope FCAS markets (see FCAS_BID_TYPES) - DISPATCH_FCAS_REQ also
    # carries the deferred RAISE1SEC/LOWER1SEC 1-second markets.
    subset!(df, :BIDTYPE => ByRow(in(string.(FCAS_BID_TYPES))))
    transform!(df, :BIDTYPE => ByRow(BidType) => :BIDTYPE)
    return df
end
