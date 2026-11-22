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


# The window of `device` over `stamps`, read at the interval `resolution` of the system base `base`. `states`
# overrides the observed state at each stamp, with `initial_mw` in MW.
function _fcas_window(device, stamps::Vector{DateTime}, resolution::Dates.Period, base::Float64; states = nothing)
    telemetry = get_telemetry(device)
    status = _values_on_grid(device, telemetry.agc_status, stamps)
    uigf = isnothing(telemetry.uigf) ? nothing : _values_on_grid(device, telemetry.uigf, stamps)
    states = [NEMUnitState(s.initial_mw / base, s.dispatch_mode, s.time_in_mode) for s in something(states, observed_unit_states(device, stamps))]
    return _FCASWindow(
        stamps, resolution, base, states, _fcas_fast_start_flags(device, stamps),
        isnothing(uigf) ? nothing : uigf ./ base,
        [isnan(v) ? -1 : round(Int, v) for v in status],
        _values_on_grid(device, telemetry.ramp_up_limit, stamps),
    )
end


# The regulation AGC ramping capability of `device` on `service` over the window (AEMO *FCAS Model in NEMDE* §4.2),
# per-unit, `NaN` at an interval with no ramp rate; `nothing` when the device has no `"fcas_agc_ramp_rate_<service>"`
# series. The series is per-unit MW/h, times the interval length in hours.
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
    return _values_on_grid(device, bid.max_avail, window.stamps; field = :max_avail) ./ window.base
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
        # The stored ratings are per-unit of the device base, so this does not depend on the display units.
        scale = PSY.get_base_power(device) / window.base
        output = getproperty(device, :output_active_power_limits).max * scale
        input = getproperty(device, :input_active_power_limits).max * scale
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
    points = _values_on_grid(device, bid.trapezium, window.stamps; field = :trapezium)
    max_avail = _values_on_grid(device, bid.max_avail, window.stamps; field = :max_avail)
    is_regulation = bid_type in FCAS_REGULATION_MARKETS
    telemetry = get_telemetry(device)
    enablement = if is_regulation
        pairs = _values_on_grid(
            device, bid_type == BidType.RAISEREG ? telemetry.raise_reg_enablement : telemetry.lower_reg_enablement, window.stamps;
            absent = (NaN, NaN),
        )
        ([p[1] / window.base for p in pairs], [p[2] / window.base for p in pairs])
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


# AEMO *FCAS Model in NEMDE* §5 pre-conditions of one side at interval `t`, ANDed with the stranded rule for the state.
function _fcas_side_enabled_at(
        window::_FCASWindow, device, bid_type::BidType, decremental::Bool, side::_FCASSide, energy, t::Int,
    )::Bool
    storage = device isa PSY.Storage
    regulation = bid_type in FCAS_REGULATION_MARKETS
    fcas_preconditions_ok(
        side.trapeziums[t], side.total_width[t], energy.gen[t], energy.load[t], window.agc_status[t],
        regulation, decremental, storage,
    ) || return false
    return fcas_state_stranded_ok(side.trapeziums[t], window.states[t], storage)
end


# The §5 enablement of a storage device's regulation bid on both sides at interval `t`, from the stranded rule for both.
function _fcas_both_sides_enabled_at(window::_FCASWindow, device, gen::_FCASSide, load::_FCASSide, energy, t::Int)
    storage = device isa PSY.Storage
    gen_ok = fcas_preconditions_ok(
        gen.trapeziums[t], gen.total_width[t], energy.gen[t], energy.load[t], window.agc_status[t], true, false, storage,
    )
    load_ok = fcas_preconditions_ok(
        load.trapeziums[t], load.total_width[t], energy.gen[t], energy.load[t], window.agc_status[t], true, true, storage,
    )
    return fcas_both_sides_stranded_ok(gen.trapeziums[t], load.trapeziums[t], gen_ok, load_ok, window.states[t])
end


"""
    _FCASPrepared

The state-independent inputs of one device's offer in one FCAS market over a window, per-unit; the state at each
interval is read from `window.states`, so a closed-loop run sets it and evaluates one interval.

# Fields
- `window`: the [`_FCASWindow`](@ref).
- `energy`: the energy limits, `(; gen, load)`.
- `direction`: the [`FCASBidDirection`](@ref) of the offer.
- `sides`: the scaled trapeziums and band widths of the generation and load side, `nothing` for a side not offered.
- `inactive`: the limit of an inactive offer, per-unit.
- `capability`, `bdu`: the regulation AGC capabilities of the joint and BDU ramping rows, zeros for a contingency market.
"""
struct _FCASPrepared
    window::_FCASWindow
    energy::@NamedTuple{gen::Vector{Float64}, load::Vector{Float64}}
    direction::FCASBidDirection
    sides::Tuple{Union{Nothing, _FCASSide}, Union{Nothing, _FCASSide}}
    inactive::Float64
    capability::Vector{Float64}
    bdu::Vector{Float64}
end


function _fcas_prepare(window::_FCASWindow, device, bid_type::BidType, direction::FCASBidDirection, inactive::Float64, energy)
    n = length(window.stamps)
    offered = fcas_offer_sides(direction)
    gen = false in offered ? _fcas_side(window, device, bid_type, false) : nothing
    load = true in offered ? _fcas_side(window, device, bid_type, true) : nothing
    regulation = bid_type in FCAS_REGULATION_MARKETS
    capability = regulation ? _fcas_capability_values(_fcas_agc_capability(window, device, _fcas_ramp_rate_service(device, bid_type)), n) : zeros(n)
    bdu = regulation && direction == FCASBidDirection.BOTH ? _fcas_capability_values(_fcas_agc_capability(window, device, bid_type), n) : zeros(n)
    limits = (gen = Vector{Float64}(energy.gen), load = Vector{Float64}(energy.load))
    return _FCASPrepared(window, limits, direction, (gen, load), inactive, capability, bdu)
