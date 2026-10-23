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
function nem_system(db; time_series_in_memory = true, as_of = nothing, kwargs...)
    @info "parsing buses"
    bus_df = get_bus_dataframe(db)
    interconnectors = read_interconnectors(db; as_of = as_of)
    units = read_units(db; as_of = as_of)
    @info "parsing loads"
    loads_df = get_load_dataframe(bus_df)
    @info "parsing branches"
    branch_df = get_branch_dataframe(bus_df, interconnectors)
    @info "parsing generators"
    gen_df = get_generators_dataframe(bus_df, units)
    @info "parsing batteries"
    batteries_df = get_batteries_dataframe(bus_df, units)
    @info "parsing scheduled loads"
    scheduled_loads_df = get_scheduled_loads_dataframe(bus_df, units)

    @info "parsing interconnectors/area interchanges / transmission interface"
    interfaces_df = get_interfaces_dataframe(interconnectors)

    sys = System(BASE_POWER; time_series_in_memory = time_series_in_memory, kwargs...)
    _add_buses!(sys, bus_df)
    _add_loads!(sys, loads_df)
    _add_generation!(sys, gen_df)
    _add_branches!(sys, branch_df)
    _add_batteries!(sys, batteries_df)
    _add_scheduled_loads!(sys, scheduled_loads_df)
    _add_area_interfaces!(sys, interfaces_df)

    return sys
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
