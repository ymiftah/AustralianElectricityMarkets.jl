"""
    read_invoked_constraints(db, date_range; intervention = 0)

Reads `DISPATCHCONSTRAINT` over `date_range`: one row per `(SETTLEMENTDATE, GENCONID)` with
`RHS`, `LHS`, `MARGINALVALUE`, and the exact constraint version NEMDE used that interval
(`GENCONID_EFFECTIVEDATE`/`GENCONID_VERSIONNO`). Membership in this table is the definition
of "NEMDE actually enforced this constraint" — see [`add_nem_constraints!`](@ref).
"""
function read_invoked_constraints(db, date_range; intervention::Integer = 0)
    start_date = first(date_range)
    end_date = last(date_range)
    sd = Date(start_date) - Day(1)
    ed = Date(end_date) + Day(1)
    table = read_hive(db, :DISPATCHCONSTRAINT)
    schema = names(_query(db, "SELECT * FROM $table LIMIT 0"))
    params = Any[sd, ed]
    _push_intervention!(params, schema, intervention)
    df = _query(
        db,
        """
        SELECT SETTLEMENTDATE, CONSTRAINTID AS GENCONID,
               $(_cast_double("RHS")), $(_cast_double("LHS")), $(_cast_double("MARGINALVALUE")),
               GENCONID_EFFECTIVEDATE, GENCONID_VERSIONNO
        FROM $table
        WHERE SETTLEMENTDATE BETWEEN ? AND ? $(_intervention_where(schema))
        QUALIFY row_number() OVER (
            PARTITION BY SETTLEMENTDATE, CONSTRAINTID ORDER BY archive_month DESC
        ) = 1
        ORDER BY SETTLEMENTDATE, GENCONID
        """,
        params,
    )
    subset!(df, :SETTLEMENTDATE => ByRow(x -> start_date <= x < end_date))
    return df
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

