"""
    check_template_against_sys(template, sys) -> Nothing

Verifies that `sys` carries the inputs that `template` depends on and that `template` models every
dispatch participant of `sys`. Run by `PSI.validate_template` before the model is built.

# Arguments
- `template`: the `PSI.ProblemTemplate` the replay builds, e.g. [`template_nemde`](@ref)().
- `sys`: the replay system.

# Returns
`nothing`. Throws `ArgumentError` naming the first failed check: an incomplete input of `sys`, a device
carrying NEM unit data modelled with a formulation that is not an [`AbstractNEMDispatch`](@ref), a dispatch
participant type with no device model in `template`.
"""
function check_template_against_sys(template::PSI.ProblemTemplate, sys::PSY.System)
    for model in values(PSI.get_device_models(template))
        T = PSI.get_component_type(model)
        formulation = PSI.get_formulation(model)
        formulation <: AbstractNEMDispatch && continue
        any(AustralianElectricityMarkets.has_nem_unit_data, PSY.get_components(T, sys)) && throw(
            ArgumentError(
                "check_template_against_sys: $(nameof(T)) carries NEM unit data and is modelled with " *
                    "$(nameof(formulation)); a NEM unit needs an AbstractNEMDispatch formulation.",
            ),
        )
    end
    _check_replay_system_inputs(sys, template)
    modeled = Set(PSI.get_component_type(m) for m in values(PSI.get_device_models(template)))
    missing_types = [T for T in nem_dispatch_participants(sys) if !(T in modeled)]
    isempty(missing_types) || throw(
        ArgumentError(
            "check_template_against_sys: no device model in template for dispatch participant types " *
                "$(join(string.(missing_types), ", ")).",
        ),
    )
    return
end


"""
    _check_excluded_constraints(sys, template) -> Nothing

Verifies that every constraint `template` excludes by name is a `GenericConstraint` of `sys`.

# Arguments
- `sys`: the replay system.
- `template`: the `PSI.ProblemTemplate` the replay builds.

# Returns
`nothing`. Throws `ArgumentError` naming the unknown constraints.
"""
function _check_excluded_constraints(sys::PSY.System, template::PSI.ProblemTemplate)
    unknown = sort!([n for n in keys(_excluded_constraints(template)) if isnothing(PSY.get_component(GenericConstraint, sys, n))])
    isempty(unknown) || throw(
        ArgumentError(
            "validate_template: exclude_constraints names $(join(unknown, ", ")), which are not GenericConstraints of sys.",
        ),
    )
    return
end


"""
    _check_blocked_constraints(blocked) -> Nothing

Throws `ArgumentError` naming each constraint of `blocked`, the result of [`_blocked_constraints`](@ref).
"""
function _check_blocked_constraints(blocked)
    isempty(blocked) || throw(
        ArgumentError(
            "validate_template: generic constraints the template cannot model: " *
                "$(join(("$(r.constraint) ($(r.reason))" for r in blocked), ", ")).",
        ),
    )
    return
end
