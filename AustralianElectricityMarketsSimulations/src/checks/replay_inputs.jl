"""
    _check_replay_system_inputs(sys, parts)

Verifies that `sys` carries every input the replay template of `parts` depends on, from the records
of the setters that built it: with `:generic_constraints`, [`get_missing_constraint_intervals`](@ref),
[`get_defaulted_constraint_weights`](@ref), [`get_skipped_constraints`](@ref) and
[`get_dropped_terms`](@ref) of [`add_nem_constraints!`](@ref) (`DISPATCHCONSTRAINT`, `GENCONDATA`,
`SPDCONNECTIONPOINTCONSTRAINT`, `SPDREGIONCONSTRAINT`, `SPDINTERCONNECTORCONSTRAINT`); the
dispatch-limit series of [`set_nem_dispatch_limits!`](@ref) (`DISPATCHLOAD`) on every dispatch
device, batteries only with `:batteries`; and, with `:losses`, the offers of `set_mnsp_offers!`
(`INTERCONNECTORCONSTRAINT`, `MNSP_INTERCONNECTOR`, `MNSP_DAYOFFER`, `MNSP_BIDOFFERPERIOD`,
`DISPATCH_MNSPBIDTRK`) on every available MNSP.

# Arguments
- `sys`: the `PSY.System` to check.
- `parts`: the [`REPLICATION_PARTS`](@ref) the template models.

# Returns
`nothing`. Throws an `ArgumentError` naming the first incomplete input and how to supply it.
"""
function _check_replay_system_inputs(sys::PSY.System, parts)
    :generic_constraints in parts && _check_replay_constraint_inputs(sys)
    uncovered = [
        PSY.get_name(device) for device in nem_dispatch_devices(sys)
            if (:batteries in parts || !(device isa PSY.Storage)) && !_has_nem_dispatch_limits(device)
    ]
    isempty(uncovered) || throw(
        ArgumentError(
            "replication_template: incomplete dispatch inputs for $(join(sort!(uncovered), ", ")); " *
                "call set_market_bids!, set_nem_dispatch_limits! and set_nem_energy_limits! over the replay range before replay",
        ),
    )
    :losses in parts && foreach(_check_mnsp_offers, PSY.get_components(PSY.get_available, PSY.AreaInterchange, sys))
    return
end


# The `add_nem_constraints!` records of `sys` are empty: every invoked constraint, weight and term was read.
function _check_replay_constraint_inputs(sys::PSY.System)
    missing_intervals = get_missing_constraint_intervals(sys)
    isempty(missing_intervals) || throw(
        ArgumentError(
            "replication_template: missing dispatch constraint intervals: $(join(string.(missing_intervals), ", ")); " *
                "populate DISPATCHCONSTRAINT for the requested range",
        ),
    )
    defaulted_weights = get_defaulted_constraint_weights(sys)
    isempty(defaulted_weights) || throw(
        ArgumentError(
            "replication_template: constraints with a NULL GENERICCONSTRAINTWEIGHT: $(join(defaulted_weights, ", ")); " *
                "repopulate GENCONDATA with populate(...; force_new = true)",
        ),
    )
    skipped_inputs = get_skipped_constraints(sys)
    isempty(skipped_inputs) || throw(
        ArgumentError(
            "replication_template: incomplete constraint inputs: $(join(skipped_inputs.constraint, ", ")); see " *
                "get_skipped_constraints(sys) for the missing definitions and keys, and repopulate GENCONDATA and the " *
                "SPD*CONSTRAINT tables with populate(...; force_new = true)",
        ),
    )
    dropped_inputs = get_dropped_terms(sys)
    isempty(dropped_inputs) || throw(
        ArgumentError(
            "replication_template: incomplete constraint terms: " *
                "$(join(dropped_inputs.constraint .* ": " .* dropped_inputs.key, ", ")); see get_dropped_terms(sys), and " *
                "build sys with every unit its constraints name",
        ),
    )
    return
end


"""
    _check_mnsp_offers(device)

Verifies that `device` carries either none or all four of the links' offer and availability series
of `set_mnsp_offers!`, and all four when it is an MNSP (`ext["ic_type"] == "MNSP"`), since a partial
set cannot be modelled.

# Arguments
- `device`: the `PSY.AreaInterchange` to check.

# Returns
`nothing`. Throws an `ArgumentError` naming `device` otherwise.
"""
function _check_mnsp_offers(device::PSY.AreaInterchange)
    present = _mnsp_offer_series_present(device)
    required = get(PSY.get_ext(device), "ic_type", nothing) == "MNSP"
    (required || any(present)) && !all(present) && throw(
        ArgumentError(
            "AreaInterchange $(PSY.get_name(device)) is an MNSP with incomplete directional offer inputs; " *
                "call set_mnsp_offers! with complete data before dispatch",
        ),
    )
    if all(present)
        for (_, series) in _MNSP_OPERATING_SERIES
            PSY.has_time_series(device, PSY.SingleTimeSeries, series) || throw(
                ArgumentError("AreaInterchange $(PSY.get_name(device)) is missing MNSP operating input $series; call set_mnsp_offers!"),
            )
        end
    end
    return
end
