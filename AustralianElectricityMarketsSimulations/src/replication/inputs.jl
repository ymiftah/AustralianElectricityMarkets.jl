"""
One dispatch interval's NEMDE inputs, read from the NEMWEB archive.

Every field is a historical measurement for `settlement_date`.
`settlement_date` is the **end** of the interval, matching NEMWEB convention.

# Fields
- `settlement_date`: interval end.
- `initial_mw`: `DUID -> INITIALMW`, the metered output at interval start (the ramp base).
- `demand`: `REGIONID -> TOTALDEMAND`.
- `uigf`: `DUID -> UIGF`, semi-scheduled weather forecast. Absent for scheduled units.
- `interconnector_flows`: `INTERCONNECTORID -> MWFLOW`, the flow NEMDE targeted for the interval
  (the metered flow at interval start is `METEREDMWFLOW`).
- `intervention`: 0 for the pricing run, 1 for the physical run.
"""
struct IntervalInputs
    settlement_date::DateTime
    initial_mw::Dict{String, Float64}
    demand::Dict{String, Float64}
    uigf::Dict{String, Float64}
    interconnector_flows::Dict{String, Float64}
    intervention::Int
end

"""
    read_interval_inputs(db, settlement_date; intervention = 0)

Reads every NEMWEB input needed to reconstruct one dispatch interval into an
[`IntervalInputs`](@ref).

# Arguments
- `db`: an `AEMDB` connection.
- `settlement_date`: the interval end (`DateTime`).
- `intervention`: 0 for the pricing run, 1 for the physical run.

# Returns
An [`IntervalInputs`](@ref).
"""
function read_interval_inputs(db, settlement_date::DateTime; intervention::Integer = 0)
    load = _read_dispatch_load(db, settlement_date, intervention)
    initial_mw = Dict{String, Float64}(row.DUID => row.INITIALMW for row in eachrow(load) if !ismissing(row.INITIALMW))

    regionsum = _read_region_sum(db, settlement_date, intervention)
    demand = Dict{String, Float64}(row.REGIONID => row.TOTALDEMAND for row in eachrow(regionsum) if !ismissing(row.TOTALDEMAND))

    uigf = read_uigf_as_dict(db, settlement_date, intervention)

    flows = _read_interconnector_flows(db, settlement_date, intervention)

    return IntervalInputs(
        settlement_date, initial_mw, demand, uigf, flows, Int(intervention),
    )
end

# Some cached partitions predate a table gaining an INTERVENTION column (see the identical
# note above `_intervention_where` in `src/parser.jl`) - referencing a column absent from
# *every* file in a `read_hive` glob is a hard DuckDB Binder Error, so every helper below
# checks the resolved schema first, mirroring the rest of this codebase's readers.

"""
    _read_dispatch_load(db, settlement_date, intervention)

Reads `DISPATCHLOAD.INITIALMW` for every `DUID` dispatched at `settlement_date`, deduplicating
archive-month overlap. One row per `DUID`.
"""
function _read_dispatch_load(db, settlement_date::DateTime, intervention::Integer)
    return _read_published(db, :DISPATCHLOAD, "DUID", ("INITIALMW",), settlement_date, intervention)
end

"""
    _read_region_sum(db, settlement_date, intervention)

Reads `DISPATCHREGIONSUM.TOTALDEMAND` for every `REGIONID` at `settlement_date`, deduplicating
archive-month overlap. One row per `REGIONID`.
"""
function _read_region_sum(db, settlement_date::DateTime, intervention::Integer)
    return _read_published(db, :DISPATCHREGIONSUM, "REGIONID", ("TOTALDEMAND",), settlement_date, intervention)
end

"""
    read_uigf_as_dict(db, settlement_date, intervention)

Reads `DISPATCHLOAD.UIGF` — the semi-scheduled weather ceiling NEMDE actually applied that
interval — as `DUID -> MW`. A `Dict` view over [`read_uigf`](@ref)'s single-interval method, so
the SQL lives in one place. Only non-negative values are kept: `UIGF` is `NULL` for scheduled
units, and a negative ceiling is not a physical bound.
"""
function read_uigf_as_dict(db, settlement_date::DateTime, intervention::Integer)
    df = read_uigf(db, settlement_date; intervention = intervention)
    return Dict{String, Float64}(row.DUID => row.UIGF for row in eachrow(df) if row.UIGF >= 0.0)
end

