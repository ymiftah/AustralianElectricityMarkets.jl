"""
    read_interconnectors(db; as_of = nothing)

Reads and processes interconnector data from the database.

# Arguments
- `db`: The database connection.
- `as_of`: when a `Date` or `DateTime`, resolves each `INTERCONNECTORCONSTRAINT` row as of that
  instant (latest `EFFECTIVEDATE <= as_of`, then highest `VERSIONNO`). `nothing` keeps the latest
  version in the cache.

# Returns
A `DataFrame` containing the interconnector constraint data, latest or as of `as_of`. Interconnectors with an
endpoint region absent from the cached `DISPATCHREGIONSUM` are dropped with a warning, so that
table must be populated; an `ArgumentError` is thrown when it is missing or empty.

# Example
```julia
db = aem_connect()
interconnectors_df = read_interconnectors(db)
println(interconnectors_df)
```
"""
function read_interconnectors(db; as_of::Union{Nothing, Date, DateTime} = nothing)
    t_interconnector = read_hive(db, :INTERCONNECTOR)
    t_interconnector_constraint = read_hive(db, :INTERCONNECTORCONSTRAINT)

    # Each monthly archive holds the full history, so only the latest archive is read.
    as_of_filter = isnothing(as_of) ? "" : "WHERE c.EFFECTIVEDATE <= ?"
    sql = """
        WITH ic AS (SELECT * FROM $t_interconnector),
             latest_ic AS (
                 SELECT INTERCONNECTORID, REGIONFROM, REGIONTO, archive_month
                 FROM ic
                 WHERE archive_month = (SELECT max(archive_month) FROM ic)
             ),
             icc AS (SELECT * FROM $t_interconnector_constraint)
        SELECT c.* EXCLUDE (archive_month), l.REGIONFROM, l.REGIONTO
        FROM icc c
        INNER JOIN latest_ic l
          ON c.INTERCONNECTORID = l.INTERCONNECTORID AND c.archive_month = l.archive_month
        $as_of_filter
        QUALIFY row_number() OVER (
            PARTITION BY c.INTERCONNECTORID ORDER BY c.EFFECTIVEDATE DESC, c.VERSIONNO DESC
        ) = 1
    """
    df = isnothing(as_of) ? _query(db, sql) : _query(db, sql, [as_of])
    current_regions = _current_regions(db)
    retired = filter(
        row -> !(row.REGIONFROM in current_regions) || !(row.REGIONTO in current_regions), df,
    )
    isempty(retired) ||
        @warn "read_interconnectors: dropping $(nrow(retired)) interconnector(s) with a retired endpoint region not present in DISPATCHREGIONSUM" interconnectors = retired.INTERCONNECTORID
    return filter(
        row -> row.REGIONFROM in current_regions && row.REGIONTO in current_regions, df,
    )
end


"""
    read_interconnector_loss_breakpoints(db, as_of) -> DataFrame

`LOSSMODEL`'s segment breakpoints, version-resolved as of `as_of` (a `Date` or `DateTime`):
`INTERCONNECTORID`, `LOSSSEGMENT`, `MWBREAKPOINT`.

`LOSSMODEL` is a versioned `MARKET_CONFIG` table — rows are keyed by `EFFECTIVEDATE`, not by the
dispatch interval they are used in — so this filters on `EFFECTIVEDATE <= as_of` and takes the
highest `VERSIONNO`, never on `archive_month`.

Throws an `ArgumentError` when `LOSSMODEL` isn't cached at all.
"""
function read_interconnector_loss_breakpoints(db, as_of::Union{Date, DateTime})
    _table_is_cached(db, :LOSSMODEL) || throw(
        ArgumentError(
            "LOSSMODEL is not cached — run `populate(db, :LOSSMODEL, <from>, <to>)` first.",
        ),
    )
    table = read_hive(db, :LOSSMODEL)
    return _query(
        db,
        """
        WITH raw AS (
            SELECT * FROM $table
            WHERE EFFECTIVEDATE <= ?
            QUALIFY row_number() OVER (
                PARTITION BY INTERCONNECTORID, EFFECTIVEDATE, VERSIONNO, LOSSSEGMENT
                ORDER BY archive_month DESC
            ) = 1
        ),
        latest AS (
            SELECT INTERCONNECTORID, max_by(EFFECTIVEDATE, (EFFECTIVEDATE, VERSIONNO)) AS EFFECTIVEDATE,
                   max_by(VERSIONNO, (EFFECTIVEDATE, VERSIONNO)) AS VERSIONNO
            FROM raw GROUP BY INTERCONNECTORID
        )
        SELECT r.INTERCONNECTORID, r.LOSSSEGMENT, TRY_CAST(r.MWBREAKPOINT AS DOUBLE) AS MWBREAKPOINT
        FROM raw r
        INNER JOIN latest l
          ON r.INTERCONNECTORID = l.INTERCONNECTORID
             AND r.EFFECTIVEDATE = l.EFFECTIVEDATE AND r.VERSIONNO = l.VERSIONNO
        WHERE r.MWBREAKPOINT IS NOT NULL
        ORDER BY r.INTERCONNECTORID, MWBREAKPOINT
        """,
        [as_of],
    )
