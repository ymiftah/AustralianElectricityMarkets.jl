"""
    nem_system(db; as_of = nothing)

Assembles a `PowerSystems.System` object from the database.

# Arguments
- `db`: The database connection.
- `as_of`: a `Date` or `DateTime` to resolve the unit and interconnector tables as of (see
  [`read_units`](@ref)); `nothing` (the default) uses the latest cached version.

# Returns
A `PowerSystems.System` object.

# Example
```julia
db = aem_connect()
sys = nem_system(db)
println(sys)
```
"""
function nem_system(db; kwargs...)
    sys, _ = _regional_system(db; kwargs...)
    return sys
end


function _regional_system(db; kwargs...)
    sys, units, gen_df = _nem_network(db; kwargs...)
    _set_isp_generation_costs!(sys, gen_df)
    return sys, units
end


"""
    table_requirements(::RegionalNetworkConfiguration)


    :INTERCONNECTOR,
    :INTERCONNECTORCONSTRAINT,
    :DISPATCHREGIONSUM,
    :DUDETAIL,
    :DUDETAILSUMMARY,
    :STATION,
    :STATIONOPERATINGSTATUS,
    :GENUNITS,
    :DUALLOC,
    :BIDDAYOFFER_D,
    :BIDPEROFFER_D,
"""
AustralianElectricityMarkets.table_requirements(::RegionalNetworkConfiguration) = [
    :INTERCONNECTOR,
    :INTERCONNECTORCONSTRAINT,
    :DISPATCHREGIONSUM,
    :DUDETAIL,
    :DUDETAILSUMMARY,
    :STATION,
    :STATIONOPERATINGSTATUS,
    :GENUNITS,
    :DUALLOC,
    :BIDDAYOFFER_D,
    :BIDPEROFFER_D,
    :DISPATCHLOAD,
]


AustralianElectricityMarkets.nem_system(db, ::RegionalNetworkConfiguration; kwargs...) = nem_system(db; kwargs...)


export RegionalNetworkConfiguration
