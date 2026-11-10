"""
    _nem_network(db; time_series_in_memory = true, as_of = nothing, through = nothing, kwargs...) -> (sys, units, gen_df)

Builds the NEM network without operation costs: buses, loads, branches, generators, batteries,
scheduled loads and area interfaces, with every generator's operation cost zero. Reads no ISP cost
table. `units` is the unit table as of `as_of`, or over the window `[as_of, through]` (see
[`read_units`](@ref)), and `gen_df` is the generator table the generators were built from, for
`_set_isp_generation_costs!`.

# Arguments
- `db`: The database connection.
- `replay`: Build a replay network: attach a [`NEMUnitData`](@ref) to every dispatch device and record
  each unit's [`NEMRegistration`](@ref).
- `time_series_in_memory`: Store time series in memory when `true`.
- `as_of`: A `Date` or `DateTime` to resolve the unit and interconnector tables as of; `nothing`
  uses the latest cached version.
- `through`: The end of the unit window that starts at `as_of`; `nothing` builds the units in
  force at `as_of` only.
- `kwargs...`: Passed to the `PowerSystems.System` constructor.

# Returns
A tuple `(sys, units, gen_df)`.
"""
function _nem_network(db; replay::Bool = false, time_series_in_memory = true, as_of = nothing, through = nothing, kwargs...)
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
    _add_generation!(sys, gen_df)
    _add_branches!(sys, branch_df)
    _add_batteries!(sys, batteries_df)
    _add_scheduled_loads!(sys, scheduled_loads_df; replay)
    _add_area_interfaces!(sys, interfaces_df)
    if replay
        _attach_nem_unit_data!(sys)
        _set_registrations!(sys, units, read_loss_factors(db; as_of, through))
    end

    return sys, units, gen_df
end

"""
    _attach_nem_unit_data!(sys)

Attaches an empty [`NEMUnitData`](@ref) to every dispatch device of `sys`, available or not, so that
registrations, bids and unit conditions can be written to it.
"""
function _attach_nem_unit_data!(sys)
    for T in NEM_DISPATCH_DEVICE_TYPES, device in get_components(T, sys)
        attach_nem_unit_data!(sys, device)
    end
    return
end


const _SCHEDULE_TYPES = Dict(
    "SCHEDULED" => ScheduleType.SCHEDULED, "SEMI-SCHEDULED" => ScheduleType.SEMI_SCHEDULED,
    "NON-SCHEDULED" => ScheduleType.NON_SCHEDULED,
)

"""
    _set_registrations!(sys, units, factors)

Records on each generator, storage and controllable load of `sys` its [`NEMRegistration`](@ref), from
its row of `units` ([`read_units`](@ref)) and its loss factors ([`read_loss_factors`](@ref)). Throws an
`ArgumentError` naming a device with no unit row, a unit with no loss factor, or an unknown schedule type.
"""
function _set_registrations!(sys, units, factors)
    unit_rows = Dict(String(r.DUID) => r for r in eachrow(units))
    factor_rows = Dict(String(r.DUID) => r for r in eachrow(factors))
    for T in (Generator, ControllableLoad, Storage), device in get_components(T, sys)
        name = get_name(device)
        unit = get(unit_rows, name, nothing)
        isnothing(unit) && throw(ArgumentError("$name has no DUDETAILSUMMARY row, so it has no registration"))
        factor = get(factor_rows, name, nothing)
        (isnothing(factor) || ismissing(factor.GEN_LOSS_FACTOR) || ismissing(factor.LOAD_LOSS_FACTOR)) &&
            throw(ArgumentError("No DUDETAILSUMMARY loss factor for $name."))
        schedule = get(_SCHEDULE_TYPES, unit.SCHEDULE_TYPE, nothing)
        isnothing(schedule) && throw(ArgumentError("$name has an unknown SCHEDULE_TYPE $(repr(unit.SCHEDULE_TYPE))"))
        set_registration!(
            device,
            NEMRegistration(;
                schedule_type = schedule, gen_loss_factor = factor.GEN_LOSS_FACTOR,
                load_loss_factor = factor.LOAD_LOSS_FACTOR, registered_from = unit.REGISTERED_FROM,
                registered_until = unit.REGISTERED_UNTIL, commissioned = unit.STATUS == "COMMISSIONED",
            ),
        )
    end
    return
end


"""
    nem_network(db; time_series_in_memory = true, as_of = nothing, through = nothing, kwargs...) -> (sys, units)

Builds the NEM network without operation costs: buses, loads, branches, generators, batteries,
scheduled loads and area interfaces. Devices are stock PowerSystems types, each carrying a
[`NEMUnitData`](@ref) with an empty [`NEMOfferCost`](@ref). Reads no ISP cost table. `units` is the unit
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
    sys, units, _ = _nem_network(db; replay = true, time_series_in_memory, as_of, through, kwargs...)
    return sys, units
end

export nem_network
