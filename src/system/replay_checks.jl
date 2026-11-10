# TODO rename this is a check against the nemde configuration, it should be named nemde_checks.jl

# The typed records every NEM dispatch device must carry, with the name each is reported by.
const _NEM_DEVICE_RECORDS = (
    (get_registration, "registration"), (get_telemetry, "telemetry"), (get_observed_state, "observed state"),
)


"""
    _check_nemde_replay_inputs(sys::PSY.System) -> Nothing

Verifies that `sys` holds every input a NEMDE dispatch replay reads: the typed records of every NEM
dispatch device, a constraint build report with nothing missing, defaulted, skipped or dropped, and
two directional links with a bid and observed state on every MNSP.

# Arguments
- `sys`: the `System` to check.

# Returns
`Nothing`. Throws an `ArgumentError` naming the offenders in the first failing part and how to supply
them.
"""
function _check_nemde_replay_inputs(sys::PSY.System)
    _check_nemde_device_records(sys)
    _check_nemde_constraint_report(sys)
    _check_nemde_mnsp_structure(sys)
    return
end


# Every NEM dispatch device carries its registration, telemetry and observed state.
function _check_nemde_device_records(sys)
    missing_inputs = String[]
    _foreach_nem_dispatch_device(sys) do device
        for (getter, what) in _NEM_DEVICE_RECORDS
            try
                getter(device)
            catch error
                error isa ArgumentError || rethrow()
                push!(missing_inputs, "$(PSY.get_name(device)) has no $what")
            end
        end
        return
    end
    isempty(missing_inputs) || throw(
        ArgumentError(
            "nem_system: $(length(missing_inputs)) dispatch device input(s) are unset: $(join(missing_inputs, ", ")); " *
                "build sys with nem_system(db, NEMDEConfiguration(); date_range) over the replay range",
        ),
    )
    return
end


# The constraint build report holds every invoked constraint, weight and term it read.
function _check_nemde_constraint_report(sys)
    missing_stamps = get_missing_constraint_intervals(sys)
    if !isempty(missing_stamps)
        # A long gap lists its first five stamps and counts the rest.
        shown = first(missing_stamps, min(length(missing_stamps), 5))
        detail = join(shown, ", ") *
            (length(missing_stamps) > length(shown) ? " and $(length(missing_stamps) - length(shown)) more" : "")
        throw(
            ArgumentError(
                "nem_system: $(length(missing_stamps)) dispatch interval(s) have no DISPATCHCONSTRAINT rows, " *
                    "at $detail; repopulate DISPATCHCONSTRAINT with populate(...; force_new = true)",
            ),
        )
    end
    defaulted = get_defaulted_constraint_weights(sys)
    isempty(defaulted) || throw(
        ArgumentError(
            "nem_system: $(length(defaulted)) invoked constraint(s) have a NULL GENERICCONSTRAINTWEIGHT in GENCONDATA " *
                "and were built with the default 1.0: $(join(defaulted, ", ")); " *
                "repopulate GENCONDATA with populate(...; force_new = true)",
        ),
    )
    skipped = get_skipped_constraints(sys)
    isempty(skipped.constraint) || throw(
        ArgumentError(
            "nem_system: $(nrow(skipped)) invoked GENCONID version(s) could not be built: " *
                join(("$(row.constraint) ($(row.reason))" for row in eachrow(skipped)), ", ") *
                "; repopulate GENCONDATA and the SPD*CONSTRAINT tables with populate(...; force_new = true), " *
                "or build with every unit, region and interconnector the constraints name",
        ),
    )
    dropped = get_dropped_terms(sys)
    isempty(dropped.constraint) || throw(
        ArgumentError(
            "nem_system: $(nrow(dropped)) unit term(s) were dropped from built constraints: " *
                join(("$(row.constraint): $(row.key)" for row in eachrow(dropped)), ", ") *
                "; build with every unit the constraints name",
        ),
    )
    return
end


# Every MNSP carries two distinct directional links, each with its bid and observed state.
function _check_nemde_mnsp_structure(sys)
    incomplete = String[]
    for device in get_components(AreaInterchange, sys)
        PSY.get_available(device) || continue
        registrations = get_supplemental_attributes(NEMInterconnectorRegistration, device)::Vector{NEMInterconnectorRegistration}
        (isempty(registrations) || only(registrations).kind != InterconnectorKind.MNSP) && continue
        name = get_name(device)
        links = get_supplemental_attributes(NEMMNSPLink, device)::Vector{NEMMNSPLink}
        link_ids = unique(link.link_id for link in links)
        length(links) == 2 && length(link_ids) == 2 || push!(
            incomplete,
            "$name has $(length(links)) directional link(s) with $(length(link_ids)) distinct LINKID(s), expected two",
        )
        isempty((get_supplemental_attributes(NEMMNSPBid, device)::Vector{NEMMNSPBid})) && push!(incomplete, "$name has no MNSP bid")
        isempty((get_supplemental_attributes(NEMMNSPObservedState, device)::Vector{NEMMNSPObservedState})) &&
            push!(incomplete, "$name has no MNSP observed state")
    end
    isempty(incomplete) || throw(
        ArgumentError(
            "nem_system: MNSP input(s) are incomplete: $(join(incomplete, "; ")); " *
                "repopulate INTERCONNECTORCONSTRAINT, MNSP_INTERCONNECTOR, MNSP_DAYOFFER, MNSP_BIDOFFERPERIOD and " *
                "DISPATCH_MNSPBIDTRK with populate(...; force_new = true)",
        ),
    )
    return
end
