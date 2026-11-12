"""
    _check_replay_system_inputs(sys, template)

Verifies that `sys` carries every input the replay of `template` depends on, from the records
of the setters that built it: with a `GenericConstraint` service model, [`get_missing_constraint_intervals`](@ref),
[`get_defaulted_constraint_weights`](@ref), [`get_skipped_constraints`](@ref) and
[`get_dropped_terms`](@ref) of the constraint build (`DISPATCHCONSTRAINT`, `GENCONDATA`,
`SPDCONNECTIONPOINTCONSTRAINT`, `SPDREGIONCONSTRAINT`, `SPDINTERCONNECTORCONSTRAINT`); the
dispatch-limit series of the dispatch-limits build (`DISPATCHLOAD`) on every dispatch
device, the resolution and five-minute alignment of the series keyed by each device's
[`NEMObservedState`](@ref); and, with a `PSY.AreaInterchange` device model, the offers of
`set_mnsp_offers!` (`INTERCONNECTORCONSTRAINT`, `MNSP_INTERCONNECTOR`, `MNSP_DAYOFFER`,
`MNSP_BIDOFFERPERIOD`, `DISPATCH_MNSPBIDTRK`) on every available MNSP.

# Arguments
- `sys`: the `PSY.System` to check.
- `template`: the `PSI.ProblemTemplate` the replay builds.

# Returns
`nothing`. Throws an `ArgumentError` naming the first incomplete input and how to supply it.
"""
function _check_replay_system_inputs(sys::PSY.System, template::PSI.ProblemTemplate)
    _has_service_model(template, GenericConstraint) && _check_replay_constraint_inputs(sys)
    devices = nem_dispatch_devices(sys)
    uncovered = [PSY.get_name(device) for device in devices if !_has_nem_dispatch_limits(device)]
    isempty(uncovered) || throw(
        ArgumentError(
            "check_template_against_sys: incomplete dispatch inputs for $(join(sort!(uncovered), ", ")); " *
                "prepare_replay! attaches them once sys is built with nem_system(db, NEMDEConfiguration(); date_range) " *
                "over the replay range",
        ),
    )
    foreach(_check_state_series_alignment, devices)
    _has_device_model(template, PSY.AreaInterchange) &&
        foreach(_check_mnsp_offers, PSY.get_components(PSY.get_available, PSY.AreaInterchange, sys))
    return
end


"""
    _check_state_series_alignment(device)

Verifies that the series keyed by `device`'s [`NEMObservedState`](@ref) are dispatch-interval series:
each is a five-minute `SingleTimeSeries` on a five-minute boundary, so the per-step state read lands
on the interval it names.

# Arguments
- `device`: the NEM dispatch device to check.

# Returns
`nothing`. Throws an `ArgumentError` naming the device and the offending series.
"""
function _check_state_series_alignment(device)
    observed = AustralianElectricityMarkets.get_observed_state(device)
    step_ms = Dates.value(convert(Millisecond, DISPATCH_INTERVAL))
    for key in (observed.initial_mw, observed.dispatch_mode)
        key isa IS.StaticTimeSeriesKey || continue
        name = PSY.get_name(key)
        series = PSY.get_time_series(PSY.SingleTimeSeries, device, name)
        resolution = Dates.canonicalize(Dates.CompoundPeriod(IS.get_resolution(series)))
        resolution == DISPATCH_INTERVAL || throw(
            ArgumentError(
                "\"$(PSY.get_name(device))\": its state series \"$name\" has resolution $resolution, " *
                    "expected $DISPATCH_INTERVAL",
            ),
        )
        stamps = PSY.get_time_series_timestamps(PSY.SingleTimeSeries, device, name)
        misaligned = findfirst(t -> Dates.value(t) % step_ms != 0, stamps)
        isnothing(misaligned) || throw(
            ArgumentError(
                "\"$(PSY.get_name(device))\": its state series \"$name\" has the stamp $(stamps[misaligned]), " *
                    "which is not aligned to the $DISPATCH_INTERVAL dispatch interval",
            ),
        )
    end
    return
end


# The constraint-build records of `sys` are empty: every invoked constraint, weight and term was read.
function _check_replay_constraint_inputs(sys::PSY.System)
    missing_intervals = get_missing_constraint_intervals(sys)
    isempty(missing_intervals) || throw(
        ArgumentError(
            "check_template_against_sys: missing dispatch constraint intervals: $(join(string.(missing_intervals), ", ")); " *
                "populate DISPATCHCONSTRAINT for the requested range",
        ),
    )
    defaulted_weights = get_defaulted_constraint_weights(sys)
    isempty(defaulted_weights) || throw(
        ArgumentError(
            "check_template_against_sys: constraints with a NULL GENERICCONSTRAINTWEIGHT: $(join(defaulted_weights, ", ")); " *
                "repopulate GENCONDATA with populate(...; force_new = true)",
        ),
    )
    skipped_inputs = get_skipped_constraints(sys)
    isempty(skipped_inputs) || throw(
        ArgumentError(
            "check_template_against_sys: incomplete constraint inputs: $(join(skipped_inputs.constraint, ", ")); see " *
                "get_skipped_constraints(sys) for the missing definitions and keys, and repopulate GENCONDATA and the " *
                "SPD*CONSTRAINT tables with populate(...; force_new = true)",
        ),
    )
    dropped_inputs = get_dropped_terms(sys)
    isempty(dropped_inputs) || throw(
        ArgumentError(
            "check_template_against_sys: incomplete constraint terms: " *
                "$(join(dropped_inputs.constraint .* ": " .* dropped_inputs.key, ", ")); see get_dropped_terms(sys), and " *
                "build sys with every unit its constraints name",
        ),
    )
    return
end


"""
    _check_mnsp_offers(device)

Verifies that `device` carries either none or all of the MNSP keys of `set_mnsp_offers!`, and all of them when
its [`NEMInterconnectorRegistration`](@ref) is `InterconnectorKind.MNSP`, since a partial set cannot be modelled.

# Arguments
- `device`: the `PSY.AreaInterchange` to check.

# Returns
`nothing`. Throws an `ArgumentError` naming `device` otherwise.
"""
function _check_mnsp_offers(device::PSY.AreaInterchange)
    bids, initial = _mnsp_offer_series_present(device)
    present = [bids; initial]
    registrations = PSY.get_supplemental_attributes(NEMInterconnectorRegistration, device)::Vector{NEMInterconnectorRegistration}
    required = !isempty(registrations) && only(registrations).kind == InterconnectorKind.MNSP
    (required || any(present)) && !all(present) && throw(
        ArgumentError(
            "AreaInterchange $(PSY.get_name(device)) is an MNSP with incomplete directional offer inputs; " *
                "call set_mnsp_offers! with complete data before dispatch",
        ),
    )
    return
end
