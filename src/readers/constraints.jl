"""
    read_invoked_constraints(db, date_range; intervention = 0)

Reads `DISPATCHCONSTRAINT` over `date_range`: one row per `(SETTLEMENTDATE, GENCONID)` invoked in
dispatch, with `RHS` and the constraint version NEMDE used (`GENCONID_EFFECTIVEDATE`/`GENCONID_VERSIONNO`).
"""
function read_invoked_constraints(db, date_range; intervention::Integer = 0)
    _check_intervention(intervention)
    source = read_hive(db, :DISPATCHCONSTRAINT, date_range)
    return _query(
        db,
        """
        WITH run AS (
            SELECT * FROM $source
            WHERE SETTLEMENTDATE >= ? AND SETTLEMENTDATE < ?
            QUALIFY COALESCE(INTERVENTION, 0) = CASE WHEN ? = 0 THEN 0
                ELSE max(COALESCE(INTERVENTION, 0)) OVER (PARTITION BY SETTLEMENTDATE) END
        )
        SELECT SETTLEMENTDATE, CONSTRAINTID AS GENCONID,
               TRY_CAST(RHS AS DOUBLE) AS RHS,
               GENCONID_EFFECTIVEDATE, GENCONID_VERSIONNO
        FROM run
        QUALIFY row_number() OVER (PARTITION BY SETTLEMENTDATE, CONSTRAINTID ORDER BY archive_month DESC) = 1
        ORDER BY SETTLEMENTDATE, GENCONID
        """,
        [first(date_range), last(date_range), intervention],
    )
end

"""
    read_constraint_definitions(db, gencon_versions)

Joins each `(GENCONID, GENCONID_EFFECTIVEDATE, GENCONID_VERSIONNO)` row of `gencon_versions`
(from [`read_invoked_constraints`](@ref)) to its exact `GENCONDATA` version: `CONSTRAINTTYPE`,
`GENERICCONSTRAINTWEIGHT`, `CONSTRAINTVALUE`, `DESCRIPTION`, `LIMITTYPE` and `SOURCE`. A version
with no cached `GENCONDATA` row is absent from the result. Throws an `ArgumentError` on an empty
`gencon_versions`.
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
                  AND (GENCONID, EFFECTIVEDATE, VERSIONNO) IN (
                      SELECT GENCONID, GENCONID_EFFECTIVEDATE, GENCONID_VERSIONNO
                      FROM wanted_gencon_versions
                  )
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
                  AND (GENCONID, EFFECTIVEDATE, VERSIONNO) IN (
                      SELECT GENCONID, GENCONID_EFFECTIVEDATE, GENCONID_VERSIONNO
                      FROM wanted_gencon_versions
                  )
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
                  AND (GENCONID, EFFECTIVEDATE, VERSIONNO) IN (
                      SELECT GENCONID, GENCONID_EFFECTIVEDATE, GENCONID_VERSIONNO
                      FROM wanted_gencon_versions
                  )
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
    read_constraint_fcas_requirements(db, date_range; intervention = 0)

Reads the dispatch FCAS requirement table's `GENCONID -> (REGIONID, BIDTYPE)` mapping over
`date_range`. Keyed by bare `GENCONID`.

# Returns
Long-format `DataFrame`. Throws `ArgumentError` when neither `DISPATCH_FCAS_REQ` nor
`DISPATCH_FCAS_REQ_CONSTRAINT` is cached.
"""
function read_constraint_fcas_requirements(db, date_range; intervention::Integer = 0)
    governed = @chain _fcas_requirement_rows(db, first(date_range), last(date_range), intervention) begin
        select(:SETTLEMENTDATE, :GENCONID, :REGIONID, :BIDTYPE)
        unique
    end
    inconsistent = @chain governed begin
        groupby([:GENCONID, :SETTLEMENTDATE])
        combine([:REGIONID, :BIDTYPE] => ((r, b) -> Ref(Set(zip(r, b)))) => :pairs)
        groupby(:GENCONID)
        combine(:pairs => (p -> Ref(unique(p))) => :pair_sets)
        subset(:pair_sets => ByRow(sets -> length(sets) > 1))
    end
    for row in eachrow(inconsistent)
        @warn "GENCONID $(row.GENCONID) governs a different (REGIONID, BIDTYPE) set at different intervals in this range; using the union." pair_sets = row.pair_sets
    end
    return @chain governed begin
        select(:GENCONID, :REGIONID, :BIDTYPE)
        unique
        transform!(:BIDTYPE => ByRow(BidType) => :BIDTYPE)
    end
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
