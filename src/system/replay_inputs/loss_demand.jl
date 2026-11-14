# The demand term of each loss-modelled interchange's loss factor, from the loads' `"loss_demand"` series.


"""
    _set_loss_demand_coefficients!(sys::PSY.System) -> Nothing

Adds to each `PowerSystems.AreaInterchange` carrying exactly one [`InterconnectorLossModel`](@ref) the
`SingleTimeSeries` [`NEM_SERIES`](@ref)`.loss_demand_coefficient`: at each interval, the demand term of its
loss factor, [`loss_demand_coefficient`](@ref) of the region demands. A region's demand is the summed demand
of the available `PowerLoad`s in it, per unit of the system base, from each load's `"loss_demand"` series.
The series sits on the timestamps of those series. A system whose interchanges carry no
[`InterconnectorLossModel`](@ref) is left unchanged.

# Arguments
- `sys`: the `System` to add to, with its `"loss_demand"` load series already written.

# Returns
`nothing`. Throws `ArgumentError` when the system has no available load, when an available load is
on a bus with no area or has no `"loss_demand"` series, or when two loads' series have different
timestamps.
"""
function _set_loss_demand_coefficients!(sys::PSY.System)
    modelled = [
        interchange for interchange in PSY.get_components(PSY.AreaInterchange, sys) if
            length((PSY.get_supplemental_attributes(InterconnectorLossModel, interchange)::Vector{InterconnectorLossModel})) == 1
    ]
    # A system with no loss-modelled interchange needs no demand term, and may carry no loads.
    isempty(modelled) && return
    stamps, resolution, demand = _area_loss_demand(sys)
    for interchange in modelled
        model = only((PSY.get_supplemental_attributes(InterconnectorLossModel, interchange)::Vector{InterconnectorLossModel}))
        values = [
            loss_demand_coefficient(model, Dict(area => series[i] for (area, series) in demand)) for
                i in eachindex(stamps)
        ]
        PSY.add_time_series!(
            sys, interchange,
            single_series(NEM_SERIES.loss_demand_coefficient, first(stamps), values, resolution),
        )
    end
    return
end


# The summed demand of `sys`'s available `PowerLoad`s per area name, per unit of the system base, on
# the timestamps of their `"loss_demand"` series.
function _area_loss_demand(sys::PSY.System)
    loads = collect(PSY.get_components(PSY.get_available, PSY.PowerLoad, sys))
    isempty(loads) && throw(ArgumentError("loss demand coefficients: the system has no available PowerLoad."))
    for load in loads
        isnothing(PSY.get_area(PSY.get_bus(load))) && throw(
            ArgumentError(
                "PowerLoad $(PSY.get_name(load)) is on a bus with no area; the interconnector loss " *
                    "demand needs every available load assigned to an area",
            ),
        )
        PSY.has_time_series(load, PSY.SingleTimeSeries, "loss_demand") || throw(
            ArgumentError(
                "loss demand coefficients: PowerLoad $(PSY.get_name(load)) has no \"loss_demand\" series; " *
                    "the demand must be written before the replay inputs.",
            ),
        )
    end
    reference = first(loads)
    stamps = PSY.get_time_series_timestamps(PSY.SingleTimeSeries, reference, "loss_demand")
    resolution = IS.get_resolution(PSY.get_time_series(PSY.SingleTimeSeries, reference, "loss_demand"))
    demand = Dict{String, Vector{Float64}}()
    for load in loads
        PSY.get_time_series_timestamps(PSY.SingleTimeSeries, load, "loss_demand") == stamps || throw(
            ArgumentError(
                "loss demand coefficients: PowerLoad $(PSY.get_name(load))'s \"loss_demand\" series is not on " *
                    "the timestamps of $(PSY.get_name(reference))'s.",
            ),
        )
        # Stored values times the load's per-unit max power, so the result ignores the System's units setting.
        per_unit = PSY.get_time_series_values(PSY.SingleTimeSeries, load, "loss_demand"; ignore_scaling_factors = true) .*
            ((PSY.get_base_power(load) / PSY.get_base_power(sys)) * load.max_active_power)
        total = get!(() -> zeros(Float64, length(stamps)), demand, PSY.get_name(PSY.get_area(PSY.get_bus(load))))
        total .+= per_unit
    end
    return stamps, resolution, demand
end