end


"""
    read_interconnector_demand_coefficients(db, as_of) -> DataFrame

`LOSSFACTORMODEL`'s per-region demand coefficients, version-resolved as of `as_of` the same way
[`read_interconnector_loss_breakpoints`](@ref) resolves `LOSSMODEL`: `INTERCONNECTORID`,
`REGIONID`, `DEMANDCOEFFICIENT`.

Throws an `ArgumentError` when `LOSSFACTORMODEL` isn't cached at all.
"""
function read_interconnector_demand_coefficients(db, as_of::Union{Date, DateTime})
    _table_is_cached(db, :LOSSFACTORMODEL) || throw(
        ArgumentError(
            "LOSSFACTORMODEL is not cached — run " *
                "`populate(db, :LOSSFACTORMODEL, <from>, <to>)` first.",
        ),
    )
    table = read_hive(db, :LOSSFACTORMODEL)
    return _query(
        db,
        """
        WITH raw AS (
            SELECT * FROM $table
            WHERE EFFECTIVEDATE <= ?
            QUALIFY row_number() OVER (
                PARTITION BY INTERCONNECTORID, EFFECTIVEDATE, VERSIONNO, REGIONID
                ORDER BY archive_month DESC
            ) = 1
        ),
        latest AS (
            SELECT INTERCONNECTORID, max_by(EFFECTIVEDATE, (EFFECTIVEDATE, VERSIONNO)) AS EFFECTIVEDATE,
                   max_by(VERSIONNO, (EFFECTIVEDATE, VERSIONNO)) AS VERSIONNO
            FROM raw GROUP BY INTERCONNECTORID
        )
        SELECT r.INTERCONNECTORID, r.REGIONID,
               TRY_CAST(r.DEMANDCOEFFICIENT AS DOUBLE) AS DEMANDCOEFFICIENT
        FROM raw r
        INNER JOIN latest l
          ON r.INTERCONNECTORID = l.INTERCONNECTORID
             AND r.EFFECTIVEDATE = l.EFFECTIVEDATE AND r.VERSIONNO = l.VERSIONNO
        WHERE r.DEMANDCOEFFICIENT IS NOT NULL
        ORDER BY r.INTERCONNECTORID, r.REGIONID
        """,
        [as_of],
    )
end


