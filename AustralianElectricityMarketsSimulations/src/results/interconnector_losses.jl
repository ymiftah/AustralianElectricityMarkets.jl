# The one variable key of entry type `T` on a `PSY.AreaInterchange`, or `nothing` when there is none.
function _interchange_key(results, T::Type)
    found = [
        k for k in PSI.list_variable_keys(results)
            if PSI.IS.Optimization.get_entry_type(k) === T && PSI.IS.Optimization.get_component_type(k) === PSY.AreaInterchange
    ]
    return isempty(found) ? nothing : only(found)
end


# One-based position of `stamp` on the grid of spacing `step` that starts at `origin`.
function _interval_offset(stamp::DateTime, origin::DateTime, step::Dates.Period)
    steps, remainder = divrem(Dates.value(stamp - origin), Dates.value(Millisecond(step)))
    iszero(remainder) || throw(ArgumentError("$stamp is not on the grid of $step starting at $origin"))
    return steps + 1
end


# Loss gap rows of every interconnector with one loss model, from the flow and loss variable frames
# (`DateTime`, `name`, `value`), and the loss-share weights of those interconnectors.
function _interconnector_loss_rows(sys::PSY.System, flow_df::DataFrame, loss_df::DataFrame)
    stamps = sort(unique(flow_df.DateTime))
    base_power = PSY.get_base_power(sys)
    flows = Dict((r.name, r.DateTime) => r.value for r in eachrow(flow_df))
    losses = Dict((r.name, r.DateTime) => r.value for r in eachrow(loss_df))
    rows = DataFrame(
        interconnector = String[], DateTime = DateTime[], flow_mw = Float64[],
        solved_loss_mw = Float64[], curve_loss_mw = Float64[], gap_mw = Float64[],
    )
    weights = DataFrame(interconnector = String[], from_region = String[], to_region = String[], share = Float64[])
    isempty(stamps) && return rows, weights
    for d in PSY.get_components(PSY.AreaInterchange, sys)
        name = PSY.get_name(d)
        models = PSY.get_supplemental_attributes(InterconnectorLossModel, d)::Vector{InterconnectorLossModel}
        length(models) == 1 || continue
        model = only(models)
        push!(weights, (name, model.from_region, model.to_region, model.from_region_loss_share))
        at_zero = loss_curve_vertex_values(model, Dict{String, Float64}())
        # The coefficient series spans every interval from the first stamp to the last, including skipped ones.
        series = PSY.get_time_series(PSY.SingleTimeSeries, d, NEM_SERIES.loss_demand_coefficient)
        step = IS.get_resolution(series)
        coefficients = PSY.get_time_series_values(
            PSY.SingleTimeSeries, d, NEM_SERIES.loss_demand_coefficient;
            start_time = first(stamps), len = _interval_offset(last(stamps), first(stamps), step),
        )
        for stamp in stamps
            haskey(flows, (name, stamp)) || continue
            t = _interval_offset(stamp, first(stamps), step)
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
    return rows, weights
end


"""
    read_interconnector_loss_gaps(results, sys::PSY.System) -> DataFrame

Reads each interconnector's solved loss against the loss curve at its solved flow, for every interval
with a solved flow. The reference is the full curve stored on the `System`, so under `loss_breakpoints`
`gap_mw` also includes the thinning error (the solver used the thinned curve), and it can be negative.
`gap_mw` is zero where the solved loss equals the full curve.

# Arguments
- `results`: `PSI.OptimizationProblemResults` of a model using `NEMInterconnectorLoss`, or
  `PSI.SimulationProblemResults` of a simulation (its realized values).
- `sys`: the `System` the model was built from.

# Returns
A `DataFrame` with columns `interconnector`, `DateTime`, `flow_mw`, `solved_loss_mw`, `curve_loss_mw`,
`gap_mw` (MW) and `weighted_loss_price` (`\$/MWh`), where `weighted_loss_price` is
`share * ROP_from + (1 - share) * ROP_to` from [`read_prices`](@ref). The table is empty when the
results hold no interchange flow or no `InterconnectorLossVariable`, as in a lossless run.
"""
function read_interconnector_loss_gaps(results, sys::PSY.System)
    flow_key = _interchange_key(results, PSI.FlowActivePowerVariable)
    loss_key = _interchange_key(results, InterconnectorLossVariable)
    if isnothing(flow_key) || isnothing(loss_key)
        return DataFrame(
            interconnector = String[], DateTime = DateTime[], flow_mw = Float64[], solved_loss_mw = Float64[],
            curve_loss_mw = Float64[], gap_mw = Float64[], weighted_loss_price = Float64[],
        )
    end
    frames = _read_variable_frames(results, [flow_key, loss_key])
    rows, weights = _interconnector_loss_rows(sys, frames[flow_key], frames[loss_key])
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
