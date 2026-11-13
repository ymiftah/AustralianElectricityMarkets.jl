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
    widths = diff(get_x_coords(curve) ./ base)
    length(widths) <= FCAS_BAND_COUNT || throw(
        ArgumentError("FCAS offer curve has $(length(widths)) bands, more than $FCAS_BAND_COUNT."),
    )
    return ntuple(i -> i <= length(widths) ? Float64(widths[i]) : 0.0, FCAS_BAND_COUNT)
end


"""
    _FCASWindow

The inputs an FCAS offer of one device reads over its intervals, per-unit of the system base.

# Fields
- `stamps::Vector{DateTime}`: the first timestamp of each interval.
- `resolution::Dates.Period`: the interval length.
- `base::Float64`: the system base power, MVA.
- `states::Vector{NEMUnitState}`: the state at the start of each interval, its `initial_mw` per-unit.
- `fast_start::Vector{Bool}`: whether each interval carries a fast-start inflexibility profile.
- `uigf::Union{Nothing, Vector{Float64}}`: the UIGF of each interval, `nothing` for a unit without one.
- `agc_status::Vector{Int}`: the AGC status of each interval, `-1` where unknown.
- `ramp_up::Vector{Float64}`: the telemetered ramp-up limit of each interval, `NaN` where it has no row.
"""
struct _FCASWindow
    stamps::Vector{DateTime}
    resolution::Dates.Period
    base::Float64
    states::Vector{NEMUnitState}
    fast_start::Vector{Bool}
    uigf::Union{Nothing, Vector{Float64}}
    agc_status::Vector{Int}
    ramp_up::Vector{Float64}
end


"""
    _FCASSide

One side of a device's FCAS bid over a window, per-unit of the system base.

# Fields
- `trapeziums::Vector{FCASTrapezium}`: the scaled trapezium of each interval.
- `widths::Vector{NTuple{FCAS_BAND_COUNT, Float64}}`: the zero-padded band widths of each interval.
- `total_width::Vector{Float64}`: the sum of the band widths of each interval.
"""
struct _FCASSide
    trapeziums::Vector{FCASTrapezium}
    widths::Vector{NTuple{FCAS_BAND_COUNT, Float64}}
    total_width::Vector{Float64}
end


# The bid of `device` for `bid_type` on `side`, or `nothing`.
function _fcas_side_bid(device, bid_type::BidType, side::OfferSide)
    cost = _nem_offer_cost(device)
    isnothing(cost) && return nothing
    bids = get_fcas_bids(cost)
    i = findfirst(b -> b.service == bid_type && _fcas_bid_side(device, b) == side, bids)
    return isnothing(i) ? nothing : bids[i]
end


# The key of a series-backed FCAS bid field; a static field has no series to read the bid from.
function _fcas_series_key(device, value, field::Symbol)
    value isa IS.StaticTimeSeriesKey || throw(
        ArgumentError(
            "\"$(PSY.get_name(device))\" has a static `$(field)` field; FCAS trapeziums and MAXAVAIL need " *
                "series-backed bid inputs, as set_market_bids! writes them.",
        ),
    )
    return value
end


# The values of a series-backed FCAS bid field over `stamps`, as the series stores them.
function _fcas_bid_window(device, value, field::Symbol, stamps::Vector{DateTime})
    key = _fcas_series_key(device, value, field)
    return IS.get_time_series_values(device, key; start_time = first(stamps), len = length(stamps))
end


# The values of a telemetry field over `stamps` as stored: a static value is repeated, and an absent field is `nothing`.
function _fcas_telemetry_window(device, value, stamps::Vector{DateTime})
    isnothing(value) && return nothing
    value isa IS.StaticTimeSeriesKey || return fill(Float64(value), length(stamps))
    return Float64.(IS.get_time_series_values(device, value; start_time = first(stamps), len = length(stamps)))
end


# The `(min, max)` pair of a telemetry enablement field over `stamps` per-unit of `base`, as its two vectors.
function _fcas_pair_window(device, value, stamps::Vector{DateTime}, base::Float64)
    pairs = value isa IS.StaticTimeSeriesKey ?
        IS.get_time_series_values(device, value; start_time = first(stamps), len = length(stamps)) : fill(value, length(stamps))
    return ([p[1] / base for p in pairs], [p[2] / base for p in pairs])