"""
    read_interconnector_loss_parameters(db, as_of) -> DataFrame

`INTERCONNECTORCONSTRAINT`'s loss parameters joined to `INTERCONNECTOR`'s region pair,
version-resolved as of `as_of`: `INTERCONNECTORID`, `REGIONFROM`, `REGIONTO`,
`FROMREGIONLOSSSHARE`, `LOSSCONSTANT`, `LOSSFLOWCOEFFICIENT`, `ICTYPE`.

Differs from [`read_interconnectors`](@ref), which resolves to the latest version overall.

Throws `ArgumentError` when either table isn't cached.
"""
function read_interconnector_loss_parameters(db, as_of::Union{Date, DateTime})
    for table in (:INTERCONNECTORCONSTRAINT, :INTERCONNECTOR)
        _table_is_cached(db, table) || throw(
            ArgumentError(
                "$table is not cached — run `populate(db, :$table, <from>, <to>)` first.",
            ),
        )
    end
    icc_table = read_hive(db, :INTERCONNECTORCONSTRAINT)
    ic_table = read_hive(db, :INTERCONNECTOR)
    return _query(
        db,
        """
        WITH icc AS (
            SELECT * FROM $icc_table
            WHERE EFFECTIVEDATE <= ?
            QUALIFY row_number() OVER (
                PARTITION BY INTERCONNECTORID, EFFECTIVEDATE, VERSIONNO ORDER BY archive_month DESC
            ) = 1
        ),
        resolved AS (
            SELECT * FROM icc
            QUALIFY row_number() OVER (
                PARTITION BY INTERCONNECTORID ORDER BY EFFECTIVEDATE DESC, VERSIONNO DESC
            ) = 1
        ),
        ic AS (
            SELECT INTERCONNECTORID, REGIONFROM, REGIONTO FROM $ic_table
            QUALIFY row_number() OVER (
                PARTITION BY INTERCONNECTORID ORDER BY archive_month DESC
            ) = 1
        )
        SELECT r.INTERCONNECTORID, ic.REGIONFROM, ic.REGIONTO,
               TRY_CAST(r.FROMREGIONLOSSSHARE AS DOUBLE) AS FROMREGIONLOSSSHARE,
               TRY_CAST(r.LOSSCONSTANT AS DOUBLE) AS LOSSCONSTANT,
               TRY_CAST(r.LOSSFLOWCOEFFICIENT AS DOUBLE) AS LOSSFLOWCOEFFICIENT,
               r.ICTYPE
        FROM resolved r
        INNER JOIN ic ON ic.INTERCONNECTORID = r.INTERCONNECTORID
        ORDER BY r.INTERCONNECTORID
        """,
        [as_of],
    )
end


# AEMO's `FROMREGIONLOSSSHARE` for Basslink is not well defined; nempy sets it to 1 to best match NEMDE.
const _LOSS_SHARE_OVERRIDES = Dict("T-V-MNSP1" => 1.0)

# Demand coefficients AEMO publishes but MMSDM LOSSFACTORMODEL omits, as
# (interconnector, region) => (value, valid_from, valid_until). Used only where the table has no
# value for that pair. V-SA NSW1 for FY2025-26: AEMO, 2025-26 Marginal Loss Factors report,
# section 3 p. 56 and Table 25 p. 59.
const _DEMAND_COEFFICIENT_PATCHES = Dict(
    ("V-SA", "NSW1") => (value = 1.6981e-6, valid_from = Date(2025, 7, 1), valid_until = Date(2026, 7, 1)),
)

function _apply_demand_coefficient_patches!(demand_coefficients, as_of)
    for ((id, region), p) in _DEMAND_COEFFICIENT_PATCHES
        p.valid_from <= Date(as_of) < p.valid_until || continue
        haskey(demand_coefficients, id) || continue
        get!(demand_coefficients[id], region, p.value)
    end
    return demand_coefficients
end


