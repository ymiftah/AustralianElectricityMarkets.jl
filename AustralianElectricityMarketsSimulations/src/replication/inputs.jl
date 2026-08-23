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

    uigf = _read_uigf(db, settlement_date, intervention)

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
    table = read_hive(db, :DISPATCHLOAD)
    schema = names(AustralianElectricityMarkets._query(db, "SELECT * FROM $table LIMIT 0"))
    params = Any[settlement_date]
    AustralianElectricityMarkets._push_intervention!(params, schema, intervention)
    return AustralianElectricityMarkets._query(
        db,
        """
        SELECT DUID, TRY_CAST(INITIALMW AS DOUBLE) AS INITIALMW
        FROM $table
        WHERE SETTLEMENTDATE = ? $(AustralianElectricityMarkets._intervention_where(schema))
        QUALIFY row_number() OVER (
            PARTITION BY DUID ORDER BY archive_month DESC
        ) = 1
        """,
        params,
    )
end

"""
    _read_region_sum(db, settlement_date, intervention)

Reads `DISPATCHREGIONSUM.TOTALDEMAND` for every `REGIONID` at `settlement_date`, deduplicating
archive-month overlap. One row per `REGIONID`.
"""
function _read_region_sum(db, settlement_date::DateTime, intervention::Integer)
    table = read_hive(db, :DISPATCHREGIONSUM)
    schema = names(AustralianElectricityMarkets._query(db, "SELECT * FROM $table LIMIT 0"))
    params = Any[settlement_date]
    AustralianElectricityMarkets._push_intervention!(params, schema, intervention)
    return AustralianElectricityMarkets._query(
        db,
        """
        SELECT REGIONID, TRY_CAST(TOTALDEMAND AS DOUBLE) AS TOTALDEMAND
        FROM $table
        WHERE SETTLEMENTDATE = ? $(AustralianElectricityMarkets._intervention_where(schema))
        QUALIFY row_number() OVER (
            PARTITION BY REGIONID ORDER BY archive_month DESC
        ) = 1
        """,
        params,
    )
end

"""
    _read_uigf(db, settlement_date, intervention)

Reads `DISPATCHLOAD.UIGF` — the semi-scheduled weather ceiling NEMDE actually applied that
interval — as `DUID -> MW`. A `Dict` view over [`read_uigf`](@ref)'s single-interval method, so
the SQL lives in one place. Only non-negative values are kept: `UIGF` is `NULL` for scheduled
units, and a negative ceiling is not a physical bound.
"""
function _read_uigf(db, settlement_date::DateTime, intervention::Integer)
    df = read_uigf(db, settlement_date; intervention = intervention)
    return Dict{String, Float64}(row.DUID => row.UIGF for row in eachrow(df) if row.UIGF >= 0.0)
end

"""
    _read_interconnector_flows(db, settlement_date, intervention)

Reads `DISPATCHINTERCONNECTORRES.MWFLOW` for every `INTERCONNECTORID` at `settlement_date`.
Returns an empty `Dict` (rather than raising) when `DISPATCHINTERCONNECTORRES` isn't cached,
matching [`read_constraint_fcas_requirements`](@ref)'s tolerance of a partially-populated cache.
"""
function _read_interconnector_flows(db, settlement_date::DateTime, intervention::Integer)
    AustralianElectricityMarkets._table_is_cached(db, :DISPATCHINTERCONNECTORRES) ||
        return Dict{String, Float64}()
    table = read_hive(db, :DISPATCHINTERCONNECTORRES)
    schema = names(AustralianElectricityMarkets._query(db, "SELECT * FROM $table LIMIT 0"))
    params = Any[settlement_date]
    AustralianElectricityMarkets._push_intervention!(params, schema, intervention)
    df = AustralianElectricityMarkets._query(
        db,
        """
        SELECT INTERCONNECTORID, TRY_CAST(MWFLOW AS DOUBLE) AS MWFLOW
        FROM $table
        WHERE SETTLEMENTDATE = ? $(AustralianElectricityMarkets._intervention_where(schema))
        QUALIFY row_number() OVER (
            PARTITION BY INTERCONNECTORID ORDER BY archive_month DESC
        ) = 1
        """,
        params,
    )
    return Dict{String, Float64}(row.INTERCONNECTORID => row.MWFLOW for row in eachrow(df) if !ismissing(row.MWFLOW))
end
