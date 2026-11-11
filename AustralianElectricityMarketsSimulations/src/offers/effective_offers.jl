"""
    set_effective_offers!(sys)

Attaches the series the NEM dispatch formulation reads as effective offers, per device of `sys`, from
the bids and unit conditions that [`nem_system`](@ref) attaches, with no database access:

- `"energy_offer[_decremental]"`, the energy offer curves, with prices referred to the reference node
  by the unit's loss factor and rounded to cents, by [`referred_offer_curves`](@ref).
- `"ramp_up_rate"`, `"ramp_down_rate"`, the dispatch ramp rates per unit of the system base per minute,
  and `"fcas_agc_ramp_rate_<BIDTYPE>"`, the AGC ramp rate of each regulation service, from the unit
  conditions that [`set_unit_conditions!`](@ref) attaches. The ramp rates are the lesser of the bid
  and telemetered rates ([`effective_ramp_limit`](@ref)), taking the composite cross-zero rate
  ([`composite_ramp_rates`](@ref)) for a device bid on both sides, and the AGC rates read the
  effective regulation availability ([`effective_regulation_max_avail`](@ref)).
- `"energy_availability[_decremental]"`, the energy bid `MAXAVAIL` per unit of the system base; zero
  for a non-scheduled load without an energy bid. This is the series the formulation reads as
  `EnergyMaxAvailTimeSeriesParameter`.
- `"fcas_offer_<BIDTYPE>[_decremental]"` and `"fcas_trapezium_<BIDTYPE>[_decremental]"`, the FCAS
  offer curves in MW and the trapezium per unit of the system base, with NaN ramp rates. A
  `BIDIRECTIONAL` FCAS bid is on the generation side.
- `"fcas_effective_<BIDTYPE>[_decremental]"` and `"fcas_ramping_limits_<BIDTYPE>"`, the FCAS offer
  per interval after AEMO *FCAS Model in NEMDE* §4 scaling and §5 enablement, on the timestamps of
  the device's `"fcas_trapezium_<BIDTYPE>[_decremental]"` series, per-unit of the system base.
- `"tie_break_scale_<k>[_decremental]"`, the tie-break scale of each price-tied energy band
  ([`tie_break_scale`](@ref)), and the [`EnergyTieBreak`](@ref) service joining the units that carry them.
- `"loss_demand_coefficient"`, the demand term of each loss-modelled interchange's loss factor
  ([`set_loss_demand_coefficients!`](@ref)).
- `"initial_mw_seed"`, `"fixed_load_seed"` and `"fixed_load_invoked_seed"`, the first-solve values
  the build reads from the configured [`StateSource`](@ref) ([`_set_state_seeds!`](@ref)). Under
  `ObservedState` each later solve reads these series at its own stamp.

It also attaches to each NEM dispatch device a [`NEMDispatchInputs`](@ref) holding the keys of the
dispatch-input series the formulation reads through.

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
    _set_mnsp_fixed_loads!(sys)
    _set_dispatch_limits!(sys)
    _set_state_seeds!(sys)
    _set_fcas_effective_offers!(sys)
    _set_tie_break_scales!(sys)
    set_loss_demand_coefficients!(sys)
    _attach_dispatch_inputs!(sys)
    return
end


"""
    _set_state_seeds!(sys)

Attaches each NEM dispatch device's first-solve seed series from the configured
[`StateSource`](@ref): `"initial_mw_seed"` in MW, and, for a device whose energy bid carries a fixed
loading, `"fixed_load_seed"` in system-base per-unit and `"fixed_load_invoked_seed"` (`1` or `0`).
The build writes them before the forecasts are attached, so the simulation's first solve, which
`PowerSimulations.jl` does not update, starts from the values at the build's stamp. Replaces existing seed series.

# Arguments
- `sys`: the `System` to add to.

