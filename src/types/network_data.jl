IS.@scoped_enum(MNSPDirection, FORWARD = 1, REVERSE = 2)

@doc """
    MNSPDirection

The direction of one MNSP bid: `FORWARD` for flow from the interchange's `from_area` to its `to_area`,
`REVERSE` for the opposite flow.
""" MNSPDirection

IS.@scoped_enum(InterconnectorKind, REGULATED = 1, MNSP = 2)

@doc """
    InterconnectorKind

AEMO's `INTERCONNECTORCONSTRAINT.ICTYPE`: `REGULATED` for an interconnector with no offers, `MNSP` for
one whose flow AEMO dispatches through two directional offers.
""" InterconnectorKind


"""
    NEMInterconnectorRegistration(; kind)

An interconnector's `ICTYPE` as AEMO publishes it, held on its `AreaInterchange`.

# Fields
- `kind`: the [`InterconnectorKind`](@ref).
- `internal`: `InfrastructureSystems` bookkeeping.
"""
struct NEMInterconnectorRegistration <: PSY.SupplementalAttribute
    kind::InterconnectorKind
    internal::IS.InfrastructureSystemsInternal
end

function NEMInterconnectorRegistration(;
        kind::InterconnectorKind, internal::IS.InfrastructureSystemsInternal = IS.InfrastructureSystemsInternal(),
    )
    return NEMInterconnectorRegistration(kind, internal)
end

IS.get_internal(registration::NEMInterconnectorRegistration) = registration.internal


"""
    NEMInterconnectorLimits(; from_to_limit, to_from_limit)

An interconnector's flow limits derived from the signed flow range AEMO publishes, in MW. Each field is a static
value or a key of the time series that holds it on the owning `AreaInterchange`.

# Fields
- `from_to_limit`: the negated lower bound of the published signed flow range, MW. For a published
  `[IMPORTLIMIT, EXPORTLIMIT]` it holds `-min(IMPORTLIMIT, EXPORTLIMIT)`, so a flow row recovers the bound with a
  `-1` multiplier.
- `to_from_limit`: the upper bound of the published signed flow range, MW: `max(IMPORTLIMIT, EXPORTLIMIT)`.
- `internal`: `InfrastructureSystems` bookkeeping.
"""
struct NEMInterconnectorLimits <: PSY.SupplementalAttribute
    from_to_limit::Union{IS.StaticTimeSeriesKey, Float64}
    to_from_limit::Union{IS.StaticTimeSeriesKey, Float64}
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
    NEMMNSPLink(; direction, link_id, from_region_tlf, to_region_tlf, lhs_factor, max_capacity)

The registration of one directional link of an MNSP, from `MNSP_INTERCONNECTOR`, held on the MNSP's
`AreaInterchange`. Every field is static.

# Fields
- `direction`: the [`MNSPDirection`](@ref) of the link.
- `link_id`: the `LINKID`.
- `from_region_tlf`: the loss factor at the from-region end, as published.
- `to_region_tlf`: the loss factor at the to-region end, as published.
- `lhs_factor`: the `LHSFACTOR` of the link.
- `max_capacity`: the `MAXCAPACITY` of the link, MW.
- `internal`: `InfrastructureSystems` bookkeeping.
"""
struct NEMMNSPLink <: PSY.SupplementalAttribute
    direction::MNSPDirection
    link_id::String
    from_region_tlf::Float64
    to_region_tlf::Float64
    lhs_factor::Float64
    max_capacity::Float64
    internal::IS.InfrastructureSystemsInternal
end

function NEMMNSPLink(;
        direction::MNSPDirection, link_id::AbstractString, from_region_tlf, to_region_tlf, lhs_factor, max_capacity,
        internal::IS.InfrastructureSystemsInternal = IS.InfrastructureSystemsInternal(),
    )
    return NEMMNSPLink(
        direction, String(link_id), Float64(from_region_tlf), Float64(to_region_tlf), Float64(lhs_factor),
        Float64(max_capacity), internal,
    )
end

IS.get_internal(link::NEMMNSPLink) = link.internal


"""
    NEMMNSPBid(; direction, offer_curves, max_avail, ramp_up, fixed_load = nothing, band_prices = nothing)

One direction of an MNSP's offer as AEMO bid it, held on the MNSP's `AreaInterchange`. Each field is a static
value or a key of the time series that holds it on that interchange.

# Fields
- `direction`: the [`MNSPDirection`](@ref).
- `offer_curves`: the cumulative price bands, MW and \$/MWh, as `PiecewiseStepData`.
- `max_avail`: the link's `MAXAVAIL`, MW.
- `ramp_up`: the link's `RAMPUPRATE`, MW/min, the limit on the flow's increase in this direction. The limit on
  the net flow's decrease is the opposite direction's `ramp_up`.
- `fixed_load`: the link's `FIXEDLOAD`, MW, with NaN at the intervals where AEMO publishes NULL, or `nothing`
  when it is NULL over the whole range.
- `band_prices`: the ten band prices of the trading day in \$/MWh, padded with `0.0`, or `nothing` until the
  replay inputs are written.
- `internal`: `InfrastructureSystems` bookkeeping.
"""
struct NEMMNSPBid <: PSY.SupplementalAttribute
    direction::MNSPDirection
    offer_curves::Union{IS.StaticTimeSeriesKey, PiecewiseStepData}
    max_avail::Union{IS.StaticTimeSeriesKey, Float64}
    ramp_up::Union{IS.StaticTimeSeriesKey, Float64}
    fixed_load::Union{Nothing, IS.StaticTimeSeriesKey, Float64}
    band_prices::Union{Nothing, NTuple{10, Float64}}
    internal::IS.InfrastructureSystemsInternal
end

function NEMMNSPBid(;
        direction::MNSPDirection, offer_curves, max_avail, ramp_up, fixed_load = nothing, band_prices = nothing,
        internal::IS.InfrastructureSystemsInternal = IS.InfrastructureSystemsInternal(),
    )
    return NEMMNSPBid(
        direction, offer_curves, _bid_number(max_avail), _bid_number(ramp_up), _bid_number(fixed_load),
        _band_prices(band_prices), internal,
    )
end

IS.get_internal(bid::NEMMNSPBid) = bid.internal


"""
    NEMMNSPObservedState(; initial_flow)

The MNSP's published flow from `DISPATCHINTERCONNECTORRES`, held on its `AreaInterchange`.

# Fields
- `initial_flow`: `METEREDMWFLOW`, the flow at the start of the interval, MW.
- `internal`: `InfrastructureSystems` bookkeeping.
"""
struct NEMMNSPObservedState <: PSY.SupplementalAttribute
    initial_flow::Union{IS.StaticTimeSeriesKey, Float64}
    internal::IS.InfrastructureSystemsInternal
end

function NEMMNSPObservedState(;
        initial_flow, internal::IS.InfrastructureSystemsInternal = IS.InfrastructureSystemsInternal(),
    )
    return NEMMNSPObservedState(_bid_number(initial_flow), internal)
end

IS.get_internal(state::NEMMNSPObservedState) = state.internal
