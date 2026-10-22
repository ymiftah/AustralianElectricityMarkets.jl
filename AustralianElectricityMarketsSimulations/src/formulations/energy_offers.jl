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
    PSI.add_constraints!(container, constraint_type, component, variable, formulation, breakpoints, period, band_type)

Links dispatch to cleared energy bands with separately priced positive and negative mismatches.
Preserves individual live band-width bounds and PSI's constant first-breakpoint offset.

# Returns
`nothing`.
"""
function PSI.add_constraints!(
        container::PSI.OptimizationContainer, ::Type{W}, component::T, ::U, ::D,
        breakpoints::Vector{<:PSI.JuMPOrFloat}, period::Int, ::Type{V},
    ) where {
        T <: PSY.StaticInjection, U <: PSI.VariableType, D <: AbstractNEMDispatch,
        V <: PSI.AbstractPiecewiseLinearBlockOffer, W <: PSI.AbstractPiecewiseLinearBlockOfferConstraint,
    }
    jm = PSI.get_jump_model(container)
    power = PSI.get_variable(container, U(), T)
    bands = PSI.get_variable(container, V(), T)
    name = PSY.get_name(component)
    rows = PSI.lazy_container_addition!(container, W(), T, axes(power)...)
    above_type, below_type = _energy_offer_slacks(V)
    above = PSI.get_variable(container, above_type(), T)[name, period]
    below = PSI.get_variable(container, below_type(), T)[name, period]
    offered = sum(bands[name, k, period] for k in 1:(length(breakpoints) - 1))
    if PSI._include_constant_min_gen_power_in_constraint(component, U(), D())
        offered += PSI.jump_fixed_value(first(breakpoints))::Float64
    elseif PSI._include_min_gen_power_in_constraint(component, U(), D())
        on = PSI.get_variable(container, PSI.OnVariable(), T)
        offered += (PSI.jump_fixed_value(first(breakpoints))::Float64) * on[name, period]
    end
    rows[name, period] = JuMP.@constraint(jm, power[name, period] == offered + above - below)
    for k in 1:(length(breakpoints) - 1)
        JuMP.@constraint(jm, bands[name, k, period] <= breakpoints[k + 1] - breakpoints[k])
    end
    return
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
    _add_mpc_penalty!(
        container, PSI.get_variable(container, slack, T), [PSY.get_name(d) for d in selected],
        PSI.get_time_steps(container), ENERGY_OFFER_CVP_FACTOR,
    )
    return
end
