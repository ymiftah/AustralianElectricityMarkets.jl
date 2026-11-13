"""
    NEMFCASInputs(; service, side, offer, trapezium, max_avail, agc_ramp)

The keys of one FCAS service's inputs on a device, for one side of its market. Throws an `ArgumentError`
when `service` is not an FCAS `BidType`.

# Fields
- `service`: the FCAS `BidType`.
- `side`: the `OfferSide` of the offer.
- `offer`: the FCAS offer curve series of the bid, a price-band series in MW against \$/MWh, or `nothing`.
- `trapezium`: the FCAS trapezium series of the bid, the four MW breakpoints, or `nothing`.
- `max_avail`: the FCAS `MAXAVAIL` series of the bid, MW, or `nothing`.
- `agc_ramp`: the AGC ramp rate series, in the units the unit conditions publish, or `nothing`.
"""
struct NEMFCASInputs <: PSY.DeviceParameter
    service::AustralianElectricityMarkets.BidType
    side::AustralianElectricityMarkets.OfferSide
    offer::Union{Nothing, IS.StaticTimeSeriesKey}
    trapezium::Union{Nothing, IS.StaticTimeSeriesKey}
    max_avail::Union{Nothing, IS.StaticTimeSeriesKey}
    agc_ramp::Union{Nothing, IS.StaticTimeSeriesKey}
end

function NEMFCASInputs(;
        service, side, offer = nothing, trapezium = nothing, max_avail = nothing, agc_ramp = nothing,
    )
    service in AustralianElectricityMarkets.FCAS_BID_TYPES ||
        throw(ArgumentError("NEMFCASInputs needs an FCAS bid type, got $(service)"))
    return NEMFCASInputs(service, side, offer, trapezium, max_avail, agc_ramp)
end

IS.deserialize(::Type{Vector{NEMFCASInputs}}, data::Vector) =
    NEMFCASInputs[AustralianElectricityMarkets._deserialize_device_parameter(d) for d in data]


"""
    NEMDispatchInputs(; energy_offer = nothing, energy_offer_decremental = nothing,
        energy_availability = nothing, energy_availability_decremental = nothing, uigf = nothing,
        ramp_up = nothing, ramp_down = nothing, fcas = NEMFCASInputs[])

The keys of a device's derived dispatch inputs, held on the device as a supplemental attribute. Each field
is a key of a series attached to the device, or `nothing` where the input is absent.

# Fields
- `energy_offer`: the derived incremental energy offer series, a price-band series in MW against \$/MWh.
- `energy_offer_decremental`: the derived decremental energy offer series, a price-band series in MW against \$/MWh.
- `energy_availability`: the key of the energy bid's `MAXAVAIL` series, MW. A non-scheduled load without an
  energy bid has the zero `MAXAVAIL` series that [`set_market_bids!`](@ref) writes.
- `energy_availability_decremental`: the key of the decremental energy bid's `MAXAVAIL` series, MW, with the
  same zero-series rule for a load.
- `uigf`: the unit initial generation forecast, MW.
- `ramp_up`: the effective ramp-up limit series, MW/h.
- `ramp_down`: the effective ramp-down limit series, MW/h.
- `fcas`: one [`NEMFCASInputs`](@ref) per FCAS service and side with an offer.
- `internal`: `InfrastructureSystems` bookkeeping.
"""
struct NEMDispatchInputs <: PSY.SupplementalAttribute
    energy_offer::Union{Nothing, IS.StaticTimeSeriesKey}
    energy_offer_decremental::Union{Nothing, IS.StaticTimeSeriesKey}
    energy_availability::Union{Nothing, IS.StaticTimeSeriesKey}
    energy_availability_decremental::Union{Nothing, IS.StaticTimeSeriesKey}
    uigf::Union{Nothing, IS.StaticTimeSeriesKey}
    ramp_up::Union{Nothing, IS.StaticTimeSeriesKey}
    ramp_down::Union{Nothing, IS.StaticTimeSeriesKey}
    fcas::Vector{NEMFCASInputs}
    internal::IS.InfrastructureSystemsInternal
end

function NEMDispatchInputs(;
        energy_offer = nothing, energy_offer_decremental = nothing,
        energy_availability = nothing, energy_availability_decremental = nothing, uigf = nothing,
        ramp_up = nothing, ramp_down = nothing, fcas = NEMFCASInputs[],
        internal::IS.InfrastructureSystemsInternal = IS.InfrastructureSystemsInternal(),
    )
    return NEMDispatchInputs(
        energy_offer, energy_offer_decremental, energy_availability, energy_availability_decremental,
        uigf, ramp_up, ramp_down, collect(NEMFCASInputs, fcas), internal,
    )
end

IS.get_internal(inputs::NEMDispatchInputs) = inputs.internal

# The telemetry of a replay unit, or `nothing` when it is unset or the device carries no unit data.
function _unit_telemetry(device)
    unit = AustralianElectricityMarkets._nem_unit_data(device)
    return isnothing(unit) ? nothing : unit.telemetry
end

# The observed state of a replay unit, or `nothing` when it is unset or the device carries no unit data.
function _unit_observed(device)
    unit = AustralianElectricityMarkets._nem_unit_data(device)
    return isnothing(unit) ? nothing : unit.observed_state
end
