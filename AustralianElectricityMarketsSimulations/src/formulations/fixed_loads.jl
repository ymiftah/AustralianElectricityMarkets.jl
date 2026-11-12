# AEMO's Energy Inflexible Offer: a unit held at its participant fixed loading, elastic at CVP 380.

PSI.get_multiplier_value(::Union{FixedLoadTimeSeriesParameter, FixedLoadInvokedTimeSeriesParameter}, ::PSY.StaticInjection, ::AbstractNEMDispatch) = 1.0

PSI.convert_result_to_natural_units(::Type{FixedLoadTimeSeriesParameter}) = true

# The parameters of the fixed-loading rows and the build's first-solve seed series.
const _FIXED_LOAD_SERIES = (
    FixedLoadTimeSeriesParameter => _FIXED_LOAD_SEED_SERIES,
    FixedLoadInvokedTimeSeriesParameter => _FIXED_LOAD_INVOKED_SEED_SERIES,
)

# Offset, in MW, that moves both fixed-loading rows out of reach at an interval with no fixed loading.
const _FIXED_LOAD_INACTIVE_MW = 1.0e5


"Whether `device` has an energy bid carrying a fixed loading on either side."
function _has_fixed_load_bid(device)
    cost = _nem_offer_cost(device)
    isnothing(cost) && return false
    return any(b -> !isnothing(b.fixed_load), get_energy_bids(cost))
end


_fixed_load_devices(devices) = [d for d in devices if _has_fixed_load_bid(d)]


"""
    _add_fixed_load_arguments!(container, devices, model)

Adds the fixed-loading parameters ([`FixedLoadTimeSeriesParameter`](@ref),
[`FixedLoadInvokedTimeSeriesParameter`](@ref)) and the surplus and deficit slacks for the
`devices` whose energy bid carries a fixed loading. The parameters read the build's seed series;
every later solve recomputes them from the bids and the state source.

# Returns
`nothing`.
"""
function _add_fixed_load_arguments!(container::PSI.OptimizationContainer, devices, model::PSI.DeviceModel{T, D}) where {T, D}
    fixed = _fixed_load_devices(devices)
    isempty(fixed) && return
    for (param, name) in _FIXED_LOAD_SERIES
        PSI.add_parameters!(container, param, fixed, model; time_series_name = name)
    end
    _add_device_unit_slacks!(container, FixedLoadSurplusVariant(), fixed)
    _add_device_unit_slacks!(container, FixedLoadDeficitVariant(), fixed)
    return
end


"""
    PSI.add_constraints!(container, ::Type{NEMUnitConstraint}, devices, model::PSI.DeviceModel{T, <:AbstractNEMDispatch}, network_model)

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
        ::Type{NEMUnitConstraint},
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
    surplus = PSI.get_variable(container, NEMUnitSlack(), T, _nem_unit_slack_meta(FixedLoadSurplusVariant()))
    deficit = PSI.get_variable(container, NEMUnitSlack(), T, _nem_unit_slack_meta(FixedLoadDeficitVariant()))
    upper = PSI.add_constraints_container!(container, NEMUnitConstraint(), T, names, steps; meta = "fixed_load|upper")
    lower = PSI.add_constraints_container!(container, NEMUnitConstraint(), T, names, steps; meta = "fixed_load|lower")
    inactive = _FIXED_LOAD_INACTIVE_MW / PSI.get_base_power(container)
    jm = PSI.get_jump_model(container)
    for device in fixed, t in steps
        name = PSY.get_name(device)
        relax = inactive * (1.0 - invoked(name, t))
        upper[name, t] = JuMP.@constraint(
            jm, sum(m * PSI.get_variable(container, V(), T)[name, t] for (V, m) in _energy_variables(device)) -
                surplus[name, t] <= target(name, t) + relax
        )
        lower[name, t] = JuMP.@constraint(
            jm, sum(m * PSI.get_variable(container, V(), T)[name, t] for (V, m) in _energy_variables(device)) +
                deficit[name, t] >= target(name, t) - relax
        )
    end
    return
end


"Prices the fixed-loading slacks of `devices` at [`FIXED_LOADING_CVP_FACTOR`](@ref) times the Market Price Cap of the build's initial interval."
function _add_fixed_load_costs!(container::PSI.OptimizationContainer, devices, ::Type{T}) where {T}
    names = PSY.get_name.(_fixed_load_devices(devices))
    isempty(names) && return
    for variant in (FixedLoadSurplusVariant(), FixedLoadDeficitVariant())
        _add_unit_slack_penalty!(container, variant, T, names)
    end
    return
end