"""
    read_constraint_definitions(db, gencon_versions)

`gencon_versions` has distinct `(GENCONID, GENCONID_EFFECTIVEDATE, GENCONID_VERSIONNO)`
rows (see [`read_invoked_constraints`](@ref)). Joins each to its exact `GENCONDATA` version:
`CONSTRAINTTYPE`, `GENERICCONSTRAINTWEIGHT`, `CONSTRAINTVALUE`, `DYNAMICRHS`, plus
`DESCRIPTION`/`LIMITTYPE`/`SOURCE`. A `GENCONID` absent from the result has no `GENCONDATA`
row for that exact version — usually because the defining archive month isn't cached (see
[`read_fcas_requirements`](@ref)) — callers must treat that as "no definition available".
Throws an `ArgumentError` on an empty `gencon_versions`: nothing was invoked over the range,
which means `DISPATCHCONSTRAINT` was never cached for it.
"""
function read_constraint_definitions(db, gencon_versions)
    DataFrames.isempty(gencon_versions) && throw(
        ArgumentError(
            "gencon_versions is empty: no constraint was invoked over the requested range. " *
                "That means DISPATCHCONSTRAINT is not cached for it — run `populate(db, :DISPATCHCONSTRAINT, ...)` first.",
        ),
    )
    wanted = unique(select(gencon_versions, :GENCONID, :GENCONID_EFFECTIVEDATE, :GENCONID_VERSIONNO))
    DuckDB.register_data_frame(db.db, wanted, "wanted_gencon_versions")
    table = read_hive(db, :GENCONDATA)
    df = _query(
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
            TRY_CAST(g.DYNAMICRHS AS INTEGER) AS DYNAMICRHS,
            g.DESCRIPTION, g.LIMITTYPE, g.SOURCE
        FROM wanted_gencon_versions w
        INNER JOIN gencon g
            ON g.GENCONID = w.GENCONID AND g.EFFECTIVEDATE = w.GENCONID_EFFECTIVEDATE
               AND g.VERSIONNO = w.GENCONID_VERSIONNO
        """,
    )
    DuckDB.unregister_table(db.db, "wanted_gencon_versions")
    return df
end

"""
    read_constraint_terms(db, gencon_versions, date_range)

Reads the three `SPD*` tables (`SPDCONNECTIONPOINTCONSTRAINT`, `SPDREGIONCONSTRAINT`,
`SPDINTERCONNECTORCONSTRAINT`) for the exact `(GENCONID, EFFECTIVEDATE, VERSIONNO)` triples
in `gencon_versions`, long-format: one row per `(GENCONID, TERM_KIND, KEY, BIDTYPE, FACTOR)`.
`TERM_KIND` is `"UNIT"`, `"REGION"`, or `"INTERCONNECTOR"` (`BIDTYPE` is `missing` for
`"INTERCONNECTOR"` rows — AEMO's interconnector terms aren't service-specific). A `"UNIT"`
row's `CONNECTIONPOINTID` is resolved to every `DUID` behind it as of `date_range`
(`DUDETAILSUMMARY.START_DATE <= last(date_range) AND (END_DATE IS NULL OR END_DATE >= first(date_range))`)
— one SPD row can expand to several `UnitTerm`s when a connection point serves multiple units.
Throws an `ArgumentError` on an empty `gencon_versions`, as [`read_constraint_definitions`](@ref) does.
"""
function read_constraint_terms(db, gencon_versions, date_range)
    DataFrames.isempty(gencon_versions) && throw(
        ArgumentError(
            "gencon_versions is empty: no constraint was invoked over the requested range. " *
                "That means DISPATCHCONSTRAINT is not cached for it — run `populate(db, :DISPATCHCONSTRAINT, ...)` first.",
        ),
    )
    start_date = first(date_range)
    end_date = last(date_range)
    wanted = unique(select(gencon_versions, :GENCONID, :GENCONID_EFFECTIVEDATE, :GENCONID_VERSIONNO))
    eff_bound = _effective_date_bound(wanted)
    DuckDB.register_data_frame(db.db, wanted, "wanted_gencon_versions")

    cp_table = read_hive(db, :SPDCONNECTIONPOINTCONSTRAINT)
    region_table = read_hive(db, :SPDREGIONCONSTRAINT)
    ic_table = read_hive(db, :SPDINTERCONNECTORCONSTRAINT)
    dudetailsummary_table = read_hive(db, :DUDETAILSUMMARY)

    df = _query(
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
            SELECT cp.GENCONID, cp.CONNECTIONPOINTID, cp.BIDTYPE, TRY_CAST(cp.FACTOR AS DOUBLE) AS FACTOR
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
        SELECT cp_matched.GENCONID, 'UNIT' AS TERM_KIND, duids.DUID AS KEY, cp_matched.BIDTYPE, cp_matched.FACTOR
        FROM cp_matched INNER JOIN duids ON duids.CONNECTIONPOINTID = cp_matched.CONNECTIONPOINTID

        UNION ALL

        SELECT r.GENCONID, 'REGION' AS TERM_KIND, r.REGIONID AS KEY, r.BIDTYPE, TRY_CAST(r.FACTOR AS DOUBLE) AS FACTOR
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

        SELECT i.GENCONID, 'INTERCONNECTOR' AS TERM_KIND, i.INTERCONNECTORID AS KEY,
               CAST(NULL AS VARCHAR) AS BIDTYPE, TRY_CAST(i.FACTOR AS DOUBLE) AS FACTOR
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
    DuckDB.unregister_table(db.db, "wanted_gencon_versions")
    return df
end

"""
    read_constraint_fcas_requirements(db, date_range; intervention = 0)

Reads `DISPATCH_FCAS_REQ`'s `GENCONID -> (REGIONID, BIDTYPE)` mapping over `date_range`,
long-format: one row per distinct pair observed. Warns (does not silently merge) if a
`GENCONID`'s pair-set changes mid-range — AEMO re-scoping a constraint's market attribution
partway through is rare but not representable by a single static set.
"""
function read_constraint_fcas_requirements(db, date_range; intervention::Integer = 0)
    start_date = first(date_range)
    end_date = last(date_range)
    sd = Date(start_date) - Day(1)
    ed = Date(end_date) + Day(1)
    table = read_hive(db, :DISPATCH_FCAS_REQ)
    schema = names(_query(db, "SELECT * FROM $table LIMIT 0"))
    params = Any[sd, ed]
    _push_intervention!(params, schema, intervention)
    df = _query(
        db,
        """
        SELECT DISTINCT SETTLEMENTDATE, GENCONID, REGIONID, BIDTYPE
        FROM $table
        WHERE SETTLEMENTDATE BETWEEN ? AND ? $(_intervention_where(schema))
        """,
        params,
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
