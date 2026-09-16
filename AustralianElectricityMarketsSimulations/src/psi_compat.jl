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

"""
    PSI.get_initial_conditions_service_model(model, service_model::PSI.ServiceModel{GenericConstraint, LinearFactorLimit})

No-op override of `PowerSimulations.jl` 0.38.4's private `get_initial_conditions_service_model`
hook, called for every registered `ServiceModel` when building the sub-model PSI derives
ramp/commitment initial conditions from. [`LinearFactorLimit`](@ref) carries no ramp/commitment
state of its own to initialize.

# Returns
`PSI.ServiceModel(GenericConstraint, LinearFactorLimit)`.
"""
function PSI.get_initial_conditions_service_model(
        ::PSI.OperationModel,
        ::PSI.ServiceModel{GenericConstraint, LinearFactorLimit},
    )
    return PSI.ServiceModel(GenericConstraint, LinearFactorLimit)
end

# Area-balance dual registration: `AreaBalancePowerModel` is a `PM.AbstractPowerModel`, so stock PSI
# 0.38.4's `add_constraint_dual!`/`assign_dual_variable!` dispatch to their generic
# `PM.AbstractPowerModel` methods and register a bus-keyed dual, the wrong shape for
# `AreaBalancePowerModel`'s `PSY.Area`-keyed `CopperPlateBalanceConstraint`. This package's pinned
# PowerSimulations.jl fork (see `[sources]` in Project.toml) adds more specific
# `NetworkModel{AreaBalancePowerModel}` methods that register the correct `Area`-keyed container
# instead — so no method is defined here.
