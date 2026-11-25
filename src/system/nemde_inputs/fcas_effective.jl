# The effective FCAS offers and regulation ramping limits of each FCAS-bidding unit. The raw bid, telemetry and
# observed series are read in MW and divided by the system base once on read, so the unit-agnostic kernels and
# the written values are per-unit of the system base.


"""
    _fcas_ramp_rate_service(device, bid_type) -> BidType

The regulation service whose AGC ramp-rate series bounds `device`'s joint ramping row for
`bid_type`: `bid_type` itself for a generating unit (`RAISEREG` reads the ramp-up rate, `LOWERREG`
the ramp-down rate), and the other service for a `PSY.ControllableLoad`, whose `LowerReg` row is
bounded by the SCADA ramp-up rate and `RaiseReg` row by the ramp-down rate (§6.1).

# Returns
`BidType.RAISEREG` or `BidType.LOWERREG`.
"""
_fcas_ramp_rate_service(::PSY.Device, bid_type::BidType) = bid_type


_fcas_ramp_rate_service(::PSY.ControllableLoad, bid_type::BidType) = _other_regulation(bid_type)


"""
    _fcas_band_widths(curve, base) -> NTuple{FCAS_BAND_COUNT, Float64}

The band widths of an FCAS offer curve per-unit of `base`, zero-padded to [`FCAS_BAND_COUNT`](@ref). Throws
`ArgumentError` for a curve with more bands than `FCAS_BAND_COUNT`.

# Arguments
- `curve`: the offer curve, its `x_coords` cumulative MW.
- `base`: the system base power, MVA.

# Returns
`NTuple{FCAS_BAND_COUNT, Float64}`.
"""
function _fcas_band_widths(curve::PiecewiseStepData, base::Float64)::NTuple{FCAS_BAND_COUNT, Float64}
    x = get_x_coords(curve)
    bands = length(x) - 1
    bands <= FCAS_BAND_COUNT || throw(
        ArgumentError("FCAS offer curve has $bands bands, more than $FCAS_BAND_COUNT."),
    )
    # Each coordinate is divided by the base before differencing, as the written widths always were.
    return ntuple(i -> i <= bands ? Float64(x[i + 1] / base - x[i] / base) : 0.0, FCAS_BAND_COUNT)
end


"""
    _FCASWindow

The inputs every FCAS market of one device reads over its intervals, per-unit of the system base.

# Fields
- `stamps::Vector{DateTime}`: the first timestamp of each interval.
- `resolution::Dates.Period`: the interval length.
- `base::Float64`: the system base power, MVA.
- `fast_start::Vector{Bool}`: whether each interval carries a fast-start inflexibility profile.
- `uigf::Vector{Float64}`: the UIGF of each interval, `NaN` where absent or for a unit without one.
- `agc_status::Vector{Int}`: the AGC status of each interval, `-1` where unknown.
- `energy_gen::Vector{Float64}`, `energy_load::Vector{Float64}`: the energy limits of each interval, from
  [`_fcas_energy_limits`](@ref).
"""
struct _FCASWindow
    stamps::Vector{DateTime}
    resolution::Dates.Period
    base::Float64
    fast_start::Vector{Bool}
    uigf::Vector{Float64}
    agc_status::Vector{Int}
    energy_gen::Vector{Float64}
    energy_load::Vector{Float64}
end


"""
    _FCASBidSeries

One side of a device's FCAS bid in one market over a window, as read from its bid series, in MW.

# Fields
- `points::Vector{NTuple{4, Float64}}`: the `(EnablementMin, LowBreakpoint, HighBreakpoint, EnablementMax)` of each interval.
- `max_avail::Vector{Float64}`: the `MaxAvail` of each interval.
- `curves::Vector{PiecewiseStepData}`: the offer curve of each interval, empty when read without them.
- `name::String`, `device::String`: the trapezium series and device names that a malformed trapezium error reports.
"""
struct _FCASBidSeries
    points::Vector{NTuple{4, Float64}}
    max_avail::Vector{Float64}
    curves::Vector{PiecewiseStepData}
    name::String
    device::String