end


# The per-interval fast-start flags of `device`: whether a bid side's `T1` to `T4` profile has a positive value.
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
            flags[t] |= any(>(0.0), (profile.t1, profile.t2, profile.t3, profile.t4))
        end
    end
    return flags
end


# The window of `device` over `stamps`, read at the interval `resolution` of the system base `base`.
function _fcas_window(device, stamps::Vector{DateTime}, resolution::Dates.Period, base::Float64)
    telemetry = get_telemetry(device)
    status = _fcas_telemetry_window(device, telemetry.agc_status, stamps)
    uigf = _fcas_telemetry_window(device, telemetry.uigf, stamps)
    states = [NEMUnitState(s.initial_mw / base, s.dispatch_mode) for s in observed_unit_states(device, stamps)]
    return _FCASWindow(
        stamps, resolution, base, states, _fcas_fast_start_flags(device, stamps),
        isnothing(uigf) ? nothing : uigf ./ base,
        [isnan(v) ? -1 : round(Int, v) for v in status],
        _fcas_telemetry_window(device, telemetry.ramp_up_limit, stamps),
    )
end


# The regulation AGC ramping capability of `device` on `service` over the window, per-unit, `NaN` at an interval with no
# ramp rate; `nothing` when the device has no `"fcas_agc_ramp_rate_<service>"` series. The series is per-unit MW/h.
function _fcas_agc_capability(window::_FCASWindow, device, service::BidType)
    name = fcas_series_name("fcas_agc_ramp_rate", service)
    has_time_series(device, SingleTimeSeries, name) || return nothing
    rate = get_time_series_values(SingleTimeSeries, device, name; start_time = first(window.stamps), len = length(window.stamps))
    hours = Dates.value(Millisecond(window.resolution)) / 3_600_000
    return Float64.(rate) .* hours
end


# A capability over the window with `NaN` and an absent series both read as `0.0`, no cap.
_fcas_capability_values(::Nothing, n::Int) = zeros(n)
_fcas_capability_values(capability::Vector{Float64}, ::Int) = replace(capability, NaN => 0.0)


# The energy `MAXAVAIL` of `device` on `side` over the window per-unit, or `nothing` without an energy bid on that side.
function _fcas_energy_max_avail(window::_FCASWindow, device, side::OfferSide)
    cost = _nem_offer_cost(device)
    bid = isnothing(cost) ? nothing : _energy_bid(cost, side)
    isnothing(bid) && return nothing
    return Float64.(_fcas_bid_window(device, bid.max_avail, :max_avail, window.stamps)) ./ window.base
end


# The energy availability of a non-storage device over the window per-unit, `nothing` where it has no energy bid
# and is not a non-scheduled load (which reads zeros).
function _fcas_unit_availability(window::_FCASWindow, device)
    side = only(energy_offer_sides(device))
    pinned = is_non_scheduled_load(device)
    max_avail = _fcas_energy_max_avail(window, device, side)
    isnothing(max_avail) && return pinned ? zeros(length(window.stamps)) : nothing
    return effective_energy_availability(max_avail, window.uigf, window.ramp_up, pinned)
end


# The energy limits of `device` per interval per-unit, as `(gen, load)`. A non-storage device reads its own
# availability in `gen` (`Inf` where it has none). A storage device reads its `MAXAVAIL` on each side, or
# the static output and input ratings when either side has none.
function _fcas_energy_limits(window::_FCASWindow, device)
    n = length(window.stamps)
    if device isa PSY.Storage
        gen = _fcas_energy_max_avail(window, device, OfferSide.GEN)
        load = _fcas_energy_max_avail(window, device, OfferSide.LOAD)
        if !(isnothing(gen) || isnothing(load))
            return (; gen, load)
        end
        # The rating is read in the display units, so it is divided by their multiplier to be per-unit.
        multiplier = _fcas_units_multiplier(device)
        output = PSY.get_output_active_power_limits(device).max / multiplier
        input = PSY.get_input_active_power_limits(device).max / multiplier
        return (; gen = fill(output, n), load = fill(input, n))
    end
    avail = _fcas_unit_availability(window, device)
    return (; gen = isnothing(avail) ? fill(Inf, n) : avail, load = fill(Inf, n))
