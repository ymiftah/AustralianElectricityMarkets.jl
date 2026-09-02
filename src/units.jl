using DataFrames

"""
    read_units(db)

Read commissioned generating unit metadata, mapping each unit's raw AEMO fuel/technology
source to `PowerSystems.PrimeMovers` (`TECHNOLOGY`) and `PowerSystems.ThermalFuels`
(`FUELTYPE`) values.

Wraps `AustralianElectricityMarketsData.read_units`, which returns the raw
`CO2E_ENERGY_SOURCE` string column — the enum mapping lives here, not in
`AustralianElectricityMarketsData`, since that package does not depend on PowerSystems.jl.

# Returns
- `DataFrame`: one row per commissioned `DUID`, including `TECHNOLOGY` and `FUELTYPE` columns.
"""
function read_units(db)
    dudetail = AustralianElectricityMarketsData.read_units(db)
    transform!(
        dudetail,
        :CO2E_ENERGY_SOURCE => ByRow(x -> AEMO_PM_MAPPING[x]) => :TECHNOLOGY,
        :CO2E_ENERGY_SOURCE => ByRow(x -> AEMO_FUEL_MAPPING[x]) => :FUELTYPE,
    )
    return dudetail
end

"""
    read_marginal_loss_factors(db, date_range) -> Dict{String, Float64}

Reads each unit's Marginal Loss Factor (`DUDETAILSUMMARY.TRANSMISSIONLOSSFACTOR`),
version-resolved over `date_range` the same way [`read_constraint_terms`](@ref) resolves
`DUDETAILSUMMARY`: `START_DATE <= last(date_range) AND (END_DATE IS NULL OR END_DATE >=
first(date_range))`. A `DUID` with more than one validity window overlapping `date_range`
(e.g. a mid-range TLF change) resolves to the row with the latest `START_DATE` - the version
in effect closest to the end of the requested window.

`DUDETAILSUMMARY.SECONDARY_TLF` is deliberately not read here: per AEMO's Electricity Data
Model Report, it is populated only for bidirectional units (BDUs, e.g. grid-scale batteries)
with dual TLFs, and gives the *generation*-component loss factor distinct from
`TRANSMISSIONLOSSFACTOR` (the load-component/primary factor; when `SECONDARY_TLF` is null,
`TRANSMISSIONLOSSFACTOR` applies to both). A single `TRANSMISSIONLOSSFACTOR` per `DUID` is
the right granularity for the non-BDU generators this reader targets; a future
BDU-aware refinement would need `SECONDARY_TLF` too.

Throws an `ArgumentError` when `DUDETAILSUMMARY` isn't cached at all.

# Arguments
- `db`: an `AEMDB` connection.
- `date_range`: the window the MLF must be valid over.

# Returns
`DUID => TRANSMISSIONLOSSFACTOR`.

# Example
```julia
mlfs = read_marginal_loss_factors(db, Date(2025, 1, 1):Date(2025, 1, 2))
mlfs["BW01"]
```
"""
function read_marginal_loss_factors(db, date_range)
    _table_is_cached(db, :DUDETAILSUMMARY) || throw(
        ArgumentError(
            "DUDETAILSUMMARY is not cached — run `populate(db, :DUDETAILSUMMARY, <from>, <to>)` first.",
        ),
    )
    start_date = first(date_range)
    end_date = last(date_range)
    table = read_hive(db, :DUDETAILSUMMARY)
    df = _query(
        db,
        """
        WITH raw AS (
            SELECT * FROM $table
            WHERE START_DATE <= ? AND (END_DATE IS NULL OR END_DATE >= ?)
            QUALIFY row_number() OVER (
                PARTITION BY DUID, START_DATE ORDER BY archive_month DESC
            ) = 1
        )
        SELECT DUID, TRY_CAST(TRANSMISSIONLOSSFACTOR AS DOUBLE) AS TRANSMISSIONLOSSFACTOR
        FROM raw
        QUALIFY row_number() OVER (
            PARTITION BY DUID ORDER BY START_DATE DESC
        ) = 1
        """,
        [end_date, start_date],
    )
    dropmissing!(df, :TRANSMISSIONLOSSFACTOR)
    return Dict(df.DUID .=> df.TRANSMISSIONLOSSFACTOR)
end
