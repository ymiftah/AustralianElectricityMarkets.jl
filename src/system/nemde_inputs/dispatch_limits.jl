"""
    _set_dispatch_limits!(sys::PSY.System) -> Nothing

Adds the ramp rates and AGC ramp rates of each NEMDE unit of `sys` that carries telemetry: the
`NEM_SERIES.ramp_up_rate` and `NEM_SERIES.ramp_down_rate` series in system-base per-unit per minute, and
one `fcas_series_name("fcas_agc_ramp_rate", service)` series per regulation service the unit's availability
supports. The ramps are the lesser of the bid and telemetered rates, a unit bid on both sides of the energy
market takes its composite cross-zero rate, and a non-scheduled load is zero. A unit without telemetry
gets no series.

# Arguments
- `sys`: the system whose telemetry [`set_unit_conditions!`](@ref) attached.

# Returns
`nothing`.
"""
function _set_dispatch_limits!(sys::PSY.System)
    base = PSY.get_base_power(sys)
    _foreach_nem_dispatch_device(sys) do device
        telemetry = _nem_unit_data(device).telemetry
        # A unit without telemetry gets no limit series; the NEMDE input check names it.
        isnothing(telemetry) && return
        up = _bid_series(device, telemetry.ramp_up_limit, :ramp_up_limit)
        down = _bid_series(device, telemetry.ramp_down_limit, :ramp_down_limit)
        interval_hours = Dates.value(Millisecond(up.resolution)) / (1000 * 60 * 60)
        ramp_up_rate, ramp_down_rate = _ramp_rate_values(device, up, down, base)
        PSY.add_time_series!(sys, device, single_series(NEM_SERIES.ramp_up_rate, first(up.timestamps), ramp_up_rate, up.resolution))
        PSY.add_time_series!(sys, device, single_series(NEM_SERIES.ramp_down_rate, first(down.timestamps), ramp_down_rate, down.resolution))
        _set_agc_ramp_rates!(sys, device, telemetry, up, down, base, interval_hours)
        return
    end
    return
end


# The bid ramp rate of `device` on `side` in MW/min over the grid of `like`; `NaN` where the device
# has no bid on that side or the bid publishes no rate.
function _bid_ramp_rates(device, side::OfferSide, field::Symbol, like)
    cost = _nem_offer_cost(device)
    isnothing(cost) && return fill(NaN, length(like.values))
    bid = _energy_bid(cost, side)
    isnothing(bid) && return fill(NaN, length(like.values))
    value = getproperty(bid, field)
    isnothing(value) && return fill(NaN, length(like.values))
    return _aligned_values(device, value, like)
end


# The ramp rates of `device` over the grid of `up` in system-base per-unit per minute, as the NEMDE inputs
# write them: zero for a non-scheduled load and where no rate applies. `initial` overrides the observed
# starting output in MW (one value per stamp), which only a storage device's composite rate reads.
function _ramp_rate_values(device, up, down, base::Real; initial = nothing)
    is_non_scheduled_load(device) && return zeros(length(up.values)), zeros(length(down.values))
    interval_hours = Dates.value(Millisecond(up.resolution)) / (1000 * 60 * 60)
    effective_up, effective_down = _effective_ramp_rates(device, up, down, interval_hours; initial)
    return replace(effective_up ./ 60 ./ base, NaN => 0.0), replace(effective_down ./ 60 ./ base, NaN => 0.0)
end


# The per-interval ramp limits of `device` in MW/h over the grid of `up`: a device bid on both sides
# of the energy market takes the composite cross-zero rate of both its bids, and every other device
# the per-side rate, each capped by the telemetered limit. A stamp the inputs do not cover is NaN,
# which leaves the telemetered rate. `initial` overrides the observed starting output in MW.
function _effective_ramp_rates(device, up, down, interval_hours::Real; initial = nothing)
    if !(device isa PSY.Storage)
        side = first(energy_offer_sides(device))
        bid_up = _bid_ramp_rates(device, side, :roc_up, up)
        bid_down = _bid_ramp_rates(device, side, :roc_down, down)
        return (
            [effective_ramp_limit(bid_up[i], up.values[i]) for i in eachindex(up.values)],
            [effective_ramp_limit(bid_down[i], down.values[i]) for i in eachindex(down.values)],
        )
    end
    inputs = _storage_ramp_inputs(device, up, interval_hours)
    initial = something(initial, _aligned_values(device, get_observed_state(device).initial_mw, up))
    rates = [_storage_ramp_at(inputs, i, initial[i]) for i in eachindex(up.values)]
    return first.(rates), last.(rates)
end


# The state-independent inputs of a storage device's composite ramp over the grid of `up`: its bid rates on both
# sides in MW/min and its telemetered limits in MW/h.
function _storage_ramp_inputs(device, up, interval_hours::Real)
    return (;
        minutes = interval_hours * 60,
        gen_up = _bid_ramp_rates(device, OfferSide.GEN, :roc_up, up),
        gen_down = _bid_ramp_rates(device, OfferSide.GEN, :roc_down, up),
        load_up = _bid_ramp_rates(device, OfferSide.LOAD, :roc_up, up),
        load_down = _bid_ramp_rates(device, OfferSide.LOAD, :roc_down, up),
        up = up.values,
        down = _aligned_values(device, _nem_unit_data(device).telemetry.ramp_down_limit, up),
    )
end


# A storage device's ramp limits in MW/h at interval `i` for the starting output `initial_mw`, in MW.
function _storage_ramp_at(inputs, i::Int, initial_mw::Real)
    # AEMO Dispatch Procedure (SO_OP_3705) Appendix C: the composite rate of a unit bid on both
    # sides, compared with its SCADA ramp rate.
    up, down = composite_ramp_rates(
        inputs.gen_up[i], inputs.gen_down[i], inputs.load_up[i], inputs.load_down[i], inputs.minutes, NEMUnitState(Float64(initial_mw), 0),
    )
    return effective_ramp_limit(up, inputs.up[i]), effective_ramp_limit(down, inputs.down[i])
end


# The regulation FCAS bid `MAXAVAIL` of `device` over the grid of `like` in MW: the sum of its bids for
# `service`, the max availability of a bidirectional unit's combined trapezium, or `NaN` when it has no
# bid for the service or a bid misses an interval, which leaves the telemetered availability.
function _regulation_bid_max_avail(device, service::BidType, like)
    cost = _nem_offer_cost(device)
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


# Adds `fcas_agc_ramp_rate_<service>` for both regulation services, from the effective regulation
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
        values = [agc_ramp_rate(ramp[i], availability[i], interval_hours) for i in eachindex(ramp)]
        all(isnan, values) && continue
        PSY.add_time_series!(
            sys, device,
            single_series(fcas_series_name("fcas_agc_ramp_rate", service), first(up.timestamps), values, up.resolution),
        )
    end
    return
end