end


# The scaled trapeziums of `device`'s FCAS bid on the side of `decremental` over the window, per-unit
# (AEMO *FCAS Model in NEMDE* §4). Throws `ArgumentError` naming `device` when it has no bid on that side.
function _fcas_scaled_trapeziums(window::_FCASWindow, device, bid_type::BidType, decremental::Bool)::Vector{FCASTrapezium}
    side = offer_side(decremental)
    bid = _fcas_side_bid(device, bid_type, side)
    isnothing(bid) && throw(
        ArgumentError("\"$(PSY.get_name(device))\" has no FCAS bid for $(string(bid_type)) on $(string(side)); call set_market_bids! first."),
    )
    n = length(window.stamps)
    points = _fcas_bid_window(device, bid.trapezium, :trapezium, window.stamps)
    max_avail = Float64.(_fcas_bid_window(device, bid.max_avail, :max_avail, window.stamps))
    is_regulation = bid_type in FCAS_REGULATION_MARKETS
    telemetry = get_telemetry(device)
    enablement = if is_regulation
        _fcas_pair_window(
            device, bid_type == BidType.RAISEREG ? telemetry.raise_reg_enablement : telemetry.lower_reg_enablement, window.stamps, window.base,
        )
    else
        (nothing, nothing)
    end
    capability = is_regulation ? _fcas_agc_capability(window, device, _fcas_ramp_rate_service(device, bid_type)) : nothing
    traps = Vector{FCASTrapezium}(undef, n)
    for t in 1:n
        e, l, h, m = Float64.(points[t]) ./ window.base
        trap = _validate_fcas_trapezium(
            FCASTrapezium(; enablement_min = e, low_breakpoint = l, high_breakpoint = h, enablement_max = m, max_avail = max_avail[t] / window.base),
            () -> "\"$(IS.get_name(bid.trapezium))\" on \"$(PSY.get_name(device))\" at step $t",
        )
        traps[t] = scale_fcas_trapezium(
            trap;
            agc_enablement_min = _fcas_input(enablement[1], t),
            agc_enablement_max = _fcas_input(enablement[2], t),
            agc_max_avail = _fcas_input(capability, t),
            uigf = _fcas_input(window.uigf, t),
            is_regulation,
        )
    end
    return traps
end


# The scaled trapeziums and band widths of `device`'s FCAS bid on the side of `decremental` over the window, per-unit.
function _fcas_side(window::_FCASWindow, device, bid_type::BidType, decremental::Bool)
    traps = _fcas_scaled_trapeziums(window, device, bid_type, decremental)
    curves = _read_fcas_series(
        "curve", device, _fcas_offer_series_name(device, bid_type, decremental), bid_type, decremental, first(window.stamps), length(traps),
    )
    widths = [_fcas_band_widths(c, window.base) for c in curves]
    return _FCASSide(traps, widths, [sum(w) for w in widths])
end


# A telemetry value at interval `t` as the scaling input it is, or `nothing` where absent or `NaN`.
_fcas_input(::Nothing, ::Int) = nothing
_fcas_input(series::Vector{Float64}, t::Int) = isnan(series[t]) ? nothing : series[t]


# AEMO *FCAS Model in NEMDE* §5 pre-conditions of one side per interval, ANDed with the stranded rule for the state.
function _fcas_side_enabled(
        window::_FCASWindow, device, bid_type::BidType, decremental::Bool, side::_FCASSide, energy,
    )::Vector{Bool}
    storage = device isa PSY.Storage
    regulation = bid_type in FCAS_REGULATION_MARKETS
    return map(eachindex(window.stamps)) do t
        fcas_preconditions_ok(
            side.trapeziums[t], side.total_width[t], energy.gen[t], energy.load[t], window.agc_status[t],
            regulation, decremental, storage,
        ) || return false
        return fcas_state_stranded_ok(side.trapeziums[t], window.states[t], storage)
    end
