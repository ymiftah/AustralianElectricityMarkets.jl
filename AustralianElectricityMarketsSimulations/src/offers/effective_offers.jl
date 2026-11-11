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
- The energy availability is the bid's `MAXAVAIL` series, read through the keys of [`NEMDispatchInputs`](@ref);
  a non-scheduled load without an energy bid reads the zero `MAXAVAIL` series [`set_market_bids!`](@ref) writes for it.
- `"fcas_effective_<BIDTYPE>[_decremental]"` and `"fcas_ramping_limits_<BIDTYPE>"`, the FCAS offer
  per interval after AEMO *FCAS Model in NEMDE* §4 scaling and §5 enablement, on the timestamps of
  the bid's trapezium series, per-unit of the system base. The FCAS trapeziums and offer curves are
  read from the device's [`NEMFCASBid`](@ref) keys, which [`NEMDispatchInputs`](@ref) also holds; a
  `BIDIRECTIONAL` FCAS bid is on the generation side.
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
    keys = _derived_series_keys(device)
    availability = _dispatch_availability_keys(device, keys)
    telemetry = _unit_telemetry(device)
    uigf = isnothing(telemetry) ? nothing : telemetry.uigf
    return NEMDispatchInputs(;
        energy_offer = get(keys, energy_offer_series_name(OfferSide.GEN), nothing),
        energy_offer_decremental = get(keys, energy_offer_series_name(OfferSide.LOAD), nothing),
        energy_availability = availability[1],
        energy_availability_decremental = availability[2],
        uigf = uigf isa IS.StaticTimeSeriesKey ? uigf : nothing,
        ramp_up = get(keys, NEM_SERIES.ramp_up_rate, nothing),
        ramp_down = get(keys, NEM_SERIES.ramp_down_rate, nothing),
        fcas = _fcas_inputs(device, keys),
    )
end


# The availability keys of `device`: a battery's generation and load sides, and a generator's or load's
# single energy side in the generation field.
function _dispatch_availability_keys(device::PSY.Storage, keys::Dict{String, IS.StaticTimeSeriesKey})
    return (
        _energy_availability_key(device, keys, OfferSide.GEN),
        _energy_availability_key(device, keys, OfferSide.LOAD),
    )
end

function _dispatch_availability_keys(device, keys::Dict{String, IS.StaticTimeSeriesKey})
    return (_energy_availability_key(device, keys, only(energy_offer_sides(device))), nothing)
end


# The key of `device`'s energy availability on `side`: the bid's `MAXAVAIL`, or for a device without an energy
# bid on that side the zero `MAXAVAIL` series of a non-scheduled load. `nothing` when neither exists.
function _energy_availability_key(device, keys::Dict{String, IS.StaticTimeSeriesKey}, side::OfferSide)
    key = _bid_availability_key(device, side)
    return isnothing(key) ? get(keys, _max_avail_series_name(side), nothing) : key
end

# The key of the `MAXAVAIL` series of `device`'s energy bid on `side`, or `nothing` without that bid.
function _bid_availability_key(device, side::OfferSide)
    cost = AustralianElectricityMarkets._nem_offer_cost(device)
    bid = isnothing(cost) ? nothing : _energy_bid(cost, side)
    return isnothing(bid) ? nothing : _bid_series_key(device, bid.max_avail, :max_avail)
end


# One `NEMFCASInputs` per side of each service `device` has an FCAS bid and a service for, keyed by the
# bid's series. A regulation service has one AGC ramp rate, so it rides on the GEN-side entry when the
# device bids that side, and on the LOAD-side entry otherwise.
function _fcas_inputs(device, keys::Dict{String, IS.StaticTimeSeriesKey})
    inputs = NEMFCASInputs[]
    for service in AustralianElectricityMarkets.FCAS_BID_TYPES
        isempty(AustralianElectricityMarkets._fcas_services(device, service)) && continue
        bids = NEMFCASInputs[
            bid for bid in (_fcas_bid_inputs(device, service, side) for side in (OfferSide.GEN, OfferSide.LOAD))
                if !isnothing(bid)
        ]
        isempty(bids) && continue
        agc_ramp = service in FCAS_REGULATION_MARKETS ?
            get(keys, fcas_series_name("fcas_agc_ramp_rate", service), nothing) : nothing
        for (i, bid) in enumerate(bids)
            push!(
                inputs,
                NEMFCASInputs(;
                    service = bid.service, side = bid.side, offer = bid.offer, trapezium = bid.trapezium,
                    max_avail = bid.max_avail, agc_ramp = i == 1 ? agc_ramp : nothing,
                ),
            )
        end
    end
    return inputs
