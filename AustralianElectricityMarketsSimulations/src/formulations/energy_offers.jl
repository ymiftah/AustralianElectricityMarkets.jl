function _energy_offer_side(::Type{<:Union{EnergyOfferSurplusSlack, EnergyOfferDeficitSlack}})
    return OfferSide.GEN
end

function _energy_offer_side(::Type{<:Union{EnergyDecrementalOfferSurplusSlack, EnergyDecrementalOfferDeficitSlack}})
    return OfferSide.LOAD
end

function _energy_offer_slacks(side::OfferSide)
    return side == OfferSide.GEN ? (EnergyOfferSurplusSlack, EnergyOfferDeficitSlack) :
        (EnergyDecrementalOfferSurplusSlack, EnergyDecrementalOfferDeficitSlack)
end

# The sides of the energy offer a device type bids: a scheduled load bids only its consumption.
_energy_offer_sides(::Type{<:PSY.StaticInjection}) = (OfferSide.GEN,)
_energy_offer_sides(::Type{<:PSY.ControllableLoad}) = (OfferSide.LOAD,)
_energy_offer_sides(::Type{<:PSY.Storage}) = (OfferSide.GEN, OfferSide.LOAD)

# The dispatch variable an energy offer side prices.
_energy_offer_power_variable(::Type{<:PSY.StaticInjection}, ::OfferSide) = PSI.ActivePowerVariable
function _energy_offer_power_variable(::Type{<:PSY.Storage}, side::OfferSide)
    return side == OfferSide.GEN ? PSI.ActivePowerOutVariable : PSI.ActivePowerInVariable
end

_energy_offer_meta(side::OfferSide) = side == OfferSide.GEN ? "gen" : "load"

# The devices bidding energy on `side`: those carrying its `energy_offer` series.
function _energy_offer_devices(devices::Union{Vector{T}, IS.FlattenIteratorWrapper{T}}, side::OfferSide) where {T}
    name = energy_offer_series_name(side)
    return T[d for d in devices if PSY.has_time_series(d, PSY.SingleTimeSeries, name)]
end

function _energy_offer_devices(devices::Union{Vector{T}, IS.FlattenIteratorWrapper{T}}, ::Type{S}) where {T, S <: AbstractEnergyOfferSlack}
    return _energy_offer_devices(devices, _energy_offer_side(S))
end

"""
    PSI.add_variables!(container, slack_type, devices, formulation)

Allocates total-offer violation variables only for devices carrying the corresponding energy
offer direction, using PSI's variable bounds and container construction.

# Returns
`nothing`.
"""
function PSI.add_variables!(
        container::PSI.OptimizationContainer, ::Type{S},
        devices::Union{Vector{T}, IS.FlattenIteratorWrapper{T}}, formulation::AbstractNEMDispatch,
    ) where {S <: AbstractEnergyOfferSlack, T <: PSY.StaticInjection}
    selected = _energy_offer_devices(devices, S)
    isempty(selected) || PSI.add_variable!(container, S(), selected, formulation)
    return
end

"""
    PSI.add_proportional_cost!(container, slack, devices, formulation)

Prices each total-offer mismatch at CVP1135 times the Market Price Cap of the build's initial interval, with system-base MW
and interval-hour conversion. Submitted energy prices apply only to cleared band quantities.

# Returns
`nothing`.
"""
function PSI.add_proportional_cost!(
        container::PSI.OptimizationContainer, slack::S,
        devices::Union{Vector{T}, IS.FlattenIteratorWrapper{T}}, ::AbstractNEMDispatch,
    ) where {S <: AbstractEnergyOfferSlack, T <: PSY.StaticInjection}
    selected = _energy_offer_devices(devices, S)
    isempty(selected) && return
    _add_mpc_penalty!(container, S, T, [PSY.get_name(d) for d in selected], ENERGY_OFFER_CVP_FACTOR)
    return
end


"""
    _check_storage_offer_sides(devices)

Throws `ArgumentError` for a storage device with an energy offer on one side only, which would price
the other side at zero. A device with no energy offer (an FCAS-only unit) passes.

# Returns
`nothing`.
"""
function _check_storage_offer_sides(devices)
    for d in devices
        has = [PSY.has_time_series(d, PSY.SingleTimeSeries, energy_offer_series_name(side)) for side in (OfferSide.GEN, OfferSide.LOAD)]
        (has[1] == has[2]) && continue
        side = has[1] ? "LOAD" : "GEN"
        throw(
            ArgumentError(
                "$(PSY.get_name(d)): the device has an energy offer on the other side but no $side " *
                    "energy offer series, so this side would be priced at zero. Add the $side offer or remove the other side's.",
            ),
        )
    end
    return
end