end


"""
    _FCASMarket

The state-independent inputs of one device's offer in one FCAS market over a window. Evaluate one interval
with [`_fcas_values_at`](@ref).

# Fields
- `window`: the device's [`_FCASWindow`](@ref).
- `direction`: the [`FCASBidDirection`](@ref) of the offer.
- `regulation`, `storage`, `upper`: whether the market is a regulation market, the device is a `PSY.Storage`, and
  the joint ramping row takes the upper form.
- `inactive`: the limit of an inactive offer, per-unit.
- `gen`, `load`: the [`_FCASBidSeries`](@ref) of the generation and load side, `nothing` for a side not offered.
- `enablement_min`, `enablement_max`: the AGC enablement limits per-unit, `NaN` where absent; empty for a contingency market.
- `capability`: the AGC ramping capability of the joint row per-unit, `NaN` where absent; empty for a contingency market.
- `bdu`: the AGC ramping capability of the BDU row per-unit, `0.0` where absent; empty unless a regulation offer on both sides.
"""
struct _FCASMarket
    window::_FCASWindow
    direction::FCASBidDirection
    regulation::Bool
    storage::Bool
    upper::Bool
    inactive::Float64
    gen::Union{Nothing, _FCASBidSeries}
    load::Union{Nothing, _FCASBidSeries}
    enablement_min::Vector{Float64}
    enablement_max::Vector{Float64}
    capability::Vector{Float64}
    bdu::Vector{Float64}
end


# The bid of `device` for `bid_type` on `side`, or `nothing`.
function _fcas_side_bid(device, bid_type::BidType, side::OfferSide)
    cost = _nem_offer_cost(device)
    isnothing(cost) && return nothing
    bids = get_fcas_bids(cost)
    i = findfirst(b -> b.service == bid_type && _fcas_bid_side(device, b) == side, bids)
    return isnothing(i) ? nothing : bids[i]
end


# The per-interval fast-start flags of `device`: whether a bid side's profile is fast-start (`is_fast_start`).
# A `FastStartProfile` held as a static bid value applies to every interval.
function _fcas_fast_start_flags(device, stamps::Vector{DateTime})
    n = length(stamps)
    flags = fill(false, n)
    cost = _nem_offer_cost(device)
    isnothing(cost) && return flags
    for bid in get_energy_bids(cost)
        isnothing(bid.fast_start_profile) && continue
        profiles = bid_value(device, bid, :fast_start_profile, first(stamps), n)
        for t in 1:n
            profile = profiles isa AbstractVector ? profiles[t] : profiles
            flags[t] |= is_fast_start(profile)
        end
    end
    return flags
end


# The energy `MAXAVAIL` of `device` on `side` over `stamps` per-unit, or `nothing` without an energy bid on that side.
function _fcas_energy_max_avail(device, side::OfferSide, stamps::Vector{DateTime}, base::Float64)
    cost = _nem_offer_cost(device)
    bid = isnothing(cost) ? nothing : _energy_bid(cost, side)
    isnothing(bid) && return nothing
    return _values_on_grid(device, bid.max_avail, stamps; field = :max_avail) ./ base
end


