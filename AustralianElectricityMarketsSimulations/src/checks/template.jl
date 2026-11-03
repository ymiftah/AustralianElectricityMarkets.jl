"""
    check_template_against_sys(template, sys; parts = REPLICATION_PARTS) -> Nothing

Verifies that `sys` carries the inputs of `parts` and that `template` models every dispatch participant
of `sys` and every available `GenericConstraint` it can build. Run after [`exclude_unmodeled_services!`](@ref)
and before the model is built.

# Arguments
- `template`: the [`template_nemde`](@ref) of `parts`.
- `sys`: the replay system.
- `parts`: the [`REPLICATION_PARTS`](@ref) the replay models; must be the parts `template` was built with.

# Returns
`nothing`. Throws `ArgumentError` naming the first failed check: an incomplete input of `sys`, a dispatch
participant type with no device model in `template`, `:tie_breaks` without `:batteries` while an available
battery carries tie-break scales, or an available `GenericConstraint` the template cannot build.
"""
function check_template_against_sys(template::PSI.ProblemTemplate, sys::PSY.System; parts = REPLICATION_PARTS)
    check_replication_parts(parts)
    _check_replay_system_inputs(sys, parts)
    modeled = Set(PSI.get_component_type(m) for m in values(PSI.get_device_models(template)))
    missing_types = [
        T for T in nem_dispatch_participants(sys)
            if (:batteries in parts || !(T <: PSY.Storage)) && !(T in modeled)
    ]
    isempty(missing_types) || throw(
        ArgumentError(
            "check_template_against_sys: no device model in template for dispatch participant types " *
                "$(join(string.(missing_types), ", ")).",
        ),
    )
    _check_tie_break_scales_modeled(sys, parts)
    if :generic_constraints in parts
        _filter_buildable_generic_constraints(sys, template, collect(PSY.get_components(PSY.get_available, GenericConstraint, sys)))
    end
    return
end


# With `:tie_breaks` but not `:batteries`, no battery may carry tie-break scales, which would go unmodeled.
function _check_tie_break_scales_modeled(sys::PSY.System, parts)
    (:tie_breaks in parts && !(:batteries in parts)) || return
    service = PSY.get_component(EnergyTieBreak, sys, TIE_BREAK_SERVICE_NAME)
    isnothing(service) && return
    scaled = sort!(
        [
            PSY.get_name(d) for d in PSY.get_contributing_devices(sys, service)
                if d isa PSY.Storage && PSY.get_available(d) &&
                any(k -> startswith(IS.get_name(k), "tie_break_scale_"), IS.get_time_series_keys(d))
        ],
    )
    isempty(scaled) || throw(
        ArgumentError(
            "check_template_against_sys: parts include :tie_breaks but not :batteries, and the batteries " *
                "$(join(scaled, ", ")) carry tie-break scales; add :batteries to parts or leave out :tie_breaks.",
        ),
    )
    return
end
