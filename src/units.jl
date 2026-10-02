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
