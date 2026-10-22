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


# `INTERCONNECTORID`, `key` and non-null `value` of each interconnector's latest `table_name` version
# effective on or before `as_of`, sorted by interconnector then `order_by`.
function _read_loss_model_table(db, table_name::Symbol, key::String, value::String, order_by::String, as_of)
    _require_cached(db, table_name)
    table = read_hive(db, table_name)
    return _query(
        db,
        """
        WITH raw AS (
            SELECT * FROM $table
            WHERE EFFECTIVEDATE <= ?
            QUALIFY row_number() OVER (
                PARTITION BY INTERCONNECTORID, EFFECTIVEDATE, VERSIONNO, $key
                ORDER BY archive_month DESC
            ) = 1
        ),
        latest AS (
            SELECT INTERCONNECTORID, max_by(EFFECTIVEDATE, (EFFECTIVEDATE, VERSIONNO)) AS EFFECTIVEDATE,
                   max_by(VERSIONNO, (EFFECTIVEDATE, VERSIONNO)) AS VERSIONNO
            FROM raw GROUP BY INTERCONNECTORID
        )
        SELECT r.INTERCONNECTORID, r.$key, TRY_CAST(r.$value AS DOUBLE) AS $value
        FROM raw r
        INNER JOIN latest l
          ON r.INTERCONNECTORID = l.INTERCONNECTORID
             AND r.EFFECTIVEDATE = l.EFFECTIVEDATE AND r.VERSIONNO = l.VERSIONNO
        WHERE r.$value IS NOT NULL
        ORDER BY r.INTERCONNECTORID, $order_by
        """,
        [as_of],
    )
end


"""
    read_interconnector_loss_breakpoints(db, as_of) -> DataFrame

Reads `LOSSMODEL`'s segment breakpoints for each interconnector's latest version effective on or
before `as_of`.

# Arguments
- `db`: an `AEMDB` connection.
- `as_of`: a `Date` or `DateTime`.

# Returns
A `DataFrame` with `INTERCONNECTORID`, `LOSSSEGMENT` and `MWBREAKPOINT`, sorted by breakpoint
within an interconnector. Throws an `ArgumentError` when `LOSSMODEL` is not cached.
"""
function read_interconnector_loss_breakpoints(db, as_of::Union{Date, DateTime})
    return _read_loss_model_table(db, :LOSSMODEL, "LOSSSEGMENT", "MWBREAKPOINT", "MWBREAKPOINT", as_of)
end


"""
    read_interconnector_demand_coefficients(db, as_of) -> DataFrame

Reads `LOSSFACTORMODEL`'s per-region demand coefficients for each interconnector's latest version
effective on or before `as_of`.

# Arguments
- `db`: an `AEMDB` connection.
- `as_of`: a `Date` or `DateTime`.

# Returns
A `DataFrame` with `INTERCONNECTORID`, `REGIONID` and `DEMANDCOEFFICIENT`. Throws an
`ArgumentError` when `LOSSFACTORMODEL` is not cached.
"""
function read_interconnector_demand_coefficients(db, as_of::Union{Date, DateTime})
    return _read_loss_model_table(db, :LOSSFACTORMODEL, "REGIONID", "DEMANDCOEFFICIENT", "r.REGIONID", as_of)
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
    foreach(table -> _require_cached(db, table), (:INTERCONNECTORCONSTRAINT, :INTERCONNECTOR))
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
    columns = [_cast_double(c) for c in ("METEREDMWFLOW", "EXPORTLIMIT", "IMPORTLIMIT")]
    return _read_dispatch_table(columns, db, :DISPATCHINTERCONNECTORRES, "INTERCONNECTORID", date_range; intervention)
end
