# AEMO's Energy Inflexible Offer: a unit held at its participant fixed loading, elastic at CVP 380.

PSI.get_multiplier_value(::Union{FixedLoadTimeSeriesParameter, FixedLoadInvokedTimeSeriesParameter}, ::PSY.StaticInjection, ::AbstractNEMDispatch) = 1.0

PSI.convert_result_to_natural_units(::Type{FixedLoadTimeSeriesParameter}) = true

# The parameters of the fixed-loading rows and their series; a device carries them only when it has a fixed loading.
const _FIXED_LOAD_SERIES = (
    FixedLoadTimeSeriesParameter => NEM_SERIES.fixed_load,
    FixedLoadInvokedTimeSeriesParameter => NEM_SERIES.fixed_load_invoked,
)

# Offset, in MW, that moves both fixed-loading rows out of reach at an interval with no fixed loading.
const _FIXED_LOAD_INACTIVE_MW = 1.0e5


_fixed_load_devices(devices) = [d for d in devices if PSY.has_time_series(d, PSY.SingleTimeSeries, NEM_SERIES.fixed_load)]


"""
    _add_fixed_load_arguments!(container, devices, model)

Adds the fixed-loading parameters ([`FixedLoadTimeSeriesParameter`](@ref),
[`FixedLoadInvokedTimeSeriesParameter`](@ref)) and the surplus and deficit slacks for the
`devices` carrying a `"fixed_load"` series ([`set_nem_fixed_loads!`](@ref)).

# Returns
`nothing`.
"""
function _add_fixed_load_arguments!(container::PSI.OptimizationContainer, devices, model::PSI.DeviceModel{T, D}) where {T, D}
    fixed = _fixed_load_devices(devices)
    isempty(fixed) && return
    for (param, _) in _FIXED_LOAD_SERIES
        PSI.add_parameters!(container, param, fixed, model)
    end
    PSI.add_variables!(container, EnergyFixedLoadSurplusSlack, fixed, D())
    PSI.add_variables!(container, EnergyFixedLoadDeficitSlack, fixed, D())
    return
end


"""
    PSI.add_constraints!(container, ::Type{EnergyFixedLoadConstraint}, devices, model::PSI.DeviceModel{T, <:AbstractNEMDispatch}, network_model)

Adds AEMO's Energy Inflexible Offer rows (*Schedule of Constraint Violation Penalty Factors* v8.0,
item 13, "Unit = X MW") for the `devices` carrying a fixed loading: the device's net energy
([`_energy_variables`](@ref)) minus its surplus slack at most, and plus its deficit slack at least,
its fixed loading. At an interval with no fixed loading both rows are relaxed by
`_FIXED_LOAD_INACTIVE_MW`, so they never bind.

# Returns
`nothing`.
"""
function PSI.add_constraints!(
        container::PSI.OptimizationContainer,
        ::Type{EnergyFixedLoadConstraint},
        devices::IS.FlattenIteratorWrapper{T},
        ::PSI.DeviceModel{T, <:AbstractNEMDispatch},
        ::PSI.NetworkModel{<:PM.AbstractPowerModel},
    ) where {T <: PSY.StaticInjection}
    fixed = _fixed_load_devices(devices)
    isempty(fixed) && return
    names = PSY.get_name.(fixed)
    steps = PSI.get_time_steps(container)
    target, _ = _ts_parameter_accessor(container, FixedLoadTimeSeriesParameter, T)
    invoked, _ = _ts_parameter_accessor(container, FixedLoadInvokedTimeSeriesParameter, T)
    surplus = PSI.get_variable(container, EnergyFixedLoadSurplusSlack(), T)
    deficit = PSI.get_variable(container, EnergyFixedLoadDeficitSlack(), T)
    upper = PSI.add_constraints_container!(container, EnergyFixedLoadConstraint(), T, names, steps; meta = "upper")
    lower = PSI.add_constraints_container!(container, EnergyFixedLoadConstraint(), T, names, steps; meta = "lower")
    inactive = _FIXED_LOAD_INACTIVE_MW / PSI.get_base_power(container)
    jm = PSI.get_jump_model(container)
    for device in fixed, t in steps
        name = PSY.get_name(device)
        net = sum(m * PSI.get_variable(container, V(), T)[name, t] for (V, m) in _energy_variables(device))
        relax = inactive * (1.0 - invoked(name, t))
        upper[name, t] = JuMP.@constraint(jm, net - surplus[name, t] <= target(name, t) + relax)
        lower[name, t] = JuMP.@constraint(jm, net + deficit[name, t] >= target(name, t) - relax)
    end
    return
end


"Prices the fixed-loading slacks of `devices` at [`FIXED_LOADING_CVP_FACTOR`](@ref) times the Market Price Cap."
function _add_fixed_load_costs!(container::PSI.OptimizationContainer, devices, ::Type{T}) where {T}
    names = PSY.get_name.(_fixed_load_devices(devices))
    isempty(names) && return
    for slack in (EnergyFixedLoadSurplusSlack(), EnergyFixedLoadDeficitSlack())
        _add_mpc_penalty!(container, PSI.get_variable(container, slack, T), names, PSI.get_time_steps(container), FIXED_LOADING_CVP_FACTOR)
    end
    return
end
