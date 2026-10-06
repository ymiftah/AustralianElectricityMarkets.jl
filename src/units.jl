using DataFrames

"""
    read_units(db; as_of = nothing)

Read commissioned generating unit metadata, mapping each unit's raw AEMO fuel/technology
source to `PowerSystems.PrimeMovers` (`TECHNOLOGY`) and `PowerSystems.ThermalFuels`
(`FUELTYPE`) values.

Wraps `AustralianElectricityMarketsData.read_units`, which returns the raw
`CO2E_ENERGY_SOURCE` string column — the enum mapping lives here, not in
`AustralianElectricityMarketsData`, since that package does not depend on PowerSystems.jl.

# Arguments
- `db`: the database connection.
- `as_of`: a `Date` or `DateTime` to resolve the static unit tables as of (loss factors in force
  then), or `nothing` for the latest cached version.

# Returns
- `DataFrame`: one row per commissioned `DUID`, including `TECHNOLOGY` and `FUELTYPE` columns.
"""
function read_units(db; as_of = nothing)
    dudetail = AustralianElectricityMarketsData.read_units(db; as_of = as_of)
    transform!(
        dudetail,
        :CO2E_ENERGY_SOURCE => ByRow(x -> AEMO_PM_MAPPING[x]) => :TECHNOLOGY,
        :CO2E_ENERGY_SOURCE => ByRow(x -> AEMO_FUEL_MAPPING[x]) => :FUELTYPE,
    )
    return dudetail
end
