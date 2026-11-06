"""
    set_effective_offers!(sys)

Attaches the series the NEM dispatch formulation reads as effective offers, per device of `sys`, from
the bids and unit conditions that [`nem_system`](@ref) attaches, with no database access:

- `"energy_offer[_decremental]"`, the energy offer curves, with prices referred to the reference node
  by the unit's loss factor and rounded to cents.
- `"ramp_up_rate"`, `"ramp_down_rate"`, the dispatch ramp rates per unit of the system base per minute,
  `"max_active_power"`, the upper dispatch limit of a non-storage NEM dispatch device, and
  `"fcas_agc_ramp_rate_<BIDTYPE>"`, the AGC ramp rate of each regulation service, from the unit
  conditions that [`set_unit_conditions!`](@ref) attaches.
- `"energy_max_avail[_decremental]"`, the energy `MAXAVAIL` per unit of the system base; zero for a
  non-scheduled load without an energy bid.
- `"fcas_offer_<BIDTYPE>[_decremental]"` and `"fcas_trapezium_<BIDTYPE>[_decremental]"`, the FCAS
  offer curves in MW and the trapezium per unit of the system base, with NaN ramp rates. A
  `BIDIRECTIONAL` FCAS bid is on the generation side.
- `"fcas_effective_<BIDTYPE>[_decremental]"` and `"fcas_ramping_limits_<BIDTYPE>"`, the FCAS offer
  per interval after AEMO *FCAS Model in NEMDE* §4 scaling and §5 enablement, on the timestamps of
  the device's `"fcas_trapezium_<BIDTYPE>[_decremental]"` series, per-unit of the system base.
- `"tie_break_scale_<k>[_decremental]"`, the tie-break scale of each price-tied energy band, and the
  [`EnergyTieBreak`](@ref) service joining the units that carry them.

The static series are written first, then the dispatch ramps and limits, then the FCAS effective offers
and tie-break scales that read them. Existing series of these names are replaced, so a second call on the same `sys` gives the same
result. [`prepare_replay!`](@ref) calls it before attaching the forecasts. Call it before
`transform_single_time_series!`: the series are single time series until then.

Throws `ArgumentError` when a bid is static rather than series-backed, or when two FCAS bids of one
service map to the same side of a unit.

# Arguments
- `sys`: the `System` to add to.

# Returns
`nothing`.
"""
function set_effective_offers!(sys::PSY.System)
    _set_static_offers!(sys)
    _set_dispatch_limits!(sys)
    _set_fcas_effective_offers!(sys)
    _set_tie_break_scales!(sys)
    return
end


# The NEM devices of `sys` that can carry offers.
_bidding_devices(sys::PSY.System) = Iterators.flatten(
    (PSY.get_components(T, sys) for T in (PSY.Generator, PSY.ControllableLoad, PSY.Storage)),
)

# The timestamps, resolution and values of a bid field's time series on `device`.
function _bid_series(device, key::IS.TimeSeriesKey)
    ts = IS.get_time_series(device, key)
    array = PSY.get_time_series_array(device, ts)
    return (;
        timestamps = PSY.TimeSeries.timestamp(array), resolution = IS.get_resolution(ts),
        values = collect(values(array)),
    )
end

# A static bid field has no series to derive the offers from.
function _bid_series(device, bid)
    throw(
        ArgumentError(
            "set_effective_offers!: \"$(PSY.get_name(device))\" has a static bid; set_effective_offers! needs " *
                "series-backed bids, as set_market_bids! writes them.",
        ),
    )
end

# The energy bid of `cost` on `side`, or `nothing`.
function _energy_bid(cost, side::OfferSide)
    i = findfirst(b -> AustralianElectricityMarkets._energy_offer_side(b.direction) == side, get_energy_bids(cost))
    return isnothing(i) ? nothing : get_energy_bids(cost)[i]
end

# The loss factor that refers `side`'s prices to the reference node, from the unit's registration.
function _loss_factor(device, side::OfferSide)
    registration = get_registration(device)
    return side == OfferSide.LOAD ? registration.load_loss_factor : registration.gen_loss_factor
end

# The offer curves of `curves` referred to the reference node by `factor`, prices rounded to cents.
function _referred_curves(curves, factor::Real)
    return [
        PSY.PiecewiseStepData(PSY.get_x_coords(c), round.(PSY.get_y_coords(c) ./ factor; digits = 2)) for c in curves
    ]