"""
    interconnector_loss_models(db, as_of) -> Dict{String, InterconnectorLossModel}

Every interconnector's [`InterconnectorLossModel`](@ref), assembled from
[`read_interconnector_loss_parameters`](@ref),
[`read_interconnector_demand_coefficients`](@ref) and
[`read_interconnector_loss_breakpoints`](@ref) as of `as_of`.

An interconnector with loss parameters but no `LOSSMODEL` breakpoints is skipped, reported in
one summary `@warn`.

The loss share of `T-V-MNSP1` (Basslink) is fixed at `1.0`, as in nempy, because AEMO's published
value is not well defined.

Demand coefficients missing from `LOSSFACTORMODEL` but published by AEMO (V-SA `NSW1` for
FY2025-26) are filled in; a value present in the table is never overridden.

Throws `ArgumentError` when no interconnector survives.
"""
function interconnector_loss_models(db, as_of::Union{Date, DateTime})
    params = read_interconnector_loss_parameters(db, as_of)
    coefficients = read_interconnector_demand_coefficients(db, as_of)
    breakpoints = read_interconnector_loss_breakpoints(db, as_of)

    by_interconnector = Dict{String, Vector{Float64}}()
    for row in eachrow(breakpoints)
        push!(get!(by_interconnector, row.INTERCONNECTORID, Float64[]), row.MWBREAKPOINT)
    end
    demand_coefficients = Dict{String, Dict{String, Float64}}()
    for row in eachrow(coefficients)
        d = get!(demand_coefficients, row.INTERCONNECTORID, Dict{String, Float64}())
        d[row.REGIONID] = row.DEMANDCOEFFICIENT
    end
    _apply_demand_coefficient_patches!(demand_coefficients, as_of)

    models = Dict{String, InterconnectorLossModel}()
    skipped = String[]
    for row in eachrow(params)
        id = row.INTERCONNECTORID
        bps = sort(get(by_interconnector, id, Float64[]))
        if length(bps) < 2
            push!(skipped, id)
            continue
        end
        models[id] = InterconnectorLossModel(;
            interconnector = id,
            from_region = row.REGIONFROM,
            to_region = row.REGIONTO,
            from_region_loss_share = get(_LOSS_SHARE_OVERRIDES, id, coalesce(row.FROMREGIONLOSSSHARE, 0.5)),
            loss_constant = coalesce(row.LOSSCONSTANT, 1.0),
            loss_flow_coefficient = coalesce(row.LOSSFLOWCOEFFICIENT, 0.0),
            demand_coefficients = get(demand_coefficients, id, Dict{String, Float64}()),
            breakpoints = bps,
        )
    end
    isempty(skipped) ||
        @warn "interconnector_loss_models: $(length(skipped)) interconnector(s) have no LOSSMODEL breakpoints as of $as_of; skipped" skipped
    isempty(models) && throw(
        ArgumentError(
            "no interconnector has a complete loss model as of $as_of. Check that " *
                "LOSSMODEL/LOSSFACTORMODEL/INTERCONNECTORCONSTRAINT are cached and that their " *
                "EFFECTIVEDATEs precede $as_of.",
        ),
    )
    return models
end


"""
    read_interconnector_limits(db, date_range; intervention = 0)

Reads the per-interval interconnector limits and metered flow from `DISPATCHINTERCONNECTORRES`:
one row per `(SETTLEMENTDATE, INTERCONNECTORID)` with `METEREDMWFLOW` (the SCADA flow, the
interval's starting flow), `EXPORTLIMIT` and `IMPORTLIMIT` (the energy-only flow limits NEMDE
applied, signed along the interconnector's from-to direction: `IMPORTLIMIT <= flow <= EXPORTLIMIT`).

# Arguments
- `db`: an `AEMDB` connection.
- `date_range`: the dispatch intervals to read (half-open: `start <= t < stop`).
- `intervention`: `0` for the pricing run, `1` for the physical run.

# Returns
A `DataFrame` with `SETTLEMENTDATE`, `INTERCONNECTORID`, `METEREDMWFLOW`, `EXPORTLIMIT`,
`IMPORTLIMIT`.
"""
function read_interconnector_limits(db, date_range; intervention::Integer = 0)
    start_date = first(date_range)
    end_date = last(date_range)
    sd = Date(start_date) - Day(1)
    ed = Date(end_date) + Day(1)

    _table_is_cached(db, :DISPATCHINTERCONNECTORRES) || throw(
        ArgumentError(
            "DISPATCHINTERCONNECTORRES is not cached; run `populate(db, :DISPATCHINTERCONNECTORRES, <from>, <to>)` first.",
        ),
    )
    table = read_hive(db, :DISPATCHINTERCONNECTORRES)
    schema = names(_query(db, "SELECT * FROM $table LIMIT 0"))
    params = Any[sd, ed]
    _push_intervention!(params, schema, intervention)
    df = _query(
        db,
        """
        SELECT SETTLEMENTDATE, INTERCONNECTORID,
               $(_cast_double("METEREDMWFLOW")), $(_cast_double("EXPORTLIMIT")), $(_cast_double("IMPORTLIMIT"))
        FROM $table
        WHERE SETTLEMENTDATE BETWEEN ? AND ? $(_intervention_where(schema))
        QUALIFY row_number() OVER (
            PARTITION BY SETTLEMENTDATE, INTERCONNECTORID ORDER BY archive_month DESC
        ) = 1
        """,
        params,
    )
    subset!(df, :SETTLEMENTDATE => ByRow(x -> start_date <= x < end_date))
    return df
end
