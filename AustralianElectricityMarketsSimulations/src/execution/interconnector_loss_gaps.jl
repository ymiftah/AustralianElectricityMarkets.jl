"""
    interconnector_loss_gaps(results, sys) -> Dict{Tuple{String, Int}, Float64}

`InterconnectorLossVariable`'s solved value minus the loss curve's breakpoint interpolation at
the solved `PSI.FlowActivePowerVariable`, per `(interconnector name, t)`, in natural MW. Zero
wherever the segment allocation reproduces the loss curve's chord value at that flow; positive
where the solver dissipated more than the curve at that flow.

# Arguments
- `results`: `PSI.OptimizationProblemResults` of one solved standalone `DecisionModel` using
  [`NEMInterconnectorLoss`](@ref); the loss curve at each result timestamp takes its demand term
  from the interchange's `"loss_demand_coefficient"` series.
- `sys`: the `System` the model was built from.

# Returns
A `Dict` keyed by `(interconnector name, t)`.
"""
function interconnector_loss_gaps(results::PSI.OptimizationProblemResults, sys::PSY.System)
    flow_df = PSI.read_variable(results, PSI.FlowActivePowerVariable, PSY.AreaInterchange)
    loss_df = PSI.read_variable(results, InterconnectorLossVariable, PSY.AreaInterchange)
    stamps = sort(unique(flow_df.DateTime))
    base_power = PSY.get_base_power(sys)
    flows = Dict((r.name, r.DateTime) => r.value for r in eachrow(flow_df))
    losses = Dict((r.name, r.DateTime) => r.value for r in eachrow(loss_df))
    gaps = Dict{Tuple{String, Int}, Float64}()
    for d in PSY.get_components(PSY.AreaInterchange, sys)
        name = PSY.get_name(d)
        models = PSY.get_supplemental_attributes(InterconnectorLossModel, d)
        length(models) == 1 || continue
        model = only(models)
        at_zero = loss_curve_vertex_values(model, Dict{String, Float64}())
        coefficients = PSY.get_time_series_values(
            PSY.SingleTimeSeries, d, NEM_SERIES.loss_demand_coefficient; start_time = first(stamps), len = length(stamps),
        )
        for (t, stamp) in enumerate(stamps)
            haskey(flows, (name, stamp)) || continue
            flow_pu = flows[(name, stamp)] / base_power
            vertex_losses = at_zero .+ coefficients[t] .* model.breakpoints
            segment = clamp(searchsortedlast(model.breakpoints, flow_pu), 1, length(model.breakpoints) - 1)
            lo, hi = model.breakpoints[segment:(segment + 1)]
            loss_lo, loss_hi = vertex_losses[segment], vertex_losses[segment + 1]
            curve_pu = loss_lo + (flow_pu - lo) * (loss_hi - loss_lo) / (hi - lo)
            gaps[(name, t)] = losses[(name, stamp)] - curve_pu * base_power
        end
    end
    return gaps
end


"""
    check_interconnector_loss_segments(results, sys; tolerance = 1.0e-3)

Calls [`interconnector_loss_gaps`](@ref) and `@warn`s once, naming every `(interconnector, t)`
whose absolute gap exceeds `tolerance` MW.

# Returns
The `Dict` from [`interconnector_loss_gaps`](@ref).
"""
function check_interconnector_loss_segments(
        results::PSI.OptimizationProblemResults, sys::PSY.System; tolerance::Float64 = 1.0e-3,
    )
    gaps = interconnector_loss_gaps(results, sys)
    flagged = [(k, v) for (k, v) in gaps if abs(v) > tolerance]
    isempty(flagged) ||
        @warn "check_interconnector_loss_segments: $(length(flagged)) (interconnector, t) pair(s) have a solved loss that does not match the loss curve at the solved flow" flagged
    return gaps
end
