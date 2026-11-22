"""
    _nem_network(db; date_range, nemde = false, time_series_in_memory = true, kwargs...) -> (sys, units, gen_df)

Builds the NEM network without operation costs: buses, loads, branches, generators, batteries,
scheduled loads and area interfaces, with every generator's operation cost zero. Reads no ISP cost
table. `units` is the unit table over `date_range` (see [`read_units`](@ref)), and `gen_df` is the generator table the generators were built from, for
`_set_isp_generation_costs!`.

# Arguments
- `db`: The database connection.
- `date_range`: The half-open range of interval-ending stamps the units and interconnectors are
  resolved over.
- `nemde`: Build a NEMDE network: attach a [`NEMUnitData`](@ref) to every dispatch device and record
  each unit's [`NEMRegistration`](@ref).
- `time_series_in_memory`: Store time series in memory when `true`.
- `kwargs...`: Passed to the `PowerSystems.System` constructor.

# Returns
A tuple `(sys, units, gen_df)`.
"""
function _nem_network(db; date_range, nemde::Bool = false, time_series_in_memory = true, kwargs...)
    @info "parsing buses"
    interconnectors = read_interconnectors(db, date_range)
    bus_df = get_bus_dataframe(interconnectors)
    units = read_units(db, date_range)
    unit_df = _map_unit_technology(units)
    @info "parsing loads"
    loads_df = get_load_dataframe(bus_df)
    @info "parsing branches"
    branch_df = get_branch_dataframe(bus_df, interconnectors)
    @info "parsing generators"
    gen_df = get_generators_dataframe(bus_df, unit_df)
    @info "parsing batteries"
    batteries_df = get_batteries_dataframe(bus_df, unit_df)
    @info "parsing scheduled loads"
    scheduled_loads_df = get_scheduled_loads_dataframe(bus_df, units)

    @info "parsing interconnectors/area interchanges / transmission interface"
    interfaces_df = get_interfaces_dataframe(interconnectors)

    sys = System(BASE_POWER; time_series_in_memory = time_series_in_memory, kwargs...)
    _add_buses!(sys, bus_df)
    _add_loads!(sys, loads_df)
    _add_generation!(sys, gen_df; legacy_batteries = nemde)
    _add_branches!(sys, branch_df)
    _add_batteries!(sys, batteries_df)
    _add_scheduled_loads!(sys, scheduled_loads_df; nemde)
    _add_area_interfaces!(sys, interfaces_df)
    if nemde
        _attach_nem_unit_data!(sys)
        _set_registrations!(sys, units, read_loss_factors(db, date_range))
    end

    return sys, units, gen_df
end

"""
    _attach_nem_unit_data!(sys)

Attaches an empty [`NEMUnitData`](@ref) to every dispatch device of `sys`, available or not, so that
registrations, bids and unit conditions can be written to it.

# Arguments
- `sys`: The `PowerSystems.System` object.

# Returns
`nothing`.
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
    devices = [d for T in (Generator, ControllableLoad, Storage) for d in get_components(T, sys)]
    registrations = @chain units begin
        subset(:DUID => ByRow(in(Set(get_name.(devices)))))
        leftjoin(factors; on = :DUID)
        transform(:SCHEDULE_TYPE => ByRow(t -> get(_SCHEDULE_TYPES, t, missing)) => :schedule_type)
    end
    invalid = subset(
        registrations,
        [:GEN_LOSS_FACTOR, :LOAD_LOSS_FACTOR] => ByRow((g, l) -> ismissing(g) || ismissing(l)),
    )
    isempty(invalid) || throw(ArgumentError("No DUDETAILSUMMARY loss factor for $(first(invalid.DUID))."))
    unknown = subset(registrations, :schedule_type => ByRow(ismissing))
    isempty(unknown) ||
        throw(ArgumentError("$(first(unknown.DUID)) has an unknown SCHEDULE_TYPE $(repr(first(unknown.SCHEDULE_TYPE)))"))
    rows = Dict(String(r.DUID) => r for r in eachrow(registrations))
    for device in devices
        name = get_name(device)
        haskey(rows, name) || throw(ArgumentError("$name has no DUDETAILSUMMARY row, so it has no registration"))
        row = rows[name]
        set_registration!(
            device,
            NEMRegistration(;
                schedule_type = row.schedule_type, gen_loss_factor = row.GEN_LOSS_FACTOR,
                load_loss_factor = row.LOAD_LOSS_FACTOR, registered_from = row.REGISTERED_FROM,
                registered_until = row.REGISTERED_UNTIL, commissioned = row.STATUS == "COMMISSIONED",
            ),
        )
    end
    return
end


"""
    nem_network(db; date_range, time_series_in_memory = true, kwargs...) -> (sys, units)

Builds the NEM network without operation costs: buses, loads, branches, generators, batteries,
scheduled loads and area interfaces. Devices are stock PowerSystems types; each dispatch device
(the `NEM_DISPATCH_DEVICE_TYPES` components) carries a [`NEMUnitData`](@ref) with an empty
[`NEMOfferCost`](@ref). Reads no ISP cost table. `units` is the unit
table over `date_range` (see [`read_units`](@ref)).

# Arguments
- `db`: The database connection.
- `date_range`: The half-open range of interval-ending stamps the units and interconnectors are
  resolved over.
- `time_series_in_memory`: Store time series in memory when `true`.
- `kwargs...`: Passed to the `PowerSystems.System` constructor.

# Returns
A tuple `(sys, units)`.
"""
function nem_network(db; date_range, time_series_in_memory = true, kwargs...)
    sys, units, _ = _nem_network(db; date_range, nemde = true, time_series_in_memory, kwargs...)
    return sys, units
end

export nem_network