"""
    _fcas_energy_limits(device, stamps, base, uigf) -> @NamedTuple{gen::Vector{Float64}, load::Vector{Float64}}

The energy limits of `device` per interval per-unit, as `(gen, load)`, that the AEMO *FCAS Model in NEMDE* §5
energy pre-condition reads. A non-storage device reads its [`effective_energy_availability`](@ref) in `gen`
(`Inf` without an energy bid, zero for a non-scheduled load without one) and `Inf` in `load`. A storage
device reads its `MAXAVAIL` on each side, or the static output and input ratings when either side has none.

# Arguments
- `device`: the bidding device.
- `stamps`: the first timestamp of each interval.
- `base`: the system base power, MVA.
- `uigf`: the UIGF per interval per-unit, or `nothing` when the unit is not semi-scheduled.

# Returns
`@NamedTuple{gen::Vector{Float64}, load::Vector{Float64}}`.
"""
function _fcas_energy_limits(device, stamps::Vector{DateTime}, base::Float64, uigf)
    n = length(stamps)
    if device isa PSY.Storage
        gen = _fcas_energy_max_avail(device, OfferSide.GEN, stamps, base)
        load = _fcas_energy_max_avail(device, OfferSide.LOAD, stamps, base)
        isnothing(gen) || isnothing(load) || return (; gen, load)
        # The stored ratings are per-unit of the device base, so this does not depend on the display units.
        scale = PSY.get_base_power(device) / base
        output = getproperty(device, :output_active_power_limits).max * scale
        input = getproperty(device, :input_active_power_limits).max * scale
        return (; gen = fill(output, n), load = fill(input, n))
    end
    pinned = is_non_scheduled_load(device)
    max_avail = _fcas_energy_max_avail(device, only(energy_offer_sides(device)), stamps, base)
    gen = if isnothing(max_avail)
        pinned ? zeros(n) : fill(Inf, n)
    else
        ramp_up = _values_on_grid(device, get_telemetry(device).ramp_up_limit, stamps)
        effective_energy_availability.(max_avail, uigf, ramp_up, pinned)
    end
    return (; gen, load = fill(Inf, n))
end


# The window of `device` over `stamps`, read at the interval `resolution` of the system base `base`.
function _fcas_window(device, stamps::Vector{DateTime}, resolution::Dates.Period, base::Float64)
    telemetry = get_telemetry(device)
    uigf = isnothing(telemetry.uigf) ? nothing : _values_on_grid(device, telemetry.uigf, stamps) ./ base
    energy = _fcas_energy_limits(device, stamps, base, uigf)
    status = _values_on_grid(device, telemetry.agc_status, stamps)
    return _FCASWindow(
        stamps, resolution, base, _fcas_fast_start_flags(device, stamps),
        something(uigf, fill(NaN, length(stamps))),
        [isnan(v) ? -1 : round(Int, v) for v in status],
        energy.gen, energy.load,
    )
end


# The regulation AGC ramping capability of `device` on `service` over the window (AEMO *FCAS Model in NEMDE* §4.2),
# per-unit, `NaN` at an interval with no ramp rate and throughout when the device has no
# `"fcas_agc_ramp_rate_<service>"` series. The series is per-unit MW/h, times the interval length in hours.
function _fcas_agc_capability(window::_FCASWindow, device, service::BidType)
    name = fcas_series_name("fcas_agc_ramp_rate", service)
    has_time_series(device, SingleTimeSeries, name) || return fill(NaN, length(window.stamps))
    rate = get_time_series_values(SingleTimeSeries, device, name; start_time = first(window.stamps), len = length(window.stamps))
    hours = Dates.value(Millisecond(window.resolution)) / 3_600_000
    return Float64.(rate) .* hours
end


# The bid series of `device`'s FCAS bid for `bid_type` on the side of `decremental` over the window, without offer
# curves unless `offer_curves`. Throws `ArgumentError` naming `device` when it has no bid on that side.
function _fcas_bid_series(window::_FCASWindow, device, bid_type::BidType, decremental::Bool; offer_curves::Bool = true)
    side = offer_side(decremental)
    bid = _fcas_side_bid(device, bid_type, side)
    isnothing(bid) && throw(
        ArgumentError("\"$(PSY.get_name(device))\" has no FCAS bid for $(string(bid_type)) on $(string(side)); call set_market_bids! first."),
    )
    stamps = window.stamps
    points = _values_on_grid(device, bid.trapezium, stamps; field = :trapezium)
    curves = if offer_curves
        _read_fcas_series(
            "curve", device, _fcas_offer_series_name(device, bid_type, decremental), bid_type, decremental, first(stamps), length(stamps),
        )
    else
        PiecewiseStepData[]
    end
    return _FCASBidSeries(
        convert(Vector{NTuple{4, Float64}}, points), _values_on_grid(device, bid.max_avail, stamps; field = :max_avail),
        curves, IS.get_name(bid.trapezium), PSY.get_name(device),
    )
end


