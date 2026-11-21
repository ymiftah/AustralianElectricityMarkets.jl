# TODO This should live in `@network_configurations`


"""
    _base_system(db; date_range, kwargs...)

Assembles the energy-only regional `PowerSystems.System` built from the database, as
[`RegionalNetworkConfiguration`](@ref) returns it.

# Arguments
- `db`: The database connection.
- `date_range`: the half-open range of interval-ending stamps the units and interconnectors are
  resolved over (see [`read_units`](@ref)).
- `kwargs...`: Passed to the `PowerSystems.System` constructor.

# Returns
A `PowerSystems.System` object.

# Example
```julia
db = aem_connect()
sys = nem_system(db, RegionalNetworkConfiguration(); date_range = DateTime(2025, 1, 1):Minute(5):DateTime(2025, 1, 2))
println(sys)
```
"""
function _base_system(db; date_range, kwargs...)
    sys, _ = _regional_system(db; date_range, kwargs...)
    return sys
end


function _regional_system(db; date_range, kwargs...)
    sys, units, gen_df = _nem_network(db; date_range, kwargs...)
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


AustralianElectricityMarkets.nem_system(db, ::RegionalNetworkConfiguration; date_range, kwargs...) = _base_system(db; date_range, kwargs...)
