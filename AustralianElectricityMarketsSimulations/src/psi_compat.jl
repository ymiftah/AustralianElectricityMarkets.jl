# Every isolated PowerSimulations.jl override lives in this one file so the compat surface is
# auditable in one place. Each override states the PSI version it was written against; re-check
# this file on every PSI upgrade.

"""
    PSI._modify_device_model!(devices_template, ::PSI.ServiceModel{GenericConstraint, LinearFactorLimit}, contributing_devices)

No-op override of `PowerSimulations.jl` 0.38.4's private `_modify_device_model!` hook, called
unconditionally when registering a service model with contributing devices. [`LinearFactorLimit`](@ref)
adds no device-side range expressions, so it has nothing to fold into the device models.

# Returns
`nothing`.
"""
function PSI._modify_device_model!(
        ::Dict{Symbol, PSI.DeviceModel},
        ::PSI.ServiceModel{GenericConstraint, LinearFactorLimit},
        ::Vector,
    )
    return nothing
end

"""
    PSI._modify_device_model!(devices_template, ::PSI.ServiceModel{FCASService, FCASMarket}, contributing_devices)

No-op override of `PowerSimulations.jl` 0.38.4's private `_modify_device_model!` hook, called
unconditionally when registering a service model with contributing devices. [`FCASMarket`](@ref)
adds no device-side range expressions, so it has nothing to fold into the device models.

# Returns
`nothing`.
"""
function PSI._modify_device_model!(
        ::Dict{Symbol, PSI.DeviceModel},
        ::PSI.ServiceModel{FCASService, FCASMarket},
        ::Vector,
    )
    return nothing
end

# No area-balance dual override here: the pinned PowerSimulations.jl fork (see `[sources]` in
# Project.toml) registers the `PSY.Area`-keyed container itself.

# PSI 0.38.4 keys these on the device type with a bare `AbstractDeviceFormulation`, so the
# `PSY.StaticInjection` method below is ambiguous for a `PSY.Generator`; the two narrower methods
# break the tie.

"""
    PSI._include_min_gen_power_in_constraint(::PSY.StaticInjection, ::PSI.ActivePowerVariable, ::AbstractNEMDispatch)

Override of `PowerSimulations.jl` 0.38.4's private market-bid hook: the bid stack's first
breakpoint contributes no minimum-generation offset, so no `OnVariable` is required.

# Returns
`false`.
"""
PSI._include_min_gen_power_in_constraint(::PSY.StaticInjection, ::PSI.ActivePowerVariable, ::AbstractNEMDispatch) = false
PSI._include_min_gen_power_in_constraint(::PSY.Generator, ::PSI.ActivePowerVariable, ::AbstractNEMDispatch) = false
PSI._include_min_gen_power_in_constraint(::PSY.RenewableDispatch, ::PSI.ActivePowerVariable, ::AbstractNEMDispatch) = false

"""
    PSI._include_constant_min_gen_power_in_constraint(::PSY.StaticInjection, ::PSI.ActivePowerVariable, ::AbstractNEMDispatch)

Override of `PowerSimulations.jl` 0.38.4's private market-bid hook: the bid stack's first
breakpoint enters the power balance as a constant rather than through an `OnVariable`.

# Returns
`true`.
"""
PSI._include_constant_min_gen_power_in_constraint(::PSY.StaticInjection, ::PSI.ActivePowerVariable, ::AbstractNEMDispatch) = true