# Returns
`nothing`.
"""
function _set_state_seeds!(sys::PSY.System)
    source = _state_source()
    base = PSY.get_base_power(sys)
    PSY.with_units_base(sys, "SYSTEM_BASE") do
        AustralianElectricityMarkets._foreach_nem_dispatch_device(sys) do device
            observed = AustralianElectricityMarkets.get_observed_state(device)
            observed.initial_mw isa IS.StaticTimeSeriesKey || return
            name = PSY.get_name(observed.initial_mw)
            stamps = PSY.get_time_series_timestamps(PSY.SingleTimeSeries, device, name)
            resolution = IS.get_resolution(PSY.get_time_series(PSY.SingleTimeSeries, device, name))
            # The seed reads the starting output only, so a stamp with no dispatch mode (before
            # registration or a missing DISPATCHLOAD row) still seeds.
            initial = _state_initial_mw_series(source, device, stamps)
            replace_single_series!(
                sys, device,
                single_series(_INITIAL_MW_SEED_SERIES, first(stamps), initial, resolution),
            )
            _has_fixed_load_bid(device) || return
            steps = _fixed_load_step_series(device, stamps; source)
            replace_single_series!(
                sys, device,
                single_series(_FIXED_LOAD_SEED_SERIES, first(stamps), [step.target / base for step in steps], resolution),
            )
            replace_single_series!(
                sys, device,
                single_series(
                    _FIXED_LOAD_INVOKED_SEED_SERIES, first(stamps),
                    [step.invoked ? 1.0 : 0.0 for step in steps], resolution,
                ),
            )
            return
        end
    end
    return
end


"""
    _attach_dispatch_inputs!(sys)

Attaches to each NEM dispatch device a [`NEMDispatchInputs`](@ref) holding the dispatch-input series
keys [`set_effective_offers!`](@ref) derived for it, replacing any attached by an earlier call.

# Arguments
- `sys`: the `System` to add to.

