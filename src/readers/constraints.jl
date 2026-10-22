"""
    read_invoked_constraints(db, date_range; intervention = 0)

Reads `DISPATCHCONSTRAINT` over `date_range`: one row per `(SETTLEMENTDATE, GENCONID)` with
`RHS`, `LHS`, `MARGINALVALUE`, and the exact constraint version NEMDE used that interval
(`GENCONID_EFFECTIVEDATE`/`GENCONID_VERSIONNO`). Membership in this table is the definition
of "NEMDE actually enforced this constraint" — see [`add_nem_constraints!`](@ref AustralianElectricityMarkets.add_nem_constraints!).
"""
function read_invoked_constraints(db, date_range; intervention::Integer = 0)
    columns = [
        _cast_double("RHS"), _cast_double("LHS"), _cast_double("MARGINALVALUE"),
        "GENCONID_EFFECTIVEDATE", "GENCONID_VERSIONNO",
    ]
    df = _read_dispatch_table(columns, db, :DISPATCHCONSTRAINT, "CONSTRAINTID", date_range; intervention, order = true)
    return rename!(df, :CONSTRAINTID => :GENCONID)
end


# Upper bound for pruning the versioned reference tables. A version effective *after* the
# newest one NEMDE invoked can never satisfy the exact-equality join, and because each
# archive month only holds the versions that became effective in it, DuckDB turns this into
# partition pruning. Bounding below is not valid: a constraint invoked today can be on a
# version effective years earlier, whose rows live only in that old month's partition.
function _effective_date_bound(wanted)
    bound = maximum(skipmissing(wanted.GENCONID_EFFECTIVEDATE); init = typemin(DateTime))
    return "CAST('$bound' AS TIMESTAMP)"
end


# An empty `gencon_versions` means `DISPATCHCONSTRAINT` is not cached over the range.
function _require_invoked(gencon_versions)
    DataFrames.isempty(gencon_versions) && throw(
        ArgumentError(
            "gencon_versions is empty: no constraint was invoked over the requested range. " *
                "That means DISPATCHCONSTRAINT is not cached for it: run `populate(db, :DISPATCHCONSTRAINT, ...)` first.",
        ),
    )
    return
end


"""
    read_constraint_definitions(db, gencon_versions)

`gencon_versions` has distinct `(GENCONID, GENCONID_EFFECTIVEDATE, GENCONID_VERSIONNO)`
rows (see [`read_invoked_constraints`](@ref)). Joins each to its exact `GENCONDATA` version:
`CONSTRAINTTYPE`, `GENERICCONSTRAINTWEIGHT`, `CONSTRAINTVALUE`, plus
`DESCRIPTION`/`LIMITTYPE`/`SOURCE`. A `GENCONID` absent from the result has no `GENCONDATA`
row for that exact version — usually because the defining archive month isn't cached (see
[`read_fcas_requirements`](@ref)) — callers must treat that as "no definition available".
Throws an `ArgumentError` on an empty `gencon_versions`: nothing was invoked over the range,
which means `DISPATCHCONSTRAINT` was never cached for it.
"""
function read_constraint_definitions(db, gencon_versions)
    _require_invoked(gencon_versions)
    wanted = unique(select(gencon_versions, :GENCONID, :GENCONID_EFFECTIVEDATE, :GENCONID_VERSIONNO))
    table = read_hive(db, :GENCONDATA)
    return _with_registered(db, wanted, "wanted_gencon_versions") do
        return _query(
            db,
            """
            WITH gencon AS (
                SELECT *
                FROM $table
                WHERE EFFECTIVEDATE <= $(_effective_date_bound(wanted))
                QUALIFY row_number() OVER (
                    PARTITION BY GENCONID, EFFECTIVEDATE, VERSIONNO ORDER BY archive_month DESC
                ) = 1
            )
            SELECT
                g.GENCONID, g.EFFECTIVEDATE, g.VERSIONNO, g.CONSTRAINTTYPE,
                TRY_CAST(g.GENERICCONSTRAINTWEIGHT AS DOUBLE) AS GENERICCONSTRAINTWEIGHT,
                TRY_CAST(g.CONSTRAINTVALUE AS DOUBLE) AS CONSTRAINTVALUE,
                g.DESCRIPTION, g.LIMITTYPE, g.SOURCE
            FROM wanted_gencon_versions w
            INNER JOIN gencon g
                ON g.GENCONID = w.GENCONID AND g.EFFECTIVEDATE = w.GENCONID_EFFECTIVEDATE
                   AND g.VERSIONNO = w.GENCONID_VERSIONNO
            """,
        )
    end
end


