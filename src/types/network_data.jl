IS.@scoped_enum(MNSPDirection, FORWARD = 1, REVERSE = 2)

@doc """
    MNSPDirection

The direction of one MNSP bid: `FORWARD` for flow from the interchange's `from_area` to its `to_area`,
`REVERSE` for the opposite flow.
""" MNSPDirection


"""
    NEMInterconnectorLimits(; from_to_limit, to_from_limit)

An interconnector's flow limits as AEMO publishes them, in MW. Each field is a static value or a key of
the time series that holds it on the owning `AreaInterchange`.

# Fields
- `from_to_limit`: the limit on flow from the from-region to the to-region, MW.
- `to_from_limit`: the limit on flow from the to-region to the from-region, MW.
- `internal`: `InfrastructureSystems` bookkeeping.
"""
struct NEMInterconnectorLimits <: PSY.SupplementalAttribute
    from_to_limit::Union{IS.TimeSeriesKey, Float64}
    to_from_limit::Union{IS.TimeSeriesKey, Float64}
    internal::IS.InfrastructureSystemsInternal
end

function NEMInterconnectorLimits(;
        from_to_limit, to_from_limit,
        internal::IS.InfrastructureSystemsInternal = IS.InfrastructureSystemsInternal(),
    )
    return NEMInterconnectorLimits(_bid_number(from_to_limit), _bid_number(to_from_limit), internal)
end

IS.get_internal(limits::NEMInterconnectorLimits) = limits.internal


"""
    NEMMNSPBid(; direction, offer_curves, max_avail, ramp_up, ramp_down, fixed_load = nothing)

One direction of an MNSP's offer as AEMO bid it, held on the MNSP's `AreaInterchange`. Each field is a
static value or a key of the time series that holds it on that interchange, or `nothing` where AEMO
publishes no value.

# Fields
- `direction`: the [`MNSPDirection`](@ref).
- `offer_curves`: the price bands, in MW and \$/MWh, as `PiecewiseStepData`.
- `max_avail`: the maximum availability, MW.
- `ramp_up`: the ramp-up rate, as AEMO publishes it.
- `ramp_down`: the ramp-down rate, as AEMO publishes it.
- `fixed_load`: the fixed loading, MW.
- `internal`: `InfrastructureSystems` bookkeeping.
"""
struct NEMMNSPBid <: PSY.SupplementalAttribute
    direction::MNSPDirection
    offer_curves::Union{IS.TimeSeriesKey, PiecewiseStepData}
    max_avail::Union{IS.TimeSeriesKey, Float64}
    ramp_up::Union{IS.TimeSeriesKey, Float64}
    ramp_down::Union{IS.TimeSeriesKey, Float64}
    fixed_load::Union{Nothing, IS.TimeSeriesKey, Float64}
    internal::IS.InfrastructureSystemsInternal
end

function NEMMNSPBid(;
        direction::MNSPDirection, offer_curves, max_avail, ramp_up, ramp_down, fixed_load = nothing,
        internal::IS.InfrastructureSystemsInternal = IS.InfrastructureSystemsInternal(),
    )
    return NEMMNSPBid(
        direction, offer_curves, _bid_number(max_avail), _bid_number(ramp_up), _bid_number(ramp_down),
        _bid_number(fixed_load), internal,
    )
end

IS.get_internal(bid::NEMMNSPBid) = bid.internal


"""
    NEMMNSPObservedState(; initial_flow)

The MNSP's published flow from `DISPATCHLOAD`, held on its `AreaInterchange`.

# Fields
- `initial_flow`: `METEREDMWFLOW`, the flow at the start of the interval, MW.
- `internal`: `InfrastructureSystems` bookkeeping.
"""
struct NEMMNSPObservedState <: PSY.SupplementalAttribute
    initial_flow::Union{IS.TimeSeriesKey, Float64}
    internal::IS.InfrastructureSystemsInternal
end

function NEMMNSPObservedState(;
        initial_flow, internal::IS.InfrastructureSystemsInternal = IS.InfrastructureSystemsInternal(),
    )
    return NEMMNSPObservedState(_bid_number(initial_flow), internal)
end

IS.get_internal(state::NEMMNSPObservedState) = state.internal