"""
    _fcas_market(window, device, bid_type, direction; offer_curves = true) -> _FCASMarket

The [`_FCASMarket`](@ref) of `device`'s offer in `bid_type` over `window`, reading the bid series of each side
`direction` offers and, for a regulation market, the AGC enablement limits and ramping capabilities.

# Arguments
- `window`: the device's [`_FCASWindow`](@ref).
- `device`: the bidding device.
- `bid_type`: the FCAS market.
- `direction`: the [`FCASBidDirection`](@ref) of the offer, not `NONE`.
- `offer_curves`: whether to read the offer curves, which the scaled trapeziums do not need.

# Returns
An [`_FCASMarket`](@ref).
"""
function _fcas_market(window::_FCASWindow, device, bid_type::BidType, direction::FCASBidDirection; offer_curves::Bool = true)
    offered = fcas_offer_sides(direction)
    gen = false in offered ? _fcas_bid_series(window, device, bid_type, false; offer_curves) : nothing
    load = true in offered ? _fcas_bid_series(window, device, bid_type, true; offer_curves) : nothing
    regulation = bid_type in FCAS_REGULATION_MARKETS
    enablement_min = Float64[]
    enablement_max = Float64[]
    capability = Float64[]
    bdu = Float64[]
    if regulation
        telemetry = get_telemetry(device)
        pairs = _values_on_grid(
            device, bid_type == BidType.RAISEREG ? telemetry.raise_reg_enablement : telemetry.lower_reg_enablement, window.stamps;
            absent = (NaN, NaN),
        )
        enablement_min = [p[1] / window.base for p in pairs]
        enablement_max = [p[2] / window.base for p in pairs]
        capability = _fcas_agc_capability(window, device, _fcas_ramp_rate_service(device, bid_type))
        if direction == FCASBidDirection.BOTH
            bdu = replace(_fcas_agc_capability(window, device, bid_type), NaN => 0.0)
        end
    end
    return _FCASMarket(
        window, direction, regulation, device isa PSY.Storage, bid_type == fcas_upper_regulation_service(device),
        FCAS_INACTIVE_LIMIT_MW / window.base, gen, load, enablement_min, enablement_max, capability, bdu,
    )
end


# `x`, or `nothing` where it is `NaN`: the absent-input form `scale_fcas_trapezium` takes.
_unless_nan(x::Float64) = isnan(x) ? nothing : x


# The scaled trapezium of `side` of `market` at interval `t`, per-unit (AEMO *FCAS Model in NEMDE* §4).
function _fcas_scaled_trapezium(market::_FCASMarket, side::_FCASBidSeries, t::Int)::FCASTrapezium
    base = market.window.base
    e, l, h, m = side.points[t] ./ base
    trap = _validate_fcas_trapezium(
        FCASTrapezium(; enablement_min = e, low_breakpoint = l, high_breakpoint = h, enablement_max = m, max_avail = side.max_avail[t] / base),
        () -> "\"$(side.name)\" on \"$(side.device)\" at step $t",
    )
    regulation = market.regulation
    return scale_fcas_trapezium(
        trap;
        agc_enablement_min = regulation ? _unless_nan(market.enablement_min[t]) : nothing,
        agc_enablement_max = regulation ? _unless_nan(market.enablement_max[t]) : nothing,
        agc_max_avail = regulation ? _unless_nan(market.capability[t]) : nothing,
        uigf = _unless_nan(market.window.uigf[t]),
        is_regulation = regulation,
    )
end