"""
    _energy_band_count(devices) -> Int

The most bands any offer of `devices` has, on either side, over the whole of its `energy_offer`
series; at least 1.

# Returns
`Int`.
"""
function _energy_band_count(devices)
    n = 1
    for d in devices, side in (OfferSide.GEN, OfferSide.LOAD)
        name = energy_offer_series_name(side)
        PSY.has_time_series(d, PSY.SingleTimeSeries, name) || continue
        n = max(n, maximum(c -> length(PSY.get_y_coords(c)), PSY.get_time_series_values(PSY.SingleTimeSeries, d, name)))
    end
    return n
end

function PSI.get_multiplier_value(::Union{EnergyBandWidthParameter, EnergyBandPriceParameter}, ::PSY.StaticInjection, ::AbstractNEMDispatch)
    return 1.0
end

# The band axis of the energy offer parameters.
function PSI.calc_additional_axes(
        ::PSI.OptimizationContainer, ::Union{EnergyBandWidthParameter, EnergyBandPriceParameter},
        devices::Union{Vector{D}, IS.FlattenIteratorWrapper{D}}, ::PSI.DeviceModel{D, <:AbstractNEMDispatch},
    ) where {D <: PSY.StaticInjection}
    return (string.(1:_energy_band_count(devices)),)
end

"""
    _add_energy_offer_bands!(container, devices, model, side)

Prices the energy offer of the `devices` of `model` that carry the `energy_offer` series of `side`:
one [`EnergyOfferBandVariable`](@ref) per band (labelled `"1"` to `"n"`), bounded by its [`EnergyBandWidthParameter`](@ref)
width, summing with the offer's surplus and deficit slacks to the dispatch variable the side prices
([`EnergyOfferBandConstraint`](@ref)), and costed through [`EnergyBandPriceParameter`](@ref) at the
band price times the system base power and the interval hours, negative on the `LOAD` side. Band
prices are the loss-factor referred prices of the series. Devices without the series add nothing.

# Arguments
- `container`: the optimization container of the model being built.
- `devices`: the devices of `model`.
- `model`: the `PSI.DeviceModel` supplying the device model of the parameters.
- `side`: the [`OfferSide`](@ref) to price.

# Returns
`nothing`.
"""
function _add_energy_offer_bands!(
        container::PSI.OptimizationContainer, devices::Union{Vector{T}, IS.FlattenIteratorWrapper{T}},
        model::PSI.DeviceModel{T, <:AbstractNEMDispatch}, side::OfferSide,
    ) where {T <: PSY.StaticInjection}
    selected = _energy_offer_devices(devices, side)
    isempty(selected) && return
    names = [PSY.get_name(d) for d in selected]
    meta = _energy_offer_meta(side)
    time_steps = PSI.get_time_steps(container)
    jm = PSI.get_jump_model(container)
    labels = string.(1:_energy_band_count(selected))

    bands = PSI.add_variable_container!(container, EnergyOfferBandVariable(), T, names, labels, time_steps; meta)
    for name in names, label in labels, t in time_steps
        bands[name, label, t] = JuMP.@variable(jm, lower_bound = 0.0, base_name = "EnergyOfferBandVariable_$(meta)_{$name,$label,$t}")
    end

    series = energy_offer_series_name(side)
    PSI.add_parameters!(container, EnergyBandWidthParameter, selected, model; meta, time_series_name = series)
    PSI.add_parameters!(container, EnergyBandPriceParameter, selected, model; meta, time_series_name = series)

    power = PSI.get_variable(container, _energy_offer_power_variable(T, side)(), T)
    above_type, below_type = _energy_offer_slacks(side)
    above = PSI.get_variable(container, above_type(), T)
    below = PSI.get_variable(container, below_type(), T)
    widths = PSI.get_parameter(container, EnergyBandWidthParameter(), T, meta)
    width_multiplier = PSI.get_multiplier_array(widths)
    rows = PSI.add_constraints_container!(container, EnergyOfferBandConstraint(), T, names, time_steps; meta)
    base_power = PSI.get_base_power(container)
    for name in names
        width_refs = PSI.get_parameter_column_refs(widths, name)
        for t in time_steps
            for label in labels
                JuMP.@constraint(jm, bands[name, label, t] <= width_multiplier[name, label, t] * width_refs[label, t] / base_power)
            end
            rows[name, t] = JuMP.@constraint(
                jm, power[name, t] == sum(bands[name, label, t] for label in labels) + above[name, t] - below[name, t]
            )
        end
    end

    key = PSI.ParameterKey(EnergyBandPriceParameter, T, meta)
    direction = side == OfferSide.GEN ? 1.0 : -1.0
    scale = direction * base_power * interval_hours(PSI.get_resolution(container))
    for name in names, (b, label) in enumerate(labels), t in time_steps
        PSI.add_cost_target!(container, key, name, (b,), t, bands[name, label, t], scale)
    end
    return
end
