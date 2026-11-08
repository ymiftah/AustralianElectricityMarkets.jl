"""
    loss_demand_coefficient(model::InterconnectorLossModel, demand::AbstractDict) -> Float64

The demand term of an interchange's loss factor, `Σ_r demand_coefficients[r] × demand[r]`, in the
units of `demand`, where `demand[r]` is the summed demand of region `r` and a region the model does
not name contributes zero.

# Arguments
- `model`: the interchange's [`InterconnectorLossModel`](@ref).
- `demand`: the summed demand per region name, in the caller's units.

# Returns
A `Float64`, in the units of `demand`.
"""
function loss_demand_coefficient(model::InterconnectorLossModel, demand::AbstractDict)
    return sum((c * get(demand, r, 0.0) for (r, c) in model.demand_coefficients); init = 0.0)
end


"""
    set_loss_demand_coefficients!(sys)

Attaches to each `PowerSystems.AreaInterchange` carrying exactly one
[`InterconnectorLossModel`](@ref) a `SingleTimeSeries` `"loss_demand_coefficient"`: at each
interval, the demand term of its loss factor, [`loss_demand_coefficient`](@ref) of the region
demands. A region's demand is the summed demand of the available `PowerSystems.PowerLoad`s in it,
per unit of the system base, from each load's `"loss_demand"` series that the demand build writes.
The series sits on the timestamps of those series and replaces an existing one. A system whose
interchanges carry no [`InterconnectorLossModel`](@ref) is left unchanged.

[`set_effective_offers!`](@ref) calls it, so it runs after the demand build and before
`transform_single_time_series!`.

# Arguments
- `sys`: the `System` to add to.

# Returns
`nothing`. Throws `ArgumentError` when the system has no available load, when an available load is
on a bus with no area or has no `"loss_demand"` series, or when two loads' series have different
timestamps.
"""
function set_loss_demand_coefficients!(sys::PSY.System)
    modelled = [
        interchange for interchange in PSY.get_components(PSY.AreaInterchange, sys) if
            length(PSY.get_supplemental_attributes(InterconnectorLossModel, interchange)) == 1
    ]
    # A system with no loss-modelled interchange needs no demand term, and may carry no loads at all.
    isempty(modelled) && return
    stamps, resolution, demand = _area_loss_demand(sys)
    for interchange in modelled
        model = only(PSY.get_supplemental_attributes(InterconnectorLossModel, interchange))
        values = [
            loss_demand_coefficient(model, Dict(area => series[i] for (area, series) in demand)) for
                i in eachindex(stamps)
        ]
        replace_single_series!(
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
    isempty(loads) && throw(ArgumentError("set_loss_demand_coefficients!: the system has no available PowerLoad."))
    for load in loads
        isnothing(PSY.get_area(PSY.get_bus(load))) && throw(
            ArgumentError(
                "PowerLoad $(PSY.get_name(load)) is on a bus with no area; the interconnector loss " *
                    "demand needs every available load assigned to an area",
            ),
        )
        has_time_series(load, PSY.SingleTimeSeries, "loss_demand") || throw(
            ArgumentError(
                "set_loss_demand_coefficients!: PowerLoad $(PSY.get_name(load)) has no \"loss_demand\" series; " *
                    "attach the demand after the loads are added.",
            ),
        )
    end
    reference = first(loads)
    stamps = PSY.get_time_series_timestamps(PSY.SingleTimeSeries, reference, "loss_demand")
    resolution = IS.get_resolution(PSY.get_time_series(PSY.SingleTimeSeries, reference, "loss_demand"))
    demand = Dict{String, Vector{Float64}}()
    with_units_base(sys, "SYSTEM_BASE") do
        for load in loads
            PSY.get_time_series_timestamps(PSY.SingleTimeSeries, load, "loss_demand") == stamps || throw(
                ArgumentError(
                    "set_loss_demand_coefficients!: PowerLoad $(PSY.get_name(load))'s \"loss_demand\" series is not on " *
                        "the timestamps of $(PSY.get_name(reference))'s.",
                ),
            )
            total = get!(() -> zeros(Float64, length(stamps)), demand, PSY.get_name(PSY.get_area(PSY.get_bus(load))))
            total .+= PSY.get_time_series_values(PSY.SingleTimeSeries, load, "loss_demand")
        end
    end
    return stamps, resolution, demand
end
