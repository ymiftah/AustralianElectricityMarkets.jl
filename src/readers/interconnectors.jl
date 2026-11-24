"""
    read_interconnectors(db, date_range)

Reads each interconnector's `INTERCONNECTORCONSTRAINT` version in force at `first(date_range)`
(latest `EFFECTIVEDATE`, then highest `VERSIONNO`), joined to its `INTERCONNECTOR` region pair.
Interconnectors with an endpoint region absent from the latest `DISPATCHREGIONSUM` snapshot at or
before `first(date_range)` are dropped with a warning.

# Arguments
- `db`: the database connection.
- `date_range`: the half-open range of interval-ending stamps.

# Returns
A `DataFrame` with the `INTERCONNECTORCONSTRAINT` columns, `REGIONFROM` and `REGIONTO`. Throws an
`ArgumentError` when no `DISPATCHREGIONSUM` snapshot is cached at or before `first(date_range)`.

# Example
```julia
db = aem_connect()
interconnectors = read_interconnectors(db, DateTime(2025, 1, 1):Minute(5):DateTime(2025, 1, 2))
```
"""
function read_interconnectors(db, date_range)
    as_of = first(date_range)
    _require_cached(db, :DISPATCHREGIONSUM; context = "read_interconnectors needs it to identify the active regions.")
    demand = read_hive(db, :DISPATCHREGIONSUM)
    regions = _query(
        db,
        """
        SELECT DISTINCT REGIONID FROM $demand
        WHERE REGIONID IS NOT NULL AND SETTLEMENTDATE = (
            SELECT max(SETTLEMENTDATE) FROM $demand WHERE REGIONID IS NOT NULL AND SETTLEMENTDATE <= ?
        )
        """,
        [as_of],
    ).REGIONID
    isempty(regions) && throw(
        ArgumentError(
            "read_interconnectors found no DISPATCHREGIONSUM snapshot at or before $as_of; " *
                "populate it with `populate(db, :DISPATCHREGIONSUM, start_date, end_date)`",
        ),
    )
    interconnector = read_hive(db, :INTERCONNECTOR)
    # Each monthly archive holds the full history, so only the latest archive is read.
    interconnectors = _query(
        db,
        """
        WITH latest_ic AS (
            SELECT INTERCONNECTORID, REGIONFROM, REGIONTO, archive_month
            FROM $interconnector
            WHERE archive_month = (SELECT max(archive_month) FROM $interconnector)
        )
        SELECT c.* EXCLUDE (archive_month), l.REGIONFROM, l.REGIONTO
        FROM $(read_hive(db, :INTERCONNECTORCONSTRAINT)) c
        INNER JOIN latest_ic l
          ON c.INTERCONNECTORID = l.INTERCONNECTORID AND c.archive_month = l.archive_month
        WHERE c.EFFECTIVEDATE <= ?
        QUALIFY row_number() OVER (
            PARTITION BY c.INTERCONNECTORID ORDER BY c.EFFECTIVEDATE DESC, c.VERSIONNO DESC
        ) = 1
        """,
        [as_of],
    )
    current = subset(interconnectors, [:REGIONFROM, :REGIONTO] => ByRow((from, to) -> from in regions && to in regions))
    retired = setdiff(interconnectors.INTERCONNECTORID, current.INTERCONNECTORID)
    isempty(retired) ||
        @warn "read_interconnectors: dropping $(length(retired)) interconnector(s) with a retired endpoint region not present in DISPATCHREGIONSUM" interconnectors = retired
    return current
end

"""
    read_interconnector_loss_breakpoints(db; as_of) -> DataFrame

Reads `LOSSMODEL`'s segment breakpoints for each interconnector's latest version effective on or
before `as_of`.

# Arguments
- `db`: an `AEMDB` connection.
- `as_of`: a `Date` or `DateTime`.

# Returns
A `DataFrame` with `INTERCONNECTORID`, `LOSSSEGMENT` and `MWBREAKPOINT`, sorted by breakpoint
within an interconnector. Throws an `ArgumentError` when `LOSSMODEL` is not cached.
"""
function read_interconnector_loss_breakpoints(db; as_of::Union{Date, DateTime})
    _require_cached(db, :LOSSMODEL)
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
    read_interconnector_demand_coefficients(db; as_of) -> DataFrame

Reads `LOSSFACTORMODEL`'s per-region demand coefficients for each interconnector's latest version
effective on or before `as_of`.

# Arguments
- `db`: an `AEMDB` connection.
- `as_of`: a `Date` or `DateTime`.

# Returns
A `DataFrame` with `INTERCONNECTORID`, `REGIONID` and `DEMANDCOEFFICIENT`. Throws an
`ArgumentError` when `LOSSFACTORMODEL` is not cached.
"""
function read_interconnector_demand_coefficients(db; as_of::Union{Date, DateTime})
    _require_cached(db, :LOSSFACTORMODEL)
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
        SELECT r.INTERCONNECTORID, r.REGIONID, TRY_CAST(r.DEMANDCOEFFICIENT AS DOUBLE) AS DEMANDCOEFFICIENT
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
    read_interconnector_loss_parameters(db; as_of) -> DataFrame

`INTERCONNECTORCONSTRAINT`'s loss parameters joined to `INTERCONNECTOR`'s region pair,
version-resolved as of `as_of`: `INTERCONNECTORID`, `REGIONFROM`, `REGIONTO`,
`FROMREGIONLOSSSHARE`, `LOSSCONSTANT`, `LOSSFLOWCOEFFICIENT`, `ICTYPE`.

Does not filter out interconnectors whose endpoint regions are absent from cached demand.

Throws `ArgumentError` when either table isn't cached.
"""
function read_interconnector_loss_parameters(db; as_of::Union{Date, DateTime})
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
- `intervention`: `0` for the pricing run. `1` for the physical run where the interval has one, else the pricing run.

# Returns
A `DataFrame` with `SETTLEMENTDATE`, `INTERCONNECTORID`, `METEREDMWFLOW`, `EXPORTLIMIT`,
`IMPORTLIMIT`.
"""
function read_interconnector_limits(db, date_range; intervention::Integer = 0)
    _check_intervention(intervention)
    source = read_hive(db, :DISPATCHINTERCONNECTORRES, date_range)
    return _query(
        db,
        """
        WITH run AS (
            SELECT * FROM $source
            WHERE SETTLEMENTDATE >= ? AND SETTLEMENTDATE < ?
            QUALIFY COALESCE(INTERVENTION, 0) = CASE WHEN ? = 0 THEN 0
                ELSE max(COALESCE(INTERVENTION, 0)) OVER (PARTITION BY SETTLEMENTDATE) END
        )
        SELECT SETTLEMENTDATE, INTERCONNECTORID,
               TRY_CAST(METEREDMWFLOW AS DOUBLE) AS METEREDMWFLOW,
               TRY_CAST(EXPORTLIMIT AS DOUBLE) AS EXPORTLIMIT,
               TRY_CAST(IMPORTLIMIT AS DOUBLE) AS IMPORTLIMIT
        FROM run
        QUALIFY row_number() OVER (PARTITION BY SETTLEMENTDATE, INTERCONNECTORID ORDER BY archive_month DESC) = 1
        ORDER BY SETTLEMENTDATE, INTERCONNECTORID
        """,
        [first(date_range), last(date_range), intervention],
    )
end
