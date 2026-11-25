"""
    _set_dispatch_limits!(sys::PSY.System, grid = _nemde_grid(sys)) -> Nothing

Adds the ramp rates and AGC ramp rates of each NEMDE unit of `sys` that carries telemetry: the
`NEM_SERIES.ramp_up_rate` and `NEM_SERIES.ramp_down_rate` series in system-base per-unit per minute, and
one `fcas_series_name("fcas_agc_ramp_rate", service)` series per regulation service the unit's availability
supports. The ramps are the lesser of the bid and telemetered rates, a unit bid on both sides of the energy
market takes its composite cross-zero rate, and a non-scheduled load is zero. A unit without telemetry
gets no series.

# Arguments
- `sys`: the system whose telemetry [`set_unit_conditions!`](@ref) attached.
- `grid`: the timestamps the single time series of `sys` share; read from `sys` by default.

# Returns
`nothing`.
"""
function _set_dispatch_limits!(sys::PSY.System, grid = _nemde_grid(sys))
    base = PSY.get_base_power(sys)
    n = length(grid)
    interval_hours = Dates.value(Millisecond(step(grid))) / 3_600_000
    _foreach_nem_dispatch_device(sys) do device
        telemetry = _nem_unit_data(device).telemetry
        # A unit without telemetry gets no limit series; the NEMDE input check names it.
        isnothing(telemetry) && return
        up = _values_on_grid(device, telemetry.ramp_up_limit, grid; field = :ramp_up_limit)
        down = _values_on_grid(device, telemetry.ramp_down_limit, grid; field = :ramp_down_limit)
        # The per-interval ramp limits in MW/h: a device bid on both sides of the energy market takes the composite
        # cross-zero rate of both its bids, every other device its per-side rate, each capped by the telemetered limit.
        if is_non_scheduled_load(device)
            effective_up, effective_down = zeros(n), zeros(n)
        elseif device isa PSY.Storage
            inputs = _storage_ramp_inputs(device, grid, interval_hours)
            initial = _values_on_grid(device, get_observed_state(device).initial_mw, grid)
            rates = [_storage_ramp_at(inputs, i, initial[i]) for i in 1:n]
            effective_up, effective_down = first.(rates), last.(rates)
        else
            side = first(energy_offer_sides(device))
            effective_up = effective_ramp_limit.(_energy_bid_values(device, side, :roc_up, grid), up)
            effective_down = effective_ramp_limit.(_energy_bid_values(device, side, :roc_down, grid), down)
        end
        ramp_up_rate = replace(effective_up ./ 60 ./ base, NaN => 0.0)
        ramp_down_rate = replace(effective_down ./ 60 ./ base, NaN => 0.0)
        PSY.add_time_series!(sys, device, single_series(NEM_SERIES.ramp_up_rate, first(grid), ramp_up_rate, step(grid)))
        PSY.add_time_series!(sys, device, single_series(NEM_SERIES.ramp_down_rate, first(grid), ramp_down_rate, step(grid)))
        _set_agc_ramp_rates!(sys, device, telemetry, up, down, base, interval_hours, grid)
        return
    end
    return
end


# The state-independent inputs of a storage device's composite ramp on `grid`: its bid rates on both sides in
# MW/min and its telemetered limits in MW/h.
function _storage_ramp_inputs(device, grid, interval_hours::Real)
    telemetry = _nem_unit_data(device).telemetry
    return (;
        minutes = interval_hours * 60,
        gen_up = _energy_bid_values(device, OfferSide.GEN, :roc_up, grid),
        gen_down = _energy_bid_values(device, OfferSide.GEN, :roc_down, grid),
        load_up = _energy_bid_values(device, OfferSide.LOAD, :roc_up, grid),
        load_down = _energy_bid_values(device, OfferSide.LOAD, :roc_down, grid),
        up = _values_on_grid(device, telemetry.ramp_up_limit, grid; field = :ramp_up_limit),
        down = _values_on_grid(device, telemetry.ramp_down_limit, grid),
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


# Adds `fcas_agc_ramp_rate_<service>` for both regulation services, from the effective regulation
# availability. A `ControllableLoad` reads its raise regulation from the lower availability and the
# ramp-up rate, and its lower regulation from the ramp-down rate and the raise availability.
function _set_agc_ramp_rates!(sys::PSY.System, device, telemetry, up, down, base::Real, interval_hours::Real, grid)
    n = length(grid)
    cost = _nem_offer_cost(device)
    fcas_bids = isnothing(cost) ? NEMFCASBid[] : get_fcas_bids(cost)
    # The regulation MAXAVAIL of a service is the sum of its bids, NaN without one, and caps the telemetered availability.
    function regulation_availability(service, telemetry_key)
        bids = [_values_on_grid(device, bid.max_avail, grid) for bid in fcas_bids if bid.service == service]
        bid_max_avail = isempty(bids) ? fill(NaN, n) : reduce(.+, bids)
        return effective_regulation_max_avail.(bid_max_avail, _values_on_grid(device, telemetry_key, grid)) ./ base
    end
    raise_availability = regulation_availability(BidType.RAISEREG, telemetry.raise_reg_max_avail)
    lower_availability = regulation_availability(BidType.LOWERREG, telemetry.lower_reg_max_avail)
    ramp_up, ramp_down = up ./ base, down ./ base
    if device isa PSY.ControllableLoad
        sides = (ramp_up => lower_availability, ramp_down => raise_availability)
    else
        sides = (ramp_up => raise_availability, ramp_down => lower_availability)
    end
    for (service, (ramp, availability)) in zip((BidType.RAISEREG, BidType.LOWERREG), sides)
        all(isnan, availability) && continue
        values = agc_ramp_rate.(ramp, availability, interval_hours)
        all(isnan, values) && continue
        PSY.add_time_series!(
            sys, device, single_series(fcas_series_name("fcas_agc_ramp_rate", service), first(grid), values, step(grid)),
        )
    end
    return
end