end

# The timestamps and resolution of the bid series of `sys`, which share one grid. Sizes the zero
# offers of a non-scheduled load.
function _bid_axis(sys::PSY.System)
    for device in _bidding_devices(sys)
        cost = AustralianElectricityMarkets._nem_offer_cost(device)
        isnothing(cost) && continue
        for bid in get_energy_bids(cost)
            series = _bid_series(device, bid.max_avail)
            return (; timestamps = series.timestamps, resolution = series.resolution)
        end
    end
    throw(ArgumentError("set_effective_offers!: no energy bid in the system to size the zero MAXAVAIL of its non-scheduled loads."))
end

# Attaches each device's energy offer curves and energy `MAXAVAIL`, and the zero `MAXAVAIL` of a
# non-scheduled load with no energy bid.
function _set_energy_offers!(sys::PSY.System)
    base = PSY.get_base_power(sys)
    axis = nothing
    for device in _bidding_devices(sys)
        cost = AustralianElectricityMarkets._nem_offer_cost(device)
        isnothing(cost) && continue
        for side in energy_offer_sides(device)
            bid = _energy_bid(cost, side)
            if isnothing(bid)
                if device isa PSY.ControllableLoad && AustralianElectricityMarkets.is_non_scheduled_load(device) &&
                        PSY.get_available(device)
                    axis = isnothing(axis) ? _bid_axis(sys) : axis
                    name = energy_max_avail_series_name(device, side)
                    PSY.has_time_series(device, PSY.SingleTimeSeries, name) && continue
                    zeros_on_axis = zeros(length(axis.timestamps))
                    replace_single_series!(sys, device, single_series(name, first(axis.timestamps), zeros_on_axis, axis.resolution))
                end
                continue
            end
            curves = _bid_series(device, bid.offer_curves)
            replace_single_series!(
                sys, device,
                single_series(
                    energy_offer_series_name(side), first(curves.timestamps),
                    _referred_curves(curves.values, _loss_factor(device, side)), curves.resolution,
                ),
            )
            max_avail = _bid_series(device, bid.max_avail)
            replace_single_series!(
                sys, device,
                single_series(
                    energy_max_avail_series_name(device, side), first(max_avail.timestamps),
                    Float64.(max_avail.values) ./ base, max_avail.resolution,
                ),
            )
        end
    end
    return
end

# The FCAS trapezium of one interval, per unit of the system base: the bid's four MW breakpoints
# and `MAXAVAIL`, then the ramp rates, which AEMO's FCAS offers do not publish (NaN).
function _fcas_trapezium_values(points, max_avail::Real, base::Real)
    return (Float64.(points)..., Float64(max_avail), NaN, NaN) ./ base
end

# Attaches the FCAS trapezium and offer curves of each FCAS bid the formulation models.
function _set_fcas_offers!(sys::PSY.System)
    base = PSY.get_base_power(sys)
    for device in _bidding_devices(sys)
        cost = AustralianElectricityMarkets._nem_offer_cost(device)
        isnothing(cost) && continue
        seen = Set{Tuple{BidType, OfferSide}}()
        for bid in get_fcas_bids(cost)
            side = AustralianElectricityMarkets._fcas_bid_side(device, bid)
            isnothing(side) && continue
            service = bid.service
            (service, side) in seen && throw(
                ArgumentError("\"$(PSY.get_name(device))\" has two $(service) bids on the $(side) side; one is overwritten."),
            )
            push!(seen, (service, side))
            decremental = side == OfferSide.LOAD
            trapezium = _bid_series(device, bid.trapezium)
            max_avail = _bid_series(device, bid.max_avail).values
            values_by_interval = [
                _fcas_trapezium_values(trapezium.values[i], max_avail[i], base) for i in eachindex(trapezium.values)
            ]
            replace_single_series!(
                sys, device,
                single_series(
                    fcas_series_name("fcas_trapezium", service, side), first(trapezium.timestamps), values_by_interval,
                    trapezium.resolution,
                ),
            )
            isempty(AustralianElectricityMarkets._fcas_services(device, service)) && continue
            offer = _bid_series(device, bid.offer_curves)
            replace_single_series!(
                sys, device,
                single_series(fcas_series_name("fcas_offer", service, side), first(offer.timestamps), offer.values, offer.resolution),
            )
        end
    end
    return
end