"""
    _fcas_interval(gen_trap, gen_widths, load_trap, load_widths, energy_gen, energy_load, agc_status, state,
        capability, bdu, fast_start; regulation, storage, direction, upper, inactive)

One interval of one device's offer in one FCAS market: the effective offer of each side
([`fcas_effective_offer`](@ref)) and, for a regulation market, the ramping limits ([`fcas_ramping_limits`](@ref)).
A side is enabled by the AEMO *FCAS Model in NEMDE* §5 pre-conditions ([`fcas_preconditions_ok`](@ref)) and its
stranded rule ([`fcas_state_stranded_ok`](@ref)); a regulation offer on both sides by the combined stranded rule
([`fcas_both_sides_stranded_ok`](@ref)), whose per-side result a storage device's sides take. All quantities are in one
unit, per-unit of the system base as written.

# Arguments
- `gen_trap`, `load_trap`: the scaled trapezium of each side, `nothing` for a side not offered.
- `gen_widths`, `load_widths`: the zero-padded band widths of each side, `nothing` for a side not offered.
- `energy_gen`, `energy_load`: the energy limits of the interval, from [`_fcas_energy_limits`](@ref).
- `agc_status`: the AGC status of the interval, `-1` where unknown.
- `state`: the [`NEMUnitState`](@ref) at the start of the interval.
- `capability`: the AGC ramping capability of the joint row, `NaN` where absent; unused for a contingency market.
- `bdu`: the AGC ramping capability of the BDU row, `0.0` where absent or the offer is one-sided.
- `fast_start`: whether the interval carries a fast-start inflexibility profile.
- `regulation`, `storage`: whether the market is a regulation market and the device a `PSY.Storage`.
- `direction`: the [`FCASBidDirection`](@ref) of the offer.
- `upper`: whether the joint ramping row takes the upper form.
- `inactive`: the limit of an inactive offer or row.

# Returns
`(gen, load, ramping)`: the `NTuple{15, Float64}` offer of each side (`nothing` for a side not offered) and the
`NTuple{2, Float64}` ramping limits `(joint, bdu)` (`nothing` for a contingency market).
"""
function _fcas_interval(
        gen_trap::Union{Nothing, FCASTrapezium}, gen_widths::Union{Nothing, NTuple{FCAS_BAND_COUNT, Float64}},
        load_trap::Union{Nothing, FCASTrapezium}, load_widths::Union{Nothing, NTuple{FCAS_BAND_COUNT, Float64}},
        energy_gen::Float64, energy_load::Float64, agc_status::Int, state::NEMUnitState,
        capability::Float64, bdu::Float64, fast_start::Bool;
        regulation::Bool, storage::Bool, direction::FCASBidDirection, upper::Bool, inactive::Float64,
    )
    gen_ok = !isnothing(gen_trap) &&
        fcas_preconditions_ok(gen_trap, sum(gen_widths), energy_gen, energy_load, agc_status, regulation, false, storage)
    load_ok = !isnothing(load_trap) &&
        fcas_preconditions_ok(load_trap, sum(load_widths), energy_gen, energy_load, agc_status, regulation, true, storage)
    gen_own = gen_ok && fcas_state_stranded_ok(gen_trap, state, storage)
    load_own = load_ok && fcas_state_stranded_ok(load_trap, state, storage)
    if regulation && direction == FCASBidDirection.BOTH
        joint = fcas_both_sides_stranded_ok(gen_trap, load_trap, gen_ok, load_ok, state)
        gen_enabled, load_enabled = storage ? joint : (gen_own, load_own)
        enabled = joint[1] | joint[2]
    else
        gen_enabled, load_enabled = gen_own, load_own
        enabled = direction == FCASBidDirection.DECREMENTAL ? load_enabled : gen_enabled
    end
    gen = isnothing(gen_trap) ? nothing : fcas_effective_offer(gen_trap, gen_widths, gen_enabled, inactive)
    load = isnothing(load_trap) ? nothing : fcas_effective_offer(load_trap, load_widths, load_enabled, inactive)
    regulation || return gen, load, nothing
    joint_capability = isnan(capability) ? 0.0 : capability
    return gen, load, fcas_ramping_limits(joint_capability, bdu, enabled, upper, fast_start, inactive, state)
end