end


# The effective offers of a prepared offer at interval `t` as `(gen, load)`, `nothing` for a side not offered, and its
# regulation ramping limits `(joint, bdu)` (AEMO *FCAS Model in NEMDE* §6.1, §6.4), `nothing` for a contingency market.
function _fcas_values_at(prep::_FCASPrepared, device, bid_type::BidType, t::Int)
    (; window, energy, direction, sides, inactive) = prep
    gen, load = sides
    regulation = bid_type in FCAS_REGULATION_MARKETS
    storage = device isa PSY.Storage
    both = direction == FCASBidDirection.BOTH
    # A regulation unit offering both sides is enabled as a whole by the combined stranded rule; a storage device's
    # per-side masks are that rule's own result.
    joint = if regulation && both
        _fcas_both_sides_enabled_at(window, device, gen, load, energy, t)
    else
        nothing
    end
    gen_enabled = if isnothing(gen)
        false
    elseif storage && !isnothing(joint)
        joint[1]
    else
        _fcas_side_enabled_at(window, device, bid_type, false, gen, energy, t)
    end
    load_enabled = if isnothing(load)
        false
    elseif storage && !isnothing(joint)
        joint[2]
    else
        _fcas_side_enabled_at(window, device, bid_type, true, load, energy, t)
    end
    offers = (
        isnothing(gen) ? nothing : fcas_effective_offer(gen.trapeziums[t], gen.widths[t], gen_enabled, inactive),
        isnothing(load) ? nothing : fcas_effective_offer(load.trapeziums[t], load.widths[t], load_enabled, inactive),
    )
    regulation || return offers, nothing
    enabled = if !isnothing(joint)
        joint[1] | joint[2]
    else
        direction == FCASBidDirection.DECREMENTAL ? load_enabled : gen_enabled
    end
    upper = bid_type == fcas_upper_regulation_service(device)
    return offers, fcas_ramping_limits(prep.capability[t], prep.bdu[t], enabled, upper, window.fast_start[t], inactive, window.states[t])
end


# The effective offers of a prepared offer per interval as `(gen, load)` vectors (`nothing` for a side not offered), and
# the regulation ramping limits (`nothing` for a contingency market).
function _fcas_effective_values(prep::_FCASPrepared, device, bid_type::BidType)
    values = [_fcas_values_at(prep, device, bid_type, t) for t in eachindex(prep.window.stamps)]
    gen = isnothing(prep.sides[1]) ? nothing : [first(v)[1] for v in values]
    load = isnothing(prep.sides[2]) ? nothing : [first(v)[2] for v in values]
    ramping = bid_type in FCAS_REGULATION_MARKETS ? [last(v) for v in values] : nothing
    return (gen, load), ramping
end


"""
    _attach_fcas_effective_series!(sys, device, bid_type, window, energy)

Adds `device`'s effective offer series for `bid_type` ([`fcas_effective_series_name`](@ref)) and, for a regulation
market, its ramping limits ([`fcas_ramping_series_name`](@ref)), on the timestamps of `window`. Values are per-unit of
the system base power. No-op for a device without a `bid_type` FCAS bid.

# Arguments
- `sys`: the `System` to add to.
- `device`: the bidding device.
- `bid_type`: the FCAS market.
- `window`: the [`_FCASWindow`](@ref) of the device over its bid series, shared by its markets.
- `energy`: the energy limits of the device over `window`, from `_fcas_energy_limits`.

# Returns
`nothing`.
"""
function _attach_fcas_effective_series!(sys::PSY.System, device::PSY.Device, bid_type::BidType, window::_FCASWindow, energy)
    direction = fcas_bid_direction(device, bid_type)
    direction == FCASBidDirection.NONE && return
    prep = _fcas_prepare(window, device, bid_type, direction, FCAS_INACTIVE_LIMIT_MW / window.base, energy)
    (gen, load), ramping = _fcas_effective_values(prep, device, bid_type)
    start = first(window.stamps)
    for (decremental, values) in ((false, gen), (true, load))
        isnothing(values) && continue
        PSY.add_time_series!(sys, device, single_series(fcas_effective_series_name(bid_type, decremental), start, values, window.resolution))
    end
    isnothing(ramping) && return
    PSY.add_time_series!(sys, device, single_series(fcas_ramping_series_name(bid_type), start, ramping, window.resolution))
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
    markets = Dict{Base.UUID, Vector{BidType}}()
    devices = PSY.Device[]
    for svc in PSY.get_components(FCASService, sys)
        bid_type = get_bid_type(svc)
        for device in get(index, IS.get_uuid(svc), PSY.Device[])
            bid_types = get!(markets, IS.get_uuid(device)) do
                push!(devices, device)
                return BidType[]
            end
            bid_type in bid_types || push!(bid_types, bid_type)
        end
    end
    for device in devices
        PSY.get_available(device) || continue
        window = nothing
        energy = nothing
        for bid_type in markets[IS.get_uuid(device)]
            fcas_bid_direction(device, bid_type) == FCASBidDirection.NONE && continue
            # The window and energy limits are read once per device.
            if isnothing(window)
                window = _fcas_window(device, stamps, step(grid), base)
                energy = _fcas_energy_limits(window, device)
            end
            _attach_fcas_effective_series!(sys, device, bid_type, window, energy)
        end
    end
    return
end
