"""
    read_demand(db; resolution::Dates.Period=Dates.Minute(5))
    read_demand(db, date_range; resolution::Dates.Period=Dates.Minute(5))

Read regional demand and aggregate it at `resolution`. When `date_range` is provided,
read only the raw intervals contributing to aggregate timestamps in `[first(date_range), last(date_range))`.

# Arguments
- `db`: The database connection.
- `date_range`: Optional range of aggregate timestamps, with an inclusive start and exclusive end.
- `resolution::Dates.Period`: The time resolution to which timestamps are rounded up. Defaults to 5 minutes.

# Returns
A `DataFrame` with regional demand, aggregated by the specified resolution.
`LOSSDEMAND` is `INITIALSUPPLY + DEMANDFORECAST` plus the initial charging load of the region's
`BIDIRECTIONAL` units (`DISPATCHLOAD.INITIALMW` where negative), with unit type and region resolved
as of the interval.

# Example
```julia
db = aem_connect()
demand_df = read_demand(db; resolution=Dates.Hour(1))
println(demand_df)
```
"""
function read_demand(db, date_range = nothing; resolution::Dates.Period = Dates.Minute(5))
    source = read_hive(db, :DISPATCHREGIONSUM)
    dispatchload = read_hive(db, :DISPATCHLOAD)
    summary = read_hive(db, :DUDETAILSUMMARY)
    demand_where = ""
    charging_where = ""
    params = Any[]
    if !isnothing(date_range)
        # Each rounded-up timestamp includes the raw bin ending at it, even before the requested start.
        lower = ceil(DateTime(first(date_range)), resolution) - resolution
        upper = ceil(DateTime(last(date_range)), resolution) - resolution
        charging_where = "AND SETTLEMENTDATE > ? AND SETTLEMENTDATE <= ?"
        demand_where = "AND r.SETTLEMENTDATE > ? AND r.SETTLEMENTDATE <= ?"
        append!(params, (lower, upper, lower, upper))
    end
    df = _query(
        db,
        """
        WITH sm_raw AS (SELECT * FROM $summary),
             bdu AS (
                 SELECT DUID, REGIONID, START_DATE, END_DATE
                 FROM sm_raw
                 WHERE DISPATCHTYPE = 'BIDIRECTIONAL'
                   AND archive_month = (SELECT max(archive_month) FROM sm_raw)
             ),
             charging AS (
                 SELECT d.SETTLEMENTDATE, bdu.REGIONID, sum(least(d.INITIALMW, 0.0)) AS INITIALCHARGE
                 FROM (
                     SELECT DUID, SETTLEMENTDATE, INITIALMW
                     FROM $dispatchload
                     WHERE INTERVENTION = 0 $charging_where
                     QUALIFY row_number() OVER (
                         PARTITION BY DUID, SETTLEMENTDATE ORDER BY archive_month DESC
                     ) = 1
                 ) d
                 JOIN bdu ON d.DUID = bdu.DUID
                     AND bdu.START_DATE <= d.SETTLEMENTDATE
                     AND (bdu.END_DATE IS NULL OR bdu.END_DATE > d.SETTLEMENTDATE)
                 GROUP BY ALL
             )
        SELECT r.SETTLEMENTDATE, r.REGIONID, r.TOTALDEMAND,
               r.INITIALSUPPLY + r.DEMANDFORECAST + COALESCE(c.INITIALCHARGE, 0.0) AS LOSSDEMAND
        FROM $source r
        LEFT JOIN charging c ON c.SETTLEMENTDATE = r.SETTLEMENTDATE AND c.REGIONID = r.REGIONID
        WHERE r.SETTLEMENTDATE IS NOT NULL AND r.REGIONID IS NOT NULL
          AND r.TOTALDEMAND IS NOT NULL
          $demand_where
        """,
        params,
    )
    ## TODO do this aggregation in duckdb.
    df[!, :SETTLEMENTDATE] = ceil.(df[!, :SETTLEMENTDATE], resolution)
    sort!(df, :SETTLEMENTDATE)
    demand = @chain df begin
        groupby([:SETTLEMENTDATE, :REGIONID])
        combine(_, valuecols(_) .=> mean ∘ skipmissing; renamecols = false)
    end
    if !isnothing(date_range)
        subset!(demand, :SETTLEMENTDATE => ByRow(x -> first(date_range) <= x < last(date_range)))
    end
    ## TODO END
    return demand
end

"""
    _current_regions(db) -> Set{String}

Every `REGIONID` present in the cached `DISPATCHREGIONSUM`, the authoritative source of which
regions are currently active - `INTERCONNECTOR`/`INTERCONNECTORCONSTRAINT` retain rows for
long-retired interconnectors (e.g. `SNOWY1`/`V-SN`, abolished 2008) that a naive
`REGIONFROM`/`REGIONTO` union would otherwise resurrect as a phantom, zero-demand region.
"""
function _current_regions(db)
    df = try
        table = read_hive(db, :DISPATCHREGIONSUM)
        _query(db, "SELECT DISTINCT REGIONID FROM $table WHERE REGIONID IS NOT NULL")
    catch err
        throw(
            ArgumentError(
                "read_interconnectors needs a cached DISPATCHREGIONSUM to identify the active regions; " *
                    "run `populate(db, :DISPATCHREGIONSUM, start_date, end_date)` first ($(sprint(showerror, err)))",
            ),
        )
    end
    isempty(df) && throw(
        ArgumentError(
            "read_interconnectors found no REGIONID in the cached DISPATCHREGIONSUM; " *
                "populate it with `populate(db, :DISPATCHREGIONSUM, start_date, end_date)`",
        ),
    )
    return Set(df.REGIONID)
end
