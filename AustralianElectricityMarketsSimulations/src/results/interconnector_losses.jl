# The one variable key of entry type `T` on a `PSY.AreaInterchange`, or `nothing` when there is none.
function _interchange_key(results, T::Type)
    found = [
        k for k in PSI.list_variable_keys(results)
            if PSI.IS.Optimization.get_entry_type(k) === T && PSI.IS.Optimization.get_component_type(k) === PSY.AreaInterchange
    ]
    return isempty(found) ? nothing : only(found)
end


"""
    read_interconnector_loss_gaps(results, sys::PSY.System) -> DataFrame

Reads each interconnector's solved loss against the loss curve at its solved flow, for every interval
with a solved flow. `gap_mw` is zero where the segment allocation reproduces the curve, and positive
where the solver dissipated more than the curve at that flow.

# Arguments
- `results`: `PSI.OptimizationProblemResults` of a model using `NEMInterconnectorLoss`, or
  `PSI.SimulationProblemResults` of a simulation (its realized values).
- `sys`: the `System` the model was built from.

# Returns
A `DataFrame` with columns `interconnector`, `DateTime`, `flow_mw`, `solved_loss_mw`, `curve_loss_mw`,
`gap_mw` (MW) and `weighted_loss_price` (`\$/MWh`), where `weighted_loss_price` is
`share * ROP_from + (1 - share) * ROP_to` from [`read_prices`](@ref). The table is empty when the
results hold no interchange flow. Throws when they hold flows but no `InterconnectorLossVariable`.
"""
function read_interconnector_loss_gaps(results, sys::PSY.System)
    flow_key = _interchange_key(results, PSI.FlowActivePowerVariable)
    isnothing(flow_key) && return DataFrame(
        interconnector = String[], DateTime = DateTime[], flow_mw = Float64[], solved_loss_mw = Float64[],
        curve_loss_mw = Float64[], gap_mw = Float64[], weighted_loss_price = Float64[],
    )
    loss_key = _interchange_key(results, InterconnectorLossVariable)
    isnothing(loss_key) && throw(
        ArgumentError("read_interconnector_loss_gaps: the results hold AreaInterchange flows but no InterconnectorLossVariable."),
    )
    frames = _read_variable_frames(results, [flow_key, loss_key])
    flow_df, loss_df = frames[flow_key], frames[loss_key]
    stamps = sort(unique(flow_df.DateTime))
    base_power = PSY.get_base_power(sys)
    flows = Dict((r.name, r.DateTime) => r.value for r in eachrow(flow_df))
    losses = Dict((r.name, r.DateTime) => r.value for r in eachrow(loss_df))
    rows = DataFrame(
        interconnector = String[], DateTime = DateTime[], flow_mw = Float64[],
        solved_loss_mw = Float64[], curve_loss_mw = Float64[], gap_mw = Float64[],
    )
    weights = DataFrame(interconnector = String[], from_region = String[], to_region = String[], share = Float64[])
    for d in PSY.get_components(PSY.AreaInterchange, sys)
        name = PSY.get_name(d)
        models = PSY.get_supplemental_attributes(InterconnectorLossModel, d)::Vector{InterconnectorLossModel}
        length(models) == 1 || continue
        model = only(models)
        push!(weights, (name, model.from_region, model.to_region, model.from_region_loss_share))
        at_zero = loss_curve_vertex_values(model, Dict{String, Float64}())
        coefficients = PSY.get_time_series_values(
            PSY.SingleTimeSeries, d, NEM_SERIES.loss_demand_coefficient; start_time = first(stamps), len = length(stamps),
        )
        for (t, stamp) in enumerate(stamps)
            haskey(flows, (name, stamp)) || continue
            flow_mw = flows[(name, stamp)]
            flow_pu = flow_mw / base_power
            # The loss curve is linear between breakpoints, so interpolate its vertex values at the flow.
            vertex_losses = at_zero .+ coefficients[t] .* model.breakpoints
            segment = clamp(searchsortedlast(model.breakpoints, flow_pu), 1, length(model.breakpoints) - 1)
            lo, hi = model.breakpoints[segment:(segment + 1)]
            loss_lo, loss_hi = vertex_losses[segment], vertex_losses[segment + 1]
            curve_pu = loss_lo + (flow_pu - lo) * (loss_hi - loss_lo) / (hi - lo)
            curve_mw = curve_pu * base_power
            push!(rows, (name, stamp, flow_mw, losses[(name, stamp)], curve_mw, losses[(name, stamp)] - curve_mw))
        end
    end
    prices = read_prices(results, sys)
    from_prices = select(prices, :SETTLEMENTDATE => :DateTime, :REGIONID => :from_region, :ROP => :price_from)
    to_prices = select(prices, :SETTLEMENTDATE => :DateTime, :REGIONID => :to_region, :ROP => :price_to)
    return @chain rows begin
        leftjoin(weights; on = :interconnector)
        leftjoin(from_prices; on = [:DateTime, :from_region])
        leftjoin(to_prices; on = [:DateTime, :to_region])
        transform([:share, :price_from, :price_to] => ByRow((s, pf, pt) -> s * pf + (1 - s) * pt) => :weighted_loss_price)
        select(:interconnector, :DateTime, :flow_mw, :solved_loss_mw, :curve_loss_mw, :gap_mw, :weighted_loss_price)
    end
end