"""
    _fcas_values_at(market, t, state) -> Tuple

The [`_fcas_interval`](@ref) values of `market` at interval `t` when the unit starts it in `state`, its
`initial_mw` per-unit.

# Arguments
- `market`: the [`_FCASMarket`](@ref).
- `t`: the index of the interval in the market's window.
- `state`: the [`NEMUnitState`](@ref) at the start of the interval.

# Returns
`(gen, load, ramping)`, as [`_fcas_interval`](@ref) returns them.
"""
function _fcas_values_at(market::_FCASMarket, t::Int, state::NEMUnitState)
    (; window, gen, load, regulation) = market
    gen_trap = isnothing(gen) ? nothing : _fcas_scaled_trapezium(market, gen, t)
    gen_widths = isnothing(gen) ? nothing : _fcas_band_widths(gen.curves[t], window.base)
    load_trap = isnothing(load) ? nothing : _fcas_scaled_trapezium(market, load, t)
    load_widths = isnothing(load) ? nothing : _fcas_band_widths(load.curves[t], window.base)
    return _fcas_interval(
        gen_trap, gen_widths, load_trap, load_widths, window.energy_gen[t], window.energy_load[t], window.agc_status[t], state,
        regulation ? market.capability[t] : NaN, isempty(market.bdu) ? 0.0 : market.bdu[t], window.fast_start[t];
        regulation, market.storage, market.direction, market.upper, market.inactive,
    )
end


# Adds `device`'s effective offers and ramping limits in each of its FCAS markets, on `stamps`.
function _set_device_fcas_effective_offers!(sys::PSY.System, device::PSY.Device, stamps::Vector{DateTime}, resolution::Dates.Period, base::Float64)
    window = nothing
    states = NEMUnitState[]
    n = length(stamps)
    start = first(stamps)
    for bid_type in unique(get_bid_type(s) for s in PSY.get_services(device) if s isa FCASService)
        direction = fcas_bid_direction(device, bid_type)
        direction == FCASBidDirection.NONE && continue
        # The window and observed states are read once per device.
        if isnothing(window)
            window = _fcas_window(device, stamps, resolution, base)
            states = [NEMUnitState(s.initial_mw / base, s.dispatch_mode, s.time_in_mode) for s in observed_unit_states(device, stamps)]
        end
        market = _fcas_market(window, device, bid_type, direction)
        gen = isnothing(market.gen) ? nothing : Vector{NTuple{15, Float64}}(undef, n)
        load = isnothing(market.load) ? nothing : Vector{NTuple{15, Float64}}(undef, n)
        ramping = market.regulation ? Vector{NTuple{2, Float64}}(undef, n) : nothing
        for t in 1:n
            g, l, r = _fcas_values_at(market, t, states[t])
            isnothing(gen) || (gen[t] = g)
            isnothing(load) || (load[t] = l)
            isnothing(ramping) || (ramping[t] = r)
        end
        for (decremental, values) in ((false, gen), (true, load))
            isnothing(values) && continue
            PSY.add_time_series!(sys, device, single_series(fcas_effective_series_name(bid_type, decremental), start, values, resolution))
        end
        isnothing(ramping) || PSY.add_time_series!(sys, device, single_series(fcas_ramping_series_name(bid_type), start, ramping, resolution))
    end
    return
end


"""
    _set_fcas_effective_offers!(sys, grid = _nemde_grid(sys))

Adds the effective FCAS offers and regulation ramping limits of every available device contributing to an
[`FCASService`](@ref), named by [`fcas_effective_series_name`](@ref) and [`fcas_ramping_series_name`](@ref), per-unit
of the system base. The AGC ramp rates it reads must already be written by [`_set_dispatch_limits!`](@ref).

# Arguments
- `sys`: the `System` to add to.
- `grid`: the timestamps the single time series of `sys` share; read from `sys` by default.

# Returns
`nothing`.
"""
function _set_fcas_effective_offers!(sys::PSY.System, grid = _nemde_grid(sys))
    base = PSY.get_base_power(sys)
    stamps = collect(grid)
    index = _contributing_device_index(sys)
    seen = Set{Base.UUID}()
    for svc in PSY.get_components(FCASService, sys), device in get(index, IS.get_uuid(svc), PSY.Device[])
        uuid = IS.get_uuid(device)
        uuid in seen && continue
        push!(seen, uuid)
        PSY.get_available(device) || continue
        _set_device_fcas_effective_offers!(sys, device, stamps, step(grid), base)
    end
    return
end