"""
    read_constraint_terms(db, gencon_versions, date_range)

Reads the three `SPD*` tables for the exact versions in `gencon_versions`.

# Returns
Long-format `DataFrame`, one row per
`(GENCONID, EFFECTIVEDATE, VERSIONNO, TERM_KIND, KEY, BIDTYPE, FACTOR)`. Throws
`ArgumentError` on an empty `gencon_versions`.
"""
function read_constraint_terms(db, gencon_versions, date_range)
    _require_invoked(gencon_versions)
    start_date = first(date_range)
    end_date = last(date_range)
    wanted = unique(select(gencon_versions, :GENCONID, :GENCONID_EFFECTIVEDATE, :GENCONID_VERSIONNO))
    eff_bound = _effective_date_bound(wanted)

    cp_table = read_hive(db, :SPDCONNECTIONPOINTCONSTRAINT)
    region_table = read_hive(db, :SPDREGIONCONSTRAINT)
    ic_table = read_hive(db, :SPDINTERCONNECTORCONSTRAINT)
    dudetailsummary_table = read_hive(db, :DUDETAILSUMMARY)

    return _with_registered(db, wanted, "wanted_gencon_versions") do
        return _query(
            db,
            """
            WITH cp AS (
                SELECT * FROM $cp_table
                WHERE EFFECTIVEDATE <= $eff_bound
                QUALIFY row_number() OVER (
                    PARTITION BY CONNECTIONPOINTID, EFFECTIVEDATE, VERSIONNO, GENCONID, BIDTYPE
                    ORDER BY archive_month DESC
                ) = 1
            ),
            cp_matched AS (
                SELECT cp.GENCONID, cp.EFFECTIVEDATE, cp.VERSIONNO, cp.CONNECTIONPOINTID, cp.BIDTYPE,
                       TRY_CAST(cp.FACTOR AS DOUBLE) AS FACTOR
                FROM cp
                INNER JOIN wanted_gencon_versions w
                    ON w.GENCONID = cp.GENCONID AND w.GENCONID_EFFECTIVEDATE = cp.EFFECTIVEDATE
                       AND w.GENCONID_VERSIONNO = cp.VERSIONNO
            ),
            duids AS (
                SELECT DISTINCT CONNECTIONPOINTID, DUID
                FROM $dudetailsummary_table
                WHERE START_DATE <= ? AND (END_DATE IS NULL OR END_DATE >= ?)
            )
            SELECT cp_matched.GENCONID, cp_matched.EFFECTIVEDATE, cp_matched.VERSIONNO,
                   'UNIT' AS TERM_KIND, duids.DUID AS KEY, cp_matched.BIDTYPE, cp_matched.FACTOR
            FROM cp_matched INNER JOIN duids ON duids.CONNECTIONPOINTID = cp_matched.CONNECTIONPOINTID

            UNION ALL

            SELECT r.GENCONID, r.EFFECTIVEDATE, r.VERSIONNO, 'REGION' AS TERM_KIND, r.REGIONID AS KEY,
                   r.BIDTYPE, TRY_CAST(r.FACTOR AS DOUBLE) AS FACTOR
            FROM (
                SELECT * FROM $region_table
                WHERE EFFECTIVEDATE <= $eff_bound
                QUALIFY row_number() OVER (
                    PARTITION BY REGIONID, EFFECTIVEDATE, VERSIONNO, GENCONID, BIDTYPE ORDER BY archive_month DESC
                ) = 1
            ) r
            INNER JOIN wanted_gencon_versions w
                ON w.GENCONID = r.GENCONID AND w.GENCONID_EFFECTIVEDATE = r.EFFECTIVEDATE AND w.GENCONID_VERSIONNO = r.VERSIONNO

            UNION ALL

            SELECT i.GENCONID, i.EFFECTIVEDATE, i.VERSIONNO, 'INTERCONNECTOR' AS TERM_KIND,
                   i.INTERCONNECTORID AS KEY, CAST(NULL AS VARCHAR) AS BIDTYPE, TRY_CAST(i.FACTOR AS DOUBLE) AS FACTOR
            FROM (
                SELECT * FROM $ic_table
                WHERE EFFECTIVEDATE <= $eff_bound
                QUALIFY row_number() OVER (
                    PARTITION BY INTERCONNECTORID, EFFECTIVEDATE, VERSIONNO, GENCONID ORDER BY archive_month DESC
                ) = 1
            ) i
            INNER JOIN wanted_gencon_versions w
                ON w.GENCONID = i.GENCONID AND w.GENCONID_EFFECTIVEDATE = i.EFFECTIVEDATE AND w.GENCONID_VERSIONNO = i.VERSIONNO
            """,
            [end_date, start_date],
        )
    end
end