end


# The §5 enablement of a storage device's regulation bid on both sides per interval, from the stranded rule for both.
function _fcas_both_sides_enabled(window::_FCASWindow, device, gen::_FCASSide, load::_FCASSide, energy)
    storage = device isa PSY.Storage
    flags = map(eachindex(window.stamps)) do t
        gen_ok = fcas_preconditions_ok(
            gen.trapeziums[t], gen.total_width[t], energy.gen[t], energy.load[t], window.agc_status[t], true, false, storage,
        )
        load_ok = fcas_preconditions_ok(
            load.trapeziums[t], load.total_width[t], energy.gen[t], energy.load[t], window.agc_status[t], true, true, storage,
        )
        return fcas_both_sides_stranded_ok(gen.trapeziums[t], load.trapeziums[t], gen_ok, load_ok, window.states[t])
    end
    return first.(flags), last.(flags)
end


# The enablement of `device`'s regulation `bid_type` per interval for the unit as a whole: either side enabled for
# `BOTH`, the one side otherwise.
function _fcas_regulation_enabled(
        window::_FCASWindow, device, bid_type::BidType, direction::FCASBidDirection, sides::Dict{Bool, _FCASSide}, energy,
    )
    if direction == FCASBidDirection.BOTH
        gen_enabled, load_enabled = _fcas_both_sides_enabled(window, device, sides[false], sides[true], energy)
        return gen_enabled .| load_enabled
    end
    decremental = direction == FCASBidDirection.DECREMENTAL
    return _fcas_side_enabled(window, device, bid_type, decremental, sides[decremental], energy)
end


# The regulation ramping limits of `device` per interval per-unit, `(joint, bdu)` (AEMO *FCAS Model in NEMDE* §6.1, §6.4).
function _fcas_ramping(
        window::_FCASWindow, device, bid_type::BidType, direction::FCASBidDirection, inactive::Float64,
        sides::Dict{Bool, _FCASSide}, energy,
    )
    n = length(window.stamps)
    capability = _fcas_capability_values(_fcas_agc_capability(window, device, _fcas_ramp_rate_service(device, bid_type)), n)
    bdu = direction == FCASBidDirection.BOTH ?
        _fcas_capability_values(_fcas_agc_capability(window, device, bid_type), n) : zeros(n)
    enabled = _fcas_regulation_enabled(window, device, bid_type, direction, sides, energy)
    upper = bid_type == fcas_upper_regulation_service(device)
    return [
        fcas_ramping_limits(capability[t], bdu[t], enabled[t], upper, window.fast_start[t], inactive, window.states[t])
            for t in eachindex(window.stamps)
    ]
end


# The effective offers of `device`'s `bid_type` per interval per-unit, keyed by each offer's `decremental` flag, and the
# regulation ramping limits (`nothing` for a contingency market).
function _fcas_effective_values(
        window::_FCASWindow, device, bid_type::BidType, direction::FCASBidDirection, inactive::Float64, energy,
    )
    regulation = bid_type in FCAS_REGULATION_MARKETS
    sides = Dict{Bool, _FCASSide}(dec => _fcas_side(window, device, bid_type, dec) for dec in fcas_offer_sides(direction))
    enabled = if direction == FCASBidDirection.BOTH && device isa PSY.Storage && regulation
        gen_enabled, load_enabled = _fcas_both_sides_enabled(window, device, sides[false], sides[true], energy)
        Dict{Bool, Vector{Bool}}(false => gen_enabled, true => load_enabled)
    else
        Dict{Bool, Vector{Bool}}(dec => _fcas_side_enabled(window, device, bid_type, dec, sides[dec], energy) for dec in fcas_offer_sides(direction))
    end
    offers = Dict{Bool, Vector{NTuple{15, Float64}}}()
    for (decremental, mask) in enabled
        side = sides[decremental]
        offers[decremental] = [fcas_effective_offer(side.trapeziums[t], side.widths[t], mask[t], inactive) for t in eachindex(mask)]
    end
    regulation || return offers, nothing
    return offers, _fcas_ramping(window, device, bid_type, direction, inactive, sides, energy)