# The static offer series: energy and FCAS curves, `MAXAVAIL`s and trapezia, from the bids alone.
function _set_static_offers!(sys::PSY.System)
    _set_energy_offers!(sys)
    _set_fcas_offers!(sys)
    return
end


# The series of one dispatch condition of `device` as a named tuple with the timestamps, the stored
# resolution and the values.
function _condition_series(device, name::AbstractString)
    array = PSY.get_time_series_array(PSY.SingleTimeSeries, device, name)
    return (;
        timestamps = PSY.TimeSeries.timestamp(array),
        resolution = IS.get_resolution(PSY.get_time_series(PSY.SingleTimeSeries, device, name)),
        values = collect(values(array)),
    )
end


# Attaches the ramp rates, AGC ramp rates and upper dispatch limit of each NEM dispatch device with unit
# conditions. The ramps copy the dispatch rates, with a non-scheduled load and a missing row at zero; the
# AGC rates read the dispatch rates as published. A device without them gets no limit series, and the
# replay input check names it.
function _set_dispatch_limits!(sys::PSY.System)
    base = PSY.get_base_power(sys)
    for device in nem_dispatch_devices(sys)
        PSY.has_time_series(device, PSY.SingleTimeSeries, NEM_SERIES.dispatch_ramp_up_rate) || continue
        up = _condition_series(device, NEM_SERIES.dispatch_ramp_up_rate)
        down = _condition_series(device, NEM_SERIES.dispatch_ramp_down_rate)
        interval_hours = Dates.value(Millisecond(up.resolution)) / (1000 * 60 * 60)
        pinned = is_non_scheduled_load(device)
        ramp_up_rate = pinned ? zeros(length(up.values)) : replace(up.values, NaN => 0.0)
        ramp_down_rate = pinned ? zeros(length(down.values)) : replace(down.values, NaN => 0.0)
        replace_single_series!(sys, device, single_series(NEM_SERIES.ramp_up_rate, first(up.timestamps), ramp_up_rate, up.resolution))
        replace_single_series!(sys, device, single_series(NEM_SERIES.ramp_down_rate, first(down.timestamps), ramp_down_rate, down.resolution))
        _set_agc_ramp_rates!(sys, device, up, down, interval_hours)
        device isa PSY.Storage && continue
        initial = _condition_series(device, NEM_SERIES.initial_mw)
        availability = _condition_series(device, NEM_SERIES.availability)
        static = with_units_base(() -> PSY.get_max_active_power(device), sys, "NATURAL_UNITS")
        ramp_down_per_hour = ramp_down_rate .* 60
        limits = [
            _max_active_power(availability.values[i], initial.values[i], ramp_down_per_hour[i], interval_hours) * base / static
                for i in eachindex(availability.values)
        ]
        replace_single_series!(
            sys, device,
            single_series(NEM_SERIES.max_active_power, first(availability.timestamps), limits, availability.resolution; scaling_factor_multiplier = PSY.get_max_active_power),
        )
    end
    return
end


# Attaches `fcas_agc_ramp_rate_<service>` for both regulation services, when `device` has their
# availability. A `ControllableLoad` reads its raise regulation from the lower availability and the
# ramp-up rate, and its lower regulation from the ramp-down rate and the raise availability.
function _set_agc_ramp_rates!(sys::PSY.System, device, up, down, interval_hours::Real)
    names = [fcas_series_name("fcas_regulation_availability", service) for service in (BidType.RAISEREG, BidType.LOWERREG)]
    all(name -> PSY.has_time_series(device, PSY.SingleTimeSeries, name), names) || return
    raise_availability, lower_availability = (_condition_series(device, name).values for name in names)
    ramp_up, ramp_down = up.values .* 60, down.values .* 60
    if device isa PSY.ControllableLoad
        sides = (ramp_up => lower_availability, ramp_down => raise_availability)
    else
        sides = (ramp_up => raise_availability, ramp_down => lower_availability)
    end
    for (service, (ramp, availability)) in zip((BidType.RAISEREG, BidType.LOWERREG), sides)
        values = [_agc_ramp_rate(ramp[i], availability[i], interval_hours) for i in eachindex(ramp)]
        all(isnan, values) && continue
        replace_single_series!(
            sys, device,
            single_series(fcas_series_name("fcas_agc_ramp_rate", service), first(up.timestamps), values, up.resolution),
        )
    end
    return
end
