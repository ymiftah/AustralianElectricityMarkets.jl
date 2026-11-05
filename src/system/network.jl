"""
    _nem_network(db; time_series_in_memory = true, as_of = nothing, through = nothing, kwargs...) -> (sys, units, gen_df)

Builds the NEM network without operation costs: buses, loads, branches, generators, batteries,
scheduled loads and area interfaces, with every generator's operation cost zero. Reads no ISP cost
table. `units` is the unit table as of `as_of`, or over the window `[as_of, through]` (see
[`read_units`](@ref)), and `gen_df` is the generator table the generators were built from, for
`_set_isp_generation_costs!`.

# Arguments
- `db`: The database connection.
- `nem_types`: Build the NEM device types ([`NEMThermalGen`](@ref) and the others, with an empty
  [`NEMOfferCost`](@ref)) in place of the stock PowerSystems types.
- `time_series_in_memory`: Store time series in memory when `true`.
- `as_of`: A `Date` or `DateTime` to resolve the unit and interconnector tables as of; `nothing`
  uses the latest cached version.
- `through`: The end of the unit window that starts at `as_of`; `nothing` builds the units in
  force at `as_of` only.
- `kwargs...`: Passed to the `PowerSystems.System` constructor.

# Returns
A tuple `(sys, units, gen_df)`.
"""
function _nem_network(db; nem_types::Bool = false, time_series_in_memory = true, as_of = nothing, through = nothing, kwargs...)
    @info "parsing buses"
    interconnectors = read_interconnectors(db; as_of = as_of)
    bus_df = _bus_dataframe(interconnectors)
    units = read_units(db; as_of = as_of, through = through)
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
    _add_generation!(sys, gen_df; nem_types)
    _add_branches!(sys, branch_df)
    _add_batteries!(sys, batteries_df; nem_types)
    _add_scheduled_loads!(sys, scheduled_loads_df; nem_types)
    _add_area_interfaces!(sys, interfaces_df)

    return sys, units, gen_df
end


"""
    nem_network(db; time_series_in_memory = true, as_of = nothing, through = nothing, kwargs...) -> (sys, units)

Builds the NEM network without operation costs: buses, loads, branches, generators, batteries,
scheduled loads and area interfaces. Devices are the NEM types ([`NEMThermalGen`](@ref) and the
others), each with an empty [`NEMOfferCost`](@ref). Reads no ISP cost table. `units` is the unit
table as of `as_of`, or over the window `[as_of, through]` (see [`read_units`](@ref)).

# Arguments
- `db`: The database connection.
- `time_series_in_memory`: Store time series in memory when `true`.
- `as_of`: A `Date` or `DateTime` to resolve the unit and interconnector tables as of; `nothing`
  uses the latest cached version.
- `through`: The end of the unit window that starts at `as_of`; `nothing` builds the units in
  force at `as_of` only.
- `kwargs...`: Passed to the `PowerSystems.System` constructor.

# Returns
A tuple `(sys, units)`.
"""
function nem_network(db; time_series_in_memory = true, as_of = nothing, through = nothing, kwargs...)
    sys, units, _ = _nem_network(db; nem_types = true, time_series_in_memory, as_of, through, kwargs...)
    return sys, units
end

export nem_network
