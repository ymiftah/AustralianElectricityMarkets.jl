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


"""
    read_demand(db; resolution::Dates.Period=Dates.Minute(5))

Read and process regional demand data from the database.

# Arguments
- `db`: The database connection.
- `resolution::Dates.Period`: The time resolution to which the data should be floored. Defaults to 5 minutes.

# Returns
A `DataFrame` with demand and renewable availability data, aggregated by the specified resolution.
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
function read_demand(db; resolution::Dates.Period = Dates.Minute(5))
    source = read_hive(db, :DISPATCHREGIONSUM)
    dispatchload = read_hive(db, :DISPATCHLOAD)
    summary = read_hive(db, :DUDETAILSUMMARY)
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
                     WHERE INTERVENTION = 0
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
               r.INITIALSUPPLY + r.DEMANDFORECAST + COALESCE(c.INITIALCHARGE, 0.0) AS LOSSDEMAND,
               r.SS_SOLAR_AVAILABILITY, r.SS_WIND_AVAILABILITY
        FROM $source r
        LEFT JOIN charging c ON c.SETTLEMENTDATE = r.SETTLEMENTDATE AND c.REGIONID = r.REGIONID
        WHERE r.SETTLEMENTDATE IS NOT NULL AND r.REGIONID IS NOT NULL
          AND r.TOTALDEMAND IS NOT NULL AND r.SS_SOLAR_AVAILABILITY IS NOT NULL AND r.SS_WIND_AVAILABILITY IS NOT NULL
        """
    )
    # df[!, :TOTALDEMAND] .+= df[!, :DISPATCHABLELOAD]  # Adds the dispatchable load to the total demand to get the actual native demand
    df[!, :SETTLEMENTDATE] = ceil.(df[!, :SETTLEMENTDATE], resolution)
    sort!(df, :SETTLEMENTDATE)
    return @chain df begin
        groupby([:SETTLEMENTDATE, :REGIONID])
        combine(_, valuecols(_) .=> mean ∘ skipmissing; renamecols = false)
    end
end