"""
    _read_interconnector_flows(db, settlement_date, intervention)

Reads the target `DISPATCHINTERCONNECTORRES.MWFLOW` for every `INTERCONNECTORID` at `settlement_date`.
Throws an `ArgumentError` when `DISPATCHINTERCONNECTORRES` isn't cached: a replicated
interval silently missing every interconnector flow is indistinguishable from one where every
interconnector was genuinely at zero flow, which is the same failure class as
[`read_fcas_requirements`](@ref)'s empty-cache case — both are now hard errors rather than a
tolerated partial cache.
"""
function _read_interconnector_flows(db, settlement_date::DateTime, intervention::Integer)
    df = _read_published(
        db, :DISPATCHINTERCONNECTORRES, "INTERCONNECTORID", ("MWFLOW",), settlement_date, intervention,
    )
    return Dict{String, Float64}(row.INTERCONNECTORID => row.MWFLOW for row in eachrow(df) if !ismissing(row.MWFLOW))
end

"""
    read_published_interval(db, settlement_date; intervention = 0)

Reads AEMO's published outcome for one dispatch interval.

# Arguments
- `db`: an `AEMDB` connection.
- `settlement_date`: the `SETTLEMENTDATE` of the interval (`DateTime`).
- `intervention`: 0 for the pricing run, 1 for the physical run.

# Returns
A `NamedTuple` of `DataFrame`s: `dispatch` (`DUID`, `TOTALCLEARED`), `interconnectors`
(`INTERCONNECTORID`, `MWFLOW`, `MWLOSSES`), `prices` (`REGIONID`, `RRP`, `ROP`) and `fcas_prices`
(`SETTLEMENTDATE`, `REGIONID`, `BIDTYPE`, `RRP`, `ROP`).
"""
function read_published_interval(db, settlement_date::DateTime; intervention::Integer = 0)
    interval = settlement_date:DISPATCH_INTERVAL:(settlement_date + DISPATCH_INTERVAL)
    return (;
        dispatch = _read_published(db, :DISPATCHLOAD, "DUID", ("TOTALCLEARED",), settlement_date, intervention),
        interconnectors = _read_published(
            db, :DISPATCHINTERCONNECTORRES, "INTERCONNECTORID", ("MWFLOW", "MWLOSSES"),
            settlement_date, intervention,
        ),
        prices = select(read_prices(db, interval; intervention = intervention), :REGIONID, :RRP, :ROP),
        fcas_prices = select(
            read_fcas_prices(db, interval; intervention = intervention), :SETTLEMENTDATE, :REGIONID, :BIDTYPE, :RRP, :ROP,
        ),
    )
end

# One row per `key` at `settlement_date`, deduplicating archive-month overlap.
function _read_published(db, table_name::Symbol, key::String, columns, settlement_date::DateTime, intervention::Integer)
    AustralianElectricityMarkets._table_is_cached(db, table_name) || throw(
        ArgumentError(
            "$table_name is not cached for $settlement_date: run " *
                "`populate(db, :$table_name, <from>, <to>)` first.",
        ),
    )
    table = read_hive(db, table_name)
    schema = names(AustralianElectricityMarkets._query(db, "SELECT * FROM $table LIMIT 0"))
    params = Any[settlement_date]
    AustralianElectricityMarkets._push_intervention!(params, schema, intervention)
    select_list = join([key; ["TRY_CAST($c AS DOUBLE) AS $c" for c in columns]], ", ")
    return AustralianElectricityMarkets._query(
        db,
        """
        SELECT $select_list
        FROM $table
        WHERE SETTLEMENTDATE = ? $(AustralianElectricityMarkets._intervention_where(schema))
        QUALIFY row_number() OVER (PARTITION BY $key ORDER BY archive_month DESC) = 1
        """,
        params,
    )
end

"""
    read_constraint_flags(db, interval_range; intervention = 0)

Reads, per dispatch interval, whether a network generic constraint bound and whether any
constraint was violated, from `DISPATCHCONSTRAINT`. FCAS requirement constraints (`F_` ids) do
not count as binding.

# Arguments
- `db`: an `AEMDB` connection.
- `interval_range`: the `SETTLEMENTDATE`s to read, as a `StepRange{DateTime}`.
- `intervention`: 0 for the pricing run, 1 for the physical run.

# Returns
A `DataFrame` with columns `SETTLEMENTDATE`, `binding` and `violated`, one row per interval that
has any constraint row.
"""
function read_constraint_flags(db, interval_range::StepRange{DateTime}; intervention::Integer = 0)
    table = read_hive(db, :DISPATCHCONSTRAINT)
    schema = names(AustralianElectricityMarkets._query(db, "SELECT * FROM $table LIMIT 0"))
    params = Any[first(interval_range), last(interval_range)]
    AustralianElectricityMarkets._push_intervention!(params, schema, intervention)
    return AustralianElectricityMarkets._query(
        db,
        """
        SELECT SETTLEMENTDATE,
               COALESCE(bool_or(TRY_CAST(MARGINALVALUE AS DOUBLE) <> 0 AND NOT starts_with(CONSTRAINTID, 'F_')), false) AS binding,
               $("VIOLATIONDEGREE" in schema ? "COALESCE(bool_or(TRY_CAST(VIOLATIONDEGREE AS DOUBLE) > 0), false)" : "false") AS violated
        FROM $table
        WHERE SETTLEMENTDATE BETWEEN ? AND ? $(AustralianElectricityMarkets._intervention_where(schema))
        GROUP BY SETTLEMENTDATE
        ORDER BY SETTLEMENTDATE
        """,
        params,
    )
