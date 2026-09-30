"""
    interconnector_loss_gaps(container, sys) -> Dict{Tuple{String, Int}, Float64}

`InterconnectorLossVariable`'s solved value minus [`interconnector_losses`](@ref) evaluated at
the solved `PSI.FlowActivePowerVariable`, per `(interconnector name, t)`, in natural MW. Exactly
zero wherever the segment allocation reproduces the loss curve's own chord value at that flow;
a nonzero gap is possible only where minimising loss was not in the objective's interest (see
`NEMInterconnectorLoss`'s docstring).

# Returns
A `Dict` keyed by `(interconnector name, t)`.
"""
function interconnector_loss_gaps(container::PSI.OptimizationContainer, sys::PSY.System)
    devices = PSY.get_components(PSY.AreaInterchange, sys)
    base_power = PSI.get_base_power(container)
    flow_var = PSI.get_variable(container, PSI.FlowActivePowerVariable(), PSY.AreaInterchange)
    loss_var = PSI.get_variable(container, InterconnectorLossVariable(), PSY.AreaInterchange)
    time_steps = PSI.get_time_steps(container)
    area_demand = _area_demand(container, sys)
    gaps = Dict{Tuple{String, Int}, Float64}()
    for d in devices
        name = PSY.get_name(d)
        models = PSY.get_supplemental_attributes(InterconnectorLossModel, d)
        length(models) == 1 || continue
        model = only(models)
        for t in time_steps
            flow = JuMP.value(flow_var[name, t])
            solved_loss = JuMP.value(loss_var[name, t]) * base_power
            curve_loss = interconnector_losses(model, flow, _demand_at(area_demand, t)) * base_power
            gaps[(name, t)] = solved_loss - curve_loss
        end
    end
    return gaps
end

"""
    check_interconnector_loss_segments(container, sys; tolerance = 1.0e-3)

Calls [`interconnector_loss_gaps`](@ref) and `@warn`s once, naming every `(interconnector, t)`
whose gap exceeds `tolerance` MW in absolute value.

# Returns
The `Dict` from [`interconnector_loss_gaps`](@ref).
"""
function check_interconnector_loss_segments(
        container::PSI.OptimizationContainer, sys::PSY.System; tolerance::Float64 = 1.0e-3,
    )
    gaps = interconnector_loss_gaps(container, sys)
    flagged = [(k, v) for (k, v) in gaps if abs(v) > tolerance]
    isempty(flagged) ||
        @warn "check_interconnector_loss_segments: $(length(flagged)) (interconnector, t) pair(s) have a solved loss that does not match the loss curve at the solved flow" flagged
    return gaps
end