end


"""
    _fcas_bid_inputs(device, service::BidType, side::OfferSide) -> Union{Nothing, NEMFCASInputs}

The keys of the series of `device`'s FCAS bid for `service` on `side`: its offer curves, trapezium and
`MAXAVAIL`, with no AGC ramp rate. `nothing` when `device` has no such bid, and `nothing` for the
`offer` field when `device` has no `FCASService` for `service`. Throws `ArgumentError` when a bid field
is static rather than series-backed.

# Arguments
- `device`: the bidding device.
- `service`: the FCAS `BidType`.
- `side`: the `OfferSide` of the bid.

# Returns
A `NEMFCASInputs`, or `nothing`.
"""
function _fcas_bid_inputs(device, service::BidType, side::OfferSide)
    cost = AustralianElectricityMarkets._nem_offer_cost(device)
    isnothing(cost) && return nothing
    bids = get_fcas_bids(cost)
    i = findfirst(b -> b.service == service && AustralianElectricityMarkets._fcas_bid_side(device, b) == side, bids)
    isnothing(i) && return nothing
    bid = bids[i]
    return NEMFCASInputs(;
        service, side,
        offer = AustralianElectricityMarkets._fcas_offer_key(device, service, side),
        trapezium = _bid_series_key(device, bid.trapezium, :trapezium),
        max_avail = _bid_series_key(device, bid.max_avail, :max_avail),
    )
end


# The key of a series-backed FCAS bid field; a static field has no series to read the trapezium from.
function _bid_series_key(device, value::IS.StaticTimeSeriesKey, ::Symbol)
    return value
end

function _bid_series_key(device, value, field::Symbol)
    throw(
        ArgumentError(
            "\"$(PSY.get_name(device))\" has a static `$(field)` field; FCAS trapeziums and MAXAVAIL need " *
                "series-backed bid inputs, as set_market_bids! writes them.",
        ),
    )
end


# The static `SingleTimeSeries` keys of `device` by name, read once from the `System` AEMSim was given.
# The first key of a name wins.
function _derived_series_keys(device)
    keys = Dict{String, IS.StaticTimeSeriesKey}()
    for key in IS.get_time_series_keys(device)
        key isa IS.StaticTimeSeriesKey && get!(keys, IS.get_name(key), key)
    end
    return keys
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

# Attaches each device's energy offer curves; a bid's MAXAVAIL is read from the bid's own series.
function _set_energy_offers!(sys::PSY.System)
    for device in _bidding_devices(sys)
        cost = AustralianElectricityMarkets._nem_offer_cost(device)
        isnothing(cost) && continue
        for side in energy_offer_sides(device)
            bid = _energy_bid(cost, side)
            isnothing(bid) && continue
            curves = _bid_series(device, bid.offer_curves, :offer_curves)
            replace_single_series!(
                sys, device,
                single_series(
                    energy_offer_series_name(side), first(curves.timestamps),
                    referred_offer_curves(curves.values, _loss_factor(device, side)), curves.resolution,
                ),
            )
        end
    end
    return
end

# Throws when two FCAS bids of one service map to the same side of a unit: only the first is read.
function _check_fcas_bid_sides(sys::PSY.System)
    for device in _bidding_devices(sys)
        cost = AustralianElectricityMarkets._nem_offer_cost(device)
        isnothing(cost) && continue
        seen = Set{Tuple{BidType, OfferSide}}()
        for bid in get_fcas_bids(cost)
            side = AustralianElectricityMarkets._fcas_bid_side(device, bid)
            isnothing(side) && continue
            (bid.service, side) in seen && throw(
                ArgumentError("\"$(PSY.get_name(device))\" has two $(bid.service) bids on the $(side) side; only the first is read."),
            )
            push!(seen, (bid.service, side))
        end
    end
    return
end

# The static offer series: the energy curves and `MAXAVAIL`s, from the bids alone. The FCAS offers are
# read from the bids' series, so they need no derived series.
function _set_static_offers!(sys::PSY.System)
    _check_fcas_bid_sides(sys)
    _set_energy_offers!(sys)
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