end

"""
    read_complementary_slackness(db, interval_range; intervention = 0, price_tolerance = 0.05,
                                 mw_tolerance = 1.0)

Checks AEMO's published energy dispatch against each unit's own offer. A band priced below
`RRP x MLF` should be fully cleared and a band priced above it uncleared, so the price-implied
dispatch (strictly-below and at-or-below bands, clipped to availability, the semi-scheduled
ceiling and the five-minute ramp window) should bracket `TOTALCLEARED`. Generation offers of
units with ramp rates are checked; fast-start units (`DISPATCHMODE = 2`) are skipped. A unit
outside the bracket is held on or off by something other than price.

# Arguments
- `db`: an `AEMDB` connection with `DISPATCHLOAD`, `DISPATCHPRICE`, `DUDETAILSUMMARY`,
  `BIDPEROFFER_D` and `BIDDAYOFFER_D` cached.
- `interval_range`: the `SETTLEMENTDATE`s to check, as a `StepRange{DateTime}`.
- `intervention`: 0 for the pricing run, 1 for the physical run.
- `price_tolerance`: dollars per MWh of band around `RRP x MLF` treated as marginal.
- `mw_tolerance`: MW outside the bracket above which a unit counts as violating.

# Returns
A `DataFrame` with one row per `(SETTLEMENTDATE, REGIONID)`: `n_units` checked, `n_violating`
units, `violation_mw` (sum of the distances outside the bracket) and `cleared_mw`.
"""
function read_complementary_slackness(
        db, interval_range::StepRange{DateTime};
        intervention::Integer = 0, price_tolerance::Real = 0.05, mw_tolerance::Real = 1.0,
    )
    aem = AustralianElectricityMarkets
    load = read_hive(db, :DISPATCHLOAD)
    load_schema = names(aem._query(db, "SELECT * FROM $load LIMIT 0"))
    price = read_hive(db, :DISPATCHPRICE)
    price_schema = names(aem._query(db, "SELECT * FROM $price LIMIT 0"))
    summary_table = read_hive(db, :DUDETAILSUMMARY)
    summary_schema = names(aem._query(db, "SELECT * FROM $summary_table LIMIT 0"))
    loss_factor(col) = col in summary_schema ? "COALESCE(TRY_CAST($col AS DOUBLE), 1.0)" : "1.0"
    mlf = "$(loss_factor("TRANSMISSIONLOSSFACTOR")) * $(loss_factor("DISTRIBUTIONLOSSFACTOR"))"
    first_t, last_t = first(interval_range), last(interval_range)
    params = Any[first_t, last_t]
    aem._push_intervention!(params, load_schema, intervention)
    append!(params, Any[first_t, last_t])
    aem._push_intervention!(params, price_schema, intervention)
    bid_days = (Date(first_t) - Day(1), Date(last_t) + Day(1))
    append!(params, Any[bid_days..., first_t, last_t, bid_days...])
    bands = 1:10
    price_bands = join(("TRY_CAST(PRICEBAND$k AS DOUBLE) AS PRICEBAND$k" for k in bands), ", ")
    band_avail = join(("TRY_CAST(BANDAVAIL$k AS DOUBLE) AS BANDAVAIL$k" for k in bands), ", ")
    strict = join(("CASE WHEN b.PRICEBAND$k < thr - $price_tolerance THEN o.BANDAVAIL$k ELSE 0 END" for k in bands), " + ")
    inclusive = join(("CASE WHEN b.PRICEBAND$k <= thr + $price_tolerance THEN o.BANDAVAIL$k ELSE 0 END" for k in bands), " + ")
    return aem._query(
        db,
        """
        WITH dl AS (
            SELECT SETTLEMENTDATE, DUID, TRY_CAST(INITIALMW AS DOUBLE) AS im, TRY_CAST(TOTALCLEARED AS DOUBLE) AS tc,
                   TRY_CAST(RAMPUPRATE AS DOUBLE) AS ru, TRY_CAST(RAMPDOWNRATE AS DOUBLE) AS rd,
                   TRY_CAST(AVAILABILITY AS DOUBLE) AS av, TRY_CAST(UIGF AS DOUBLE) AS uigf,
                   $("DISPATCHMODE" in load_schema ? "TRY_CAST(DISPATCHMODE AS INTEGER)" : "0") AS dm
            FROM $load
            WHERE SETTLEMENTDATE BETWEEN ? AND ? $(aem._intervention_where(load_schema))
            QUALIFY row_number() OVER (PARTITION BY SETTLEMENTDATE, DUID ORDER BY archive_month DESC) = 1
        ),
        pr AS (
            SELECT SETTLEMENTDATE, REGIONID, TRY_CAST(RRP AS DOUBLE) AS rrp
            FROM $price
            WHERE SETTLEMENTDATE BETWEEN ? AND ? $(aem._intervention_where(price_schema))
            QUALIFY row_number() OVER (PARTITION BY SETTLEMENTDATE, REGIONID ORDER BY archive_month DESC) = 1
        ),
        du AS (
            SELECT DUID, REGIONID,
                   $mlf AS mlf
            FROM $summary_table
            QUALIFY row_number() OVER (PARTITION BY DUID ORDER BY archive_month DESC, START_DATE DESC) = 1
        ),
        base AS (
            SELECT dl.*, du.REGIONID, pr.rrp * du.mlf AS thr
            FROM dl JOIN du USING (DUID) JOIN pr ON pr.SETTLEMENTDATE = dl.SETTLEMENTDATE AND pr.REGIONID = du.REGIONID
            WHERE dl.ru IS NOT NULL AND dl.rd IS NOT NULL AND dl.tc IS NOT NULL AND COALESCE(dl.dm, 0) <> 2
        ),
        offer AS (
            SELECT DUID, SETTLEMENTDATE AS bid_day, INTERVAL_DATETIME, VERSIONNO, TRY_CAST(MAXAVAIL AS DOUBLE) AS maxavail,
                   $band_avail
            FROM $(read_hive(db, :BIDPEROFFER_D))
            WHERE BIDTYPE = 'ENERGY' AND DIRECTION = 'GEN' AND SETTLEMENTDATE BETWEEN ? AND ?
              AND INTERVAL_DATETIME BETWEEN ? AND ?
            QUALIFY row_number() OVER (PARTITION BY DUID, INTERVAL_DATETIME ORDER BY VERSIONNO DESC, archive_month DESC) = 1
        ),
        day AS (
            SELECT DUID, SETTLEMENTDATE, VERSIONNO, $price_bands
            FROM $(read_hive(db, :BIDDAYOFFER_D))
            WHERE BIDTYPE = 'ENERGY' AND DIRECTION = 'GEN' AND SETTLEMENTDATE BETWEEN ? AND ?
            QUALIFY row_number() OVER (PARTITION BY DUID, SETTLEMENTDATE, VERSIONNO ORDER BY archive_month DESC) = 1
        ),
        checked AS (
            SELECT base.SETTLEMENTDATE, base.REGIONID, base.tc, base.im, base.ru, base.rd,
                   LEAST(base.av, o.maxavail, COALESCE(base.uigf, 1e9)) AS cap,
                   $strict AS strict_mw, $inclusive AS incl_mw
            FROM base
            JOIN offer o ON o.DUID = base.DUID AND o.INTERVAL_DATETIME = base.SETTLEMENTDATE
            JOIN day b ON b.DUID = o.DUID AND b.SETTLEMENTDATE = o.bid_day AND b.VERSIONNO = o.VERSIONNO
        ),
        windowed AS (
            SELECT SETTLEMENTDATE, REGIONID, tc,
                   GREATEST(im - rd / 12.0, LEAST(im + ru / 12.0, LEAST(strict_mw, cap))) AS lo,
                   GREATEST(im - rd / 12.0, LEAST(im + ru / 12.0, LEAST(incl_mw, cap))) AS hi
            FROM checked
        )
        SELECT SETTLEMENTDATE, REGIONID, count(*) AS n_units,
               sum((GREATEST(lo - tc, tc - hi, 0) > $mw_tolerance)::INT) AS n_violating,
               sum(GREATEST(lo - tc, tc - hi, 0)) AS violation_mw, sum(tc) AS cleared_mw
        FROM windowed
        GROUP BY SETTLEMENTDATE, REGIONID
        ORDER BY SETTLEMENTDATE, REGIONID
        """,
        params,
    )
end
