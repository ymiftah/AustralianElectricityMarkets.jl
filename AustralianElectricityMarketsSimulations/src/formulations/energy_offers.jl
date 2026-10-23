function _energy_offer_curve(::Type{<:Union{EnergyOfferSurplusSlack, EnergyOfferDeficitSlack}})
    return PSY.get_incremental_offer_curves
end

function _energy_offer_curve(::Type{<:Union{EnergyDecrementalOfferSurplusSlack, EnergyDecrementalOfferDeficitSlack}})
    return PSY.get_decremental_offer_curves
end

function _energy_offer_devices(devices::Union{Vector{T}, IS.FlattenIteratorWrapper{T}}, ::Type{S}) where {T, S <: AbstractEnergyOfferSlack}
    curve = _energy_offer_curve(S)
    return T[d for d in devices if PSY.get_operation_cost(d) isa PSY.MarketBidCost && !isnothing(curve(PSY.get_operation_cost(d)))]
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

function _energy_offer_slacks(::Type{PSI.PiecewiseLinearBlockIncrementalOffer})
    return EnergyOfferSurplusSlack, EnergyOfferDeficitSlack
end

function _energy_offer_slacks(::Type{PSI.PiecewiseLinearBlockDecrementalOffer})
    return EnergyDecrementalOfferSurplusSlack, EnergyDecrementalOfferDeficitSlack
end

"""
    PSI.add_proportional_cost!(container, slack, devices, formulation)

Prices each total-offer mismatch at CVP1135 times the Market Price Cap, with system-base MW
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
