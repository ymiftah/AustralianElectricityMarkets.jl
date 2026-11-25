# The availability of the built GenericConstraints, decided from the dispatch intervals and the contributing devices.


# Whether `constraint` is invoked at some of `stamps`: its static flag, or a nonzero point of its invoked series.
function _invoked_at_any(constraint::GenericConstraint, stamps)
    key = constraint.invoked
    key isa Bool && return key
    values = IS.get_time_series_values(constraint, key; start_time = first(stamps), len = length(stamps))
    return any(!iszero, values)
end


# The contributing devices of every service of `sys`, by service UUID, from one pass over the devices.
function _contributing_device_index(sys::PSY.System)
    index = Dict{Base.UUID, Vector{PSY.Device}}()
    for device in PSY.get_components(PSY.Device, sys)
        PSY.supports_services(device) || continue
        for service in PSY.get_services(device)
            push!(get!(Vector{PSY.Device}, index, IS.get_uuid(service)), device)
        end
    end
    return index
end


# Why `constraint` cannot bind over `stamps`, or `nothing` when it can. A constraint with no contributing
# device is not unavailable for lack of one. `index` is the `_contributing_device_index` of the system.
function _constraint_unavailable_reason(index, constraint::GenericConstraint, stamps)
    _invoked_at_any(constraint, stamps) || return :never_invoked
    devices = get(index, IS.get_uuid(constraint), PSY.Device[])
    isempty(devices) || any(PSY.get_available, devices) || return :no_available_device
    return nothing
end


"""
    _set_constraint_availability!(sys::PSY.System) -> Nothing

Sets each `GenericConstraint` of `sys` unavailable when it cannot bind over the dispatch intervals of `sys`:
`:never_invoked` when its invoked series is zero at every interval (or its static `invoked::Bool` is `false`),
else `:no_available_device` when it has contributing devices and none is available. The unavailable constraints
are recorded in the build report, as [`get_unavailable_constraints`](@ref) reports them. A repeat call re-decides
every constraint and replaces the recorded rows; it never makes an unavailable constraint available again.
Device availability must be final before the call.

# Arguments
- `sys`: the system built by [`nem_system`](@ref).

# Returns
`nothing`.
"""
function _set_constraint_availability!(sys::PSY.System)
    stamps = _dispatch_interval_stamps(sys)
    # A series of one point has no dispatch interval, so no constraint is decided.
    isempty(stamps) && return
    constraints = sort!(collect(PSY.get_components(GenericConstraint, sys)); by = PSY.get_name)
    isempty(constraints) && return
    rows = @NamedTuple{constraint::String, reason::String}[]
    index = _contributing_device_index(sys)
    for constraint in constraints
        reason = _constraint_unavailable_reason(index, constraint, stamps)
        isnothing(reason) && continue
        PSY.set_available!(constraint, false)
        push!(rows, (constraint = PSY.get_name(constraint), reason = String(reason)))
    end
    report = get_build_report(sys)
    set_build_report!(
        sys,
        NEMBuildReport(;
            skipped_constraints = report.skipped_constraints,
            missing_constraint_intervals = report.missing_constraint_intervals,
            defaulted_constraint_weights = report.defaulted_constraint_weights,
            dropped_terms = report.dropped_terms,
            unavailable_constraints = DataFrame(rows),
        ),
    )
    return
end
