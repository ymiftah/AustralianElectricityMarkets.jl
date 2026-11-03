"""
    check_template_against_sys(template, sys) -> Nothing

Verifies that `sys` carries the inputs that `template` depends on and that `template` models every
dispatch participant of `sys` and every available `GenericConstraint` it can build. Run after
[`exclude_unmodeled_services!`](@ref) and before the model is built.

# Arguments
- `template`: the `PSI.ProblemTemplate` the replay builds, e.g. [`template_nemde`](@ref)().
- `sys`: the replay system.

# Returns
`nothing`. Throws `ArgumentError` naming the first failed check: an incomplete input of `sys`, a dispatch
participant type with no device model in `template`, or an available `GenericConstraint` the template
cannot build.
"""
function check_template_against_sys(template::PSI.ProblemTemplate, sys::PSY.System)
    _check_replay_system_inputs(sys, template)
    modeled = Set(PSI.get_component_type(m) for m in values(PSI.get_device_models(template)))
    missing_types = [T for T in nem_dispatch_participants(sys) if !(T in modeled)]
    isempty(missing_types) || throw(
        ArgumentError(
            "check_template_against_sys: no device model in template for dispatch participant types " *
                "$(join(string.(missing_types), ", ")).",
        ),
    )
    if _has_service_model(template, GenericConstraint)
        _filter_buildable_generic_constraints(sys, template, collect(PSY.get_components(PSY.get_available, GenericConstraint, sys)))
    end
    return
end
