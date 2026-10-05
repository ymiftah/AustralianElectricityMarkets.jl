"""
One dispatch interval's NEMDE inputs, read from the NEMWEB archive.

Every field is a historical measurement for `settlement_date`.
`settlement_date` is the **end** of the interval, matching NEMWEB convention.

# Fields
- `settlement_date`: interval end.
- `initial_mw`: `DUID -> INITIALMW`, the metered output at interval start (the ramp base).
- `demand`: `REGIONID -> TOTALDEMAND`.
- `uigf`: `DUID -> UIGF`, semi-scheduled weather forecast. Absent for scheduled units.
- `interconnector_flows`: `INTERCONNECTORID -> MWFLOW` at interval start.
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

Reads `DISPATCHINTERCONNECTORRES.MWFLOW` for every `INTERCONNECTORID` at `settlement_date`.
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