"""
    _fcas_req_union_sql(db, intervention) -> (sql_fragment, params_for_fragment)

A `SELECT`-able fragment presenting AEMO's two generations of the dispatch FCAS requirement
table under the **old** column names — `SETTLEMENTDATE`, `GENCONID`, `REGIONID`, `BIDTYPE`,
`MARGINALVALUE`, `GENCONEFFECTIVEDATE`, `GENCONVERSIONNO`.

`DISPATCH_FCAS_REQ` was last published for the 2025-05 archive month; from 2025-06 AEMO
publishes `DISPATCH_FCAS_REQ_CONSTRAINT` instead, which renames `GENCONID` to
`CONSTRAINTID` and `SETTLEMENTDATE` to `INTERVAL_DATETIME`. Callers get one continuous
series across the cut rather than silently empty results for recent dates.

Two columns have no successor and come back `NULL` for post-cut rows:
`GENCONEFFECTIVEDATE`/`GENCONVERSIONNO`, so a constraint's `GENCONDATA` version can only be
resolved by exact equality on the old side (see [`read_fcas_requirements`](@ref) for the
fallback). The new table also drops `INTERVENTION` entirely — `intervention` therefore
filters the old side only, and post-cut rows are whatever runs AEMO published.

Either table may be absent from the cache; a missing one contributes no rows, so a cache covering
only one side of the cut still works. Throws an `ArgumentError` when neither is cached.
"""
function _fcas_req_union_sql(db, intervention::Integer)
    branches = String[]
    params = Any[]

    if _table_is_cached(db, :DISPATCH_FCAS_REQ)
        table = read_hive(db, :DISPATCH_FCAS_REQ)
        schema = _table_schema(db, table)
        push!(
            branches,
            """
            SELECT SETTLEMENTDATE, GENCONID, REGIONID, BIDTYPE,
                   TRY_CAST(MARGINALVALUE AS DOUBLE) AS MARGINALVALUE,
                   GENCONEFFECTIVEDATE, GENCONVERSIONNO
            FROM $table
            WHERE SETTLEMENTDATE BETWEEN ? AND ? $(_intervention_where(schema))
            """,
        )
        push!(params, :dates)
        _intervention_where(schema) == "" || push!(params, intervention)
    end

    if _table_is_cached(db, :DISPATCH_FCAS_REQ_CONSTRAINT)
        table = read_hive(db, :DISPATCH_FCAS_REQ_CONSTRAINT)
        push!(
            branches,
            """
            SELECT INTERVAL_DATETIME AS SETTLEMENTDATE, CONSTRAINTID AS GENCONID,
                   REGIONID, BIDTYPE,
                   TRY_CAST(MARGINALVALUE AS DOUBLE) AS MARGINALVALUE,
                   CAST(NULL AS DATE) AS GENCONEFFECTIVEDATE,
                   CAST(NULL AS INTEGER) AS GENCONVERSIONNO
            FROM $table
            WHERE INTERVAL_DATETIME BETWEEN ? AND ?
            """,
        )
        push!(params, :dates)
    end

    isempty(branches) && throw(
        ArgumentError(
            "Neither DISPATCH_FCAS_REQ nor DISPATCH_FCAS_REQ_CONSTRAINT is cached: run " *
                "`populate(db, :DISPATCH_FCAS_REQ, ...)` or `populate(db, :DISPATCH_FCAS_REQ_CONSTRAINT, ...)` " *
                "first (AEMO switched tables at the 2025-05/2025-06 boundary; which one you need depends on the date range).",
        ),
    )
    return join(branches, "\nUNION ALL\n"), params
end


"""
    _expand_fcas_req_params(param_spec, start_date, end_date) -> Vector{Any}

Substitutes each `:dates` placeholder from [`_fcas_req_union_sql`](@ref) with the
`start_date`/`end_date` pair, keeping positional `?` binding aligned across a variable number of `UNION ALL`
branches.
"""
function _expand_fcas_req_params(param_spec, start_date, end_date)
    out = Any[]
    for p in param_spec
        if p === :dates
            push!(out, start_date, end_date)
        else
            push!(out, p)
        end
    end
    return out
end


"""
    read_constraint_fcas_requirements(db, date_range; intervention = 0)

Reads the dispatch FCAS requirement table's `GENCONID -> (REGIONID, BIDTYPE)` mapping over
`date_range`. Keyed by bare `GENCONID`.

# Returns
Long-format `DataFrame`. Throws `ArgumentError` when neither `DISPATCH_FCAS_REQ` nor
`DISPATCH_FCAS_REQ_CONSTRAINT` is cached.
"""
function read_constraint_fcas_requirements(db, date_range; intervention::Integer = 0)
    start_date = first(date_range)
    end_date = last(date_range)
    union_sql, param_spec = _fcas_req_union_sql(db, intervention)
    df = _query(
        db,
        """
        SELECT DISTINCT SETTLEMENTDATE, GENCONID, REGIONID, BIDTYPE
        FROM ($union_sql)
        """,
        _expand_fcas_req_params(param_spec, start_date, end_date),
    )
    subset!(df, :SETTLEMENTDATE => ByRow(x -> start_date <= x < end_date))
    subset!(df, :BIDTYPE => ByRow(in(string.(FCAS_BID_TYPES))))

    for sub in groupby(df, :GENCONID)
        pair_sets = combine(
            groupby(sub, :SETTLEMENTDATE),
            [:REGIONID, :BIDTYPE] => ((r, b) -> [Set(zip(r, b))]) => :pairs,
        ).pairs
        allequal(pair_sets) || @warn "GENCONID $(sub.GENCONID[1]) governs a different (REGIONID, BIDTYPE) set at different intervals in this range; using the union." pair_sets
    end

    result = unique(select(df, :GENCONID, :REGIONID, :BIDTYPE))
    transform!(result, :BIDTYPE => ByRow(BidType) => :BIDTYPE)
    return result
end