end


"""
    _is_unpriced_unavailable(svc, device, bid_type) -> Bool

Whether `device` is unavailable and carries no stored offer curve for `svc` on one of its sides:
NEMDE-path units with no energy bids get no FCAS offer curve, and nothing reads their effective offer.
An available device without its curve is not skipped, so its missing data still fails.

# Returns
`Bool`.
"""
function _is_unpriced_unavailable(svc::FCASService, device::PSY.Device, bid_type::BidType)
    PSY.get_available(device) && return false
    sides = fcas_offer_sides(fcas_bid_direction(device, bid_type))
    return !all(dec -> !isnothing(_fcas_offer_key(device, bid_type, offer_side(dec))), sides)
end


"""
    _attach_fcas_effective_series!(sys, device, bid_type, base)

Adds `device`'s effective offer series for `bid_type` ([`fcas_effective_series_name`](@ref)) and, for a regulation
market, its ramping limits ([`fcas_ramping_series_name`](@ref)), on the timestamps of its bid's trapezium series.
Values are per-unit of `base`, the system base power in MVA. No-op for a device without a `bid_type` FCAS bid.

# Arguments
- `sys`: the `System` to add to.
- `device`: the bidding device.
- `bid_type`: the FCAS market.
- `base`: the system base power, MVA.

# Returns
`nothing`.
"""
function _attach_fcas_effective_series!(sys::PSY.System, device::PSY.Device, bid_type::BidType, base::Float64)
    direction = fcas_bid_direction(device, bid_type)
    direction == FCASBidDirection.NONE && return
    side = direction == FCASBidDirection.DECREMENTAL ? OfferSide.LOAD : OfferSide.GEN
    bid = _fcas_side_bid(device, bid_type, side)
    isnothing(bid) && throw(ArgumentError("\"$(PSY.get_name(device))\" has no FCAS bid for $(string(bid_type)) on $(string(side))."))
    name = IS.get_name(_fcas_series_key(device, bid.trapezium, :trapezium))
    stamps = PSY.get_time_series_timestamps(PSY.SingleTimeSeries, device, name)
    resolution = IS.get_resolution(PSY.get_time_series(PSY.SingleTimeSeries, device, name))
    window = _fcas_window(device, stamps, resolution, base)
    energy = _fcas_energy_limits(window, device)
    offers, ramping = _fcas_effective_values(window, device, bid_type, direction, FCAS_INACTIVE_LIMIT_MW / base, energy)
    for (decremental, values) in offers
        PSY.add_time_series!(
            sys, device, single_series(fcas_effective_series_name(bid_type, decremental), first(stamps), values, resolution),
        )
    end
    isnothing(ramping) && return
    PSY.add_time_series!(sys, device, single_series(fcas_ramping_series_name(bid_type), first(stamps), ramping, resolution))
    return
end


"""
    _set_fcas_effective_offers!(sys)

Adds the effective FCAS offers and regulation ramping limits of every available device contributing to an
[`FCASService`](@ref), named by [`fcas_effective_series_name`](@ref) and [`fcas_ramping_series_name`](@ref), per-unit
of the system base. The AGC ramp rates it reads must already be written by [`_set_dispatch_limits!`](@ref).

# Arguments
- `sys`: the `System` to add to.

# Returns
`nothing`.
"""
function _set_fcas_effective_offers!(sys::PSY.System)
    base = PSY.get_base_power(sys)
    done = Set{Tuple{DataType, String, BidType}}()
    for svc in PSY.get_components(FCASService, sys)
        bid_type = get_bid_type(svc)
        for device in PSY.get_contributing_devices(sys, svc)
            key = (typeof(device), PSY.get_name(device), bid_type)
            key in done && continue
            push!(done, key)
            _is_unpriced_unavailable(svc, device, bid_type) && continue
            PSY.get_available(device) || continue
            _attach_fcas_effective_series!(sys, device, bid_type, base)
        end
    end
    return
end