# Returns
`nothing`.
"""
function _attach_dispatch_inputs!(sys::PSY.System)
    AustralianElectricityMarkets._foreach_nem_dispatch_device(sys) do device
        for old in (PSY.get_supplemental_attributes(NEMDispatchInputs, device)::Vector{NEMDispatchInputs})
            PSY.remove_supplemental_attribute!(sys, device, old)
        end
        PSY.add_supplemental_attribute!(sys, device, _dispatch_inputs(device))
        return
    end
    return
end


# The derived-input keys of `device`: one per dispatch-input series it has, or `nothing` where an
# input is absent.
function _dispatch_inputs(device)
    telemetry = _unit_telemetry(device)
    uigf = isnothing(telemetry) ? nothing : telemetry.uigf
    return NEMDispatchInputs(;
        energy_offer = _derived_series_key(device, energy_offer_series_name(OfferSide.GEN)),
        energy_offer_decremental = _derived_series_key(device, energy_offer_series_name(OfferSide.LOAD)),
        energy_availability = _derived_series_key(device, energy_availability_series_name(OfferSide.GEN)),
        energy_availability_decremental = _derived_series_key(device, energy_availability_series_name(OfferSide.LOAD)),
        uigf = uigf isa IS.StaticTimeSeriesKey ? uigf : nothing,
        ramp_up = _derived_series_key(device, NEM_SERIES.ramp_up_rate),
        ramp_down = _derived_series_key(device, NEM_SERIES.ramp_down_rate),
        fcas = _fcas_inputs(device),
    )
end


# One `NEMFCASInputs` per side of each service `device` has an offer for: an offer always writes its
# trapezium. A regulation service has one AGC ramp rate, so it rides on the GEN-side entry when the
# device bids that side, and on the LOAD-side entry otherwise.
function _fcas_inputs(device)
    inputs = NEMFCASInputs[]
    for service in AustralianElectricityMarkets.FCAS_BID_TYPES
        offers = Dict(
            side => _derived_series_key(device, fcas_series_name("fcas_offer", service, side))
                for side in (OfferSide.GEN, OfferSide.LOAD)
        )
        sides = [side for side in (OfferSide.GEN, OfferSide.LOAD) if !isnothing(offers[side])]
        isempty(sides) && continue
        agc_ramp = service in FCAS_REGULATION_MARKETS ?
            _derived_series_key(device, fcas_series_name("fcas_agc_ramp_rate", service)) : nothing
        for (i, side) in enumerate(sides)
            trapezium = _derived_series_key(device, fcas_series_name("fcas_trapezium", service, side))
            push!(inputs, NEMFCASInputs(; service, side, offer = offers[side], trapezium, agc_ramp = i == 1 ? agc_ramp : nothing))
        end
    end
    return inputs
end


# The key of `device`'s `name` `SingleTimeSeries`, or `nothing` when it carries none: read from the
# `System` AEMSim was given, where AEM's `_series_key` throws on a missing name.
function _derived_series_key(device, name::AbstractString)
    for key in IS.get_time_series_keys(device)
        key isa IS.StaticTimeSeriesKey && IS.get_name(key) == name && return key
    end
    return nothing
end


# Derives each MNSP link direction's NaN-free fixed-loading value and invoked series from its bid's `fixed_load`
# (NaN where AEMO publishes NULL). A bid without a fixed loading gives zeros on its availability grid.
function _set_mnsp_fixed_loads!(sys::PSY.System)
    for device in PSY.get_components(PSY.AreaInterchange, sys)
        for dir in _MNSP_DIRECTIONS
            bid = _mnsp_bid(device, dir)
            isnothing(bid) && continue
            series = isnothing(bid.fixed_load) ? _bid_series(device, bid.max_avail, :max_avail) :
                _bid_series(device, bid.fixed_load, :fixed_load)
            raw = isnothing(bid.fixed_load) ? fill(NaN, length(series.values)) : Float64.(series.values)
            value = [isnan(v) ? 0.0 : v for v in raw]
            invoked = [isnan(v) ? 0.0 : 1.0 for v in raw]
            for (kind, data) in ((:value, value), (:invoked, invoked))
                name = getproperty(NEM_MNSP_FIXED_LOAD_SERIES, Symbol(dir, "_", kind))
                # A transformed system keeps a deterministic copy, which must go before its single series.
                PSY.has_time_series(device, PSY.DeterministicSingleTimeSeries, name) &&
                    PSY.remove_time_series!(sys, PSY.DeterministicSingleTimeSeries, device, name)
                replace_single_series!(sys, device, single_series(name, first(series.timestamps), data, series.resolution))
            end
        end
    end
    return
end


# The NEM devices of `sys` that can carry offers.
_bidding_devices(sys::PSY.System) = Iterators.flatten(
    (PSY.get_components(T, sys) for T in (PSY.Generator, PSY.ControllableLoad, PSY.Storage)),
)

# The timestamps, resolution and values of a bid field's time series on `device`.
function _bid_series(device, key::IS.TimeSeriesKey, ::Symbol)
    ts::PSY.SingleTimeSeries = IS.get_time_series(device, key)
    array = PSY.get_time_series_array(device, ts)
    return (;
        timestamps = PSY.TimeSeries.timestamp(array), resolution = IS.get_resolution(ts),
        values = collect(values(array)),
    )
end

# A static bid field has no series to derive the offers from.
function _bid_series(device, value, field::Symbol)
    throw(
        ArgumentError(
            "set_effective_offers!: \"$(PSY.get_name(device))\" has a static `$(field)` field; set_effective_offers! " *
                "needs series-backed bid inputs, as set_market_bids! writes them.",
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

# The timestamps and resolution of the bid series of `sys`, which share one grid. Sizes the zero
# offers of a non-scheduled load.
function _bid_axis(sys::PSY.System)
    for device in _bidding_devices(sys)
        cost = AustralianElectricityMarkets._nem_offer_cost(device)
        isnothing(cost) && continue
        for bid in get_energy_bids(cost)
            series = _bid_series(device, bid.max_avail, :max_avail)
            return (; timestamps = series.timestamps, resolution = series.resolution)
        end
    end
    throw(ArgumentError("set_effective_offers!: no energy bid in the system to size the zero MAXAVAIL of its non-scheduled loads."))
end

# Attaches each device's energy offer curves and energy availability, and the zero availability of a
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
                    name = energy_availability_series_name(device, side)
                    PSY.has_time_series(device, PSY.SingleTimeSeries, name) && continue
                    zeros_on_axis = zeros(length(axis.timestamps))
                    replace_single_series!(sys, device, single_series(name, first(axis.timestamps), zeros_on_axis, axis.resolution))
                end
                continue
            end
            curves = _bid_series(device, bid.offer_curves, :offer_curves)
            replace_single_series!(
                sys, device,
                single_series(
                    energy_offer_series_name(side), first(curves.timestamps),
                    referred_offer_curves(curves.values, _loss_factor(device, side)), curves.resolution,
                ),
            )
            max_avail = _bid_series(device, bid.max_avail, :max_avail)
            replace_single_series!(
                sys, device,
                single_series(
                    energy_availability_series_name(device, side), first(max_avail.timestamps),
                    Float64.(max_avail.values) ./ base, max_avail.resolution,
                ),
            )
        end
    end
    return
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
            trapezium = _bid_series(device, bid.trapezium, :trapezium)
            max_avail = _bid_series(device, bid.max_avail, :max_avail).values
            values_by_interval = [
                fcas_trapezium_values(trapezium.values[i], max_avail[i], base) for i in eachindex(trapezium.values)
            ]
            replace_single_series!(
                sys, device,
                single_series(
                    fcas_series_name("fcas_trapezium", service, side), first(trapezium.timestamps), values_by_interval,
                    trapezium.resolution,
                ),
            )
            isempty(AustralianElectricityMarkets._fcas_services(device, service)) && continue
            offer = _bid_series(device, bid.offer_curves, :offer_curves)
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


# The values of a telemetry key over the grid of `like`: a static value is repeated.
function _grid_values(device, key, like)
    key isa IS.StaticTimeSeriesKey || return fill(Float64(key), length(like.values))
    return _bid_series(device, key, :availability).values
end


# The values of `key` on the timestamps of `like`: a static value is repeated, and a stamp the
# series does not cover is `NaN`, so a bid on another window limits nothing.
function _aligned_values(device, key, like)
    key isa IS.StaticTimeSeriesKey || return fill(Float64(key), length(like.values))
    series = _bid_series(device, key, :availability)
    values = fill(NaN, length(like.values))
    index = Dict(t => i for (i, t) in enumerate(like.timestamps))
    for (i, t) in enumerate(series.timestamps)
        j = get(index, t, nothing)
        isnothing(j) || (values[j] = series.values[i])
    end
    return values
end


# The bid ramp rate of `device` on `side` in MW/min over the grid of `like`; `NaN` where the device
# has no bid on that side or the bid publishes no rate.
function _bid_ramp_rates(device, side::OfferSide, field::Symbol, like)
    cost = AustralianElectricityMarkets._nem_offer_cost(device)
    isnothing(cost) && return fill(NaN, length(like.values))
    bid = _energy_bid(cost, side)
    isnothing(bid) && return fill(NaN, length(like.values))
    value = getproperty(bid, field)
    isnothing(value) && return fill(NaN, length(like.values))
    return _aligned_values(device, value, like)
end


# The regulation FCAS bid `MAXAVAIL` of `device` over the grid of `like` in MW: the sum of its bids for
# `service`, the max availability of a bidirectional unit's combined trapezium, or `NaN` when it has no
# bid for the service or a bid misses an interval, which leaves the telemetered availability.
function _regulation_bid_max_avail(device, service::BidType, like)
    cost = AustralianElectricityMarkets._nem_offer_cost(device)
    isnothing(cost) && return fill(NaN, length(like.values))
    values = [_aligned_values(device, bid.max_avail, like) for bid in get_fcas_bids(cost) if bid.service == service]
    isempty(values) && return fill(NaN, length(like.values))
    return reduce((a, b) -> a .+ b, values)
end


# The effective availability of `service` over the grid of `like`, per unit of the system base.
function _regulation_availability(device, service::BidType, key, like, base::Real)
    telemetry = _grid_values(device, key, like)
    bid = _regulation_bid_max_avail(device, service, like)
    return [effective_regulation_max_avail(bid[i], telemetry[i]) for i in eachindex(telemetry)] ./ base
end


# Attaches the ramp rates and AGC ramp rates of each available NEM dispatch device. The ramps are the
# lesser of the bid and telemetered rates per minute, with a non-scheduled load and a missing row at
# zero; a battery bid on both sides takes the composite cross-zero rate; the AGC rates read the
# effective regulation availability.
function _set_dispatch_limits!(sys::PSY.System)
    base = PSY.get_base_power(sys)
    AustralianElectricityMarkets._foreach_nem_dispatch_device(sys) do device
        telemetry = _unit_telemetry(device)
        # A unit without telemetry gets no limit series; the replay input check names it.
        isnothing(telemetry) && return
        up = _bid_series(device, telemetry.ramp_up_limit, :ramp_up_limit)
        down = _bid_series(device, telemetry.ramp_down_limit, :ramp_down_limit)
        interval_hours = Dates.value(Millisecond(up.resolution)) / (1000 * 60 * 60)
        pinned = AustralianElectricityMarkets.is_non_scheduled_load(device)
        effective_up, effective_down = _effective_ramp_rates(device, up, down, interval_hours)
        ramp_up_rate = pinned ? zeros(length(up.values)) : replace(effective_up ./ 60 ./ base, NaN => 0.0)
        ramp_down_rate = pinned ? zeros(length(down.values)) : replace(effective_down ./ 60 ./ base, NaN => 0.0)
        replace_single_series!(sys, device, single_series(NEM_SERIES.ramp_up_rate, first(up.timestamps), ramp_up_rate, up.resolution))
        replace_single_series!(sys, device, single_series(NEM_SERIES.ramp_down_rate, first(down.timestamps), ramp_down_rate, down.resolution))
        _set_agc_ramp_rates!(sys, device, telemetry, up, down, base, interval_hours)
        return
    end
    return
end


# The per-interval ramp limits of `device` in MW/h over the grid of `up`: a device bid on both sides
# of the energy market takes the composite cross-zero rate of both its bids, and every other device
# the per-side rate, each capped by the telemetered limit. A stamp the inputs do not cover is NaN,
# which leaves the telemetered rate.
function _effective_ramp_rates(device, up, down, interval_hours::Real)
    device isa PSY.Storage || return effective_ramp_limits(
        _bid_ramp_rates(device, first(energy_offer_sides(device)), :roc_up, up),
        _bid_ramp_rates(device, first(energy_offer_sides(device)), :roc_down, down),
        up.values, down.values,
    )
    minutes = interval_hours * 60
    gen_up = _bid_ramp_rates(device, OfferSide.GEN, :roc_up, up)
    gen_down = _bid_ramp_rates(device, OfferSide.GEN, :roc_down, up)
    load_up = _bid_ramp_rates(device, OfferSide.LOAD, :roc_up, up)
    load_down = _bid_ramp_rates(device, OfferSide.LOAD, :roc_down, up)
    initial = _aligned_values(device, AustralianElectricityMarkets.get_observed_state(device).initial_mw, up)
    down_telemetry = _aligned_values(device, _unit_telemetry(device).ramp_down_limit, up)
    # AEMO Dispatch Procedure (SO_OP_3705) Appendix C: the composite rate of a unit bid on both
    # sides, compared with its SCADA ramp rate.
    rates = [
        composite_ramp_rates(gen_up[i], gen_down[i], load_up[i], load_down[i], minutes, NEMUnitState(initial[i], 0))
            for i in eachindex(up.values)
    ]
    return (
        [effective_ramp_limit(rates[i][1], up.values[i]) for i in eachindex(rates)],
        [effective_ramp_limit(rates[i][2], down_telemetry[i]) for i in eachindex(rates)],
    )
end


# Attaches `fcas_agc_ramp_rate_<service>` for both regulation services, from the effective regulation
# availability. A `ControllableLoad` reads its raise regulation from the lower availability and the
# ramp-up rate, and its lower regulation from the ramp-down rate and the raise availability.
function _set_agc_ramp_rates!(sys::PSY.System, device, telemetry, up, down, base::Real, interval_hours::Real)
    raise_availability = _regulation_availability(device, BidType.RAISEREG, telemetry.raise_reg_max_avail, up, base)
    lower_availability = _regulation_availability(device, BidType.LOWERREG, telemetry.lower_reg_max_avail, up, base)
    ramp_up, ramp_down = up.values ./ base, down.values ./ base
    if device isa PSY.ControllableLoad
        sides = (ramp_up => lower_availability, ramp_down => raise_availability)
    else
        sides = (ramp_up => raise_availability, ramp_down => lower_availability)
    end
    for (service, (ramp, availability)) in zip((BidType.RAISEREG, BidType.LOWERREG), sides)
        all(isnan, availability) && continue
        values = [_agc_ramp_rate(ramp[i], availability[i], interval_hours) for i in eachindex(ramp)]
        all(isnan, values) && continue
        replace_single_series!(
            sys, device,
            single_series(fcas_series_name("fcas_agc_ramp_rate", service), first(up.timestamps), values, up.resolution),
        )
    end
    return
end
