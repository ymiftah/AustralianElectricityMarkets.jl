# The availability the NEMDE inputs were derived for, recorded as the last step of the stage.

const _NEMDE_AVAILABILITY_KEY = "nemde_unavailable_components"

# The `(type, name)` of every unavailable device and service of `sys`, sorted.
function _unavailable_components(sys::PSY.System)
    rows = Tuple{String, String}[]
    for c in PSY.get_components(c -> !PSY.get_available(c), PSY.Device, sys)
        push!(rows, (string(nameof(typeof(c))), PSY.get_name(c)))
    end
    for c in PSY.get_components(PSY.Service, sys)
        applicable(PSY.get_available, c) && !PSY.get_available(c) || continue
        push!(rows, (string(nameof(typeof(c))), PSY.get_name(c)))
    end
    return sort!(rows)
end


"""
    _set_nemde_availability!(sys::PSY.System) -> Nothing

Records the unavailable devices and services of `sys` in its `ext`, as plain data, so a later change of
availability can be refused by [`_check_nemde_availability`](@ref): the NEMDE inputs (FCAS effective offers,
tie-break membership, loss demand terms, constraint availability) were derived for this availability.

# Arguments
- `sys`: the system whose NEMDE inputs were just written.

# Returns
`nothing`.
"""
function _set_nemde_availability!(sys::PSY.System)
    get_ext(sys)[_NEMDE_AVAILABILITY_KEY] = [collect(r) for r in _unavailable_components(sys)]
    return
end


"""
    _check_nemde_availability(sys::PSY.System) -> Nothing

Throws when the availability of a device or service of `sys` differs from the one its NEMDE inputs were
derived for, naming every changed component.

# Arguments
- `sys`: a system built by `nem_system(db, NEMDEConfiguration(); date_range)`.

# Returns
`nothing`. Throws `ArgumentError` when `sys` carries no recorded availability or when it changed.
"""
function _check_nemde_availability(sys::PSY.System)
    recorded = get(get_ext(sys), _NEMDE_AVAILABILITY_KEY, nothing)
    isnothing(recorded) && throw(
        ArgumentError(
            "the system carries no NEMDE inputs; build it with nem_system(db, NEMDEConfiguration(); date_range)",
        ),
    )
    before = Set(Tuple{String, String}((String(r[1]), String(r[2]))) for r in recorded)
    now = Set(_unavailable_components(sys))
    before == now && return
    label(rows) = join(sort!(["$(t) $(n)" for (t, n) in rows]), ", ")
    changes = String[]
    isempty(setdiff(now, before)) || push!(changes, "made unavailable: $(label(setdiff(now, before)))")
    isempty(setdiff(before, now)) || push!(changes, "made available: $(label(setdiff(before, now)))")
    throw(
        ArgumentError(
            "the availability of the system changed after its NEMDE inputs were written ($(join(changes, "; "))). " *
                "Set availability before nem_system builds the NEMDE inputs, or rebuild the system.",
        ),
    )
end
