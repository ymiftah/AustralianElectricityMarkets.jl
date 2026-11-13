"""
    set_effective_offers!(sys)

Attaches the series the NEM dispatch formulation reads as effective offers, per device of `sys`, from
the bids and unit conditions that [`nem_system`](@ref) attaches, with no database access:

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

The ramp rates, AGC ramp rates and energy offer curves are not written here: [`nem_system`](@ref) adds them
with the other replay input series, and this function reads them. Existing series of the names written here
are replaced, so a second call on the same `sys` gives the same result. [`prepare_replay!`](@ref) calls it before attaching
the forecasts. Call it before `transform_single_time_series!`: the series are single time series until then.

Throws `ArgumentError` when a bid this function reads is static rather than series-backed.

# Arguments
- `sys`: the `System` to add to.

# Returns
`nothing`.
"""
function set_effective_offers!(sys::PSY.System)
    _set_state_seeds!(sys)
    _set_fcas_effective_offers!(sys)
    _set_tie_break_scales!(sys)
    set_loss_demand_coefficients!(sys)
    _attach_dispatch_inputs!(sys)
    return
end


# The raw `FIXEDLOAD` of `device`'s `side` energy bid at `stamp`, MW; `NaN` when the bid has none.
function _fixed_load_mw(device, side::OfferSide, stamp::DateTime)
    cost = _nem_offer_cost(device)
    bid = isnothing(cost) ? nothing : _energy_bid(cost, side)
    isnothing(bid) && return NaN
    value = _state_value(device, bid, Val(:fixed_load), stamp)
    return isnothing(value) ? NaN : Float64(value)
end


# The fixed-loading target on the net-injection axis at `stamp`, MW, and whether either side applies.
function _fixed_load_step(device, stamp::DateTime; source::StateSource = _state_source())
    state = unit_state(source, device, stamp)
    gen = _fixed_load_mw(device, OfferSide.GEN, stamp)
    load = _fixed_load_mw(device, OfferSide.LOAD, stamp)
    target = if device isa PSY.Storage
        effective_fixed_load(gen, state) - effective_fixed_load(load, state)
    else
        effective_fixed_load(gen, state) + effective_fixed_load(load, state)
    end
    return (; target, invoked = fixed_load_invoked(gen, state) || fixed_load_invoked(load, state))
end


# The raw `FIXEDLOAD` of `device`'s `side` energy bid at each of `stamps`, MW; `NaN` where the bid has none.
function _fixed_load_mw_series(device, side::OfferSide, stamps::AbstractVector{DateTime})
    cost = _nem_offer_cost(device)
    bid = isnothing(cost) ? nothing : _energy_bid(cost, side)
    isnothing(bid) && return fill(NaN, length(stamps))
    value = bid.fixed_load
    value isa IS.StaticTimeSeriesKey || return fill(isnothing(value) ? NaN : Float64(value), length(stamps))
    return Float64.(IS.get_time_series_values(device, value; start_time = first(stamps), len = length(stamps)))
end


"""
    _fixed_load_step_series(device, stamps::AbstractVector{DateTime}; source::StateSource = _state_source())

The fixed-loading targets and invoked flags of [`_fixed_load_step`](@ref) at each of `stamps`. The bid
fixed loadings are read once per side over the stamps; the state is read stamp by stamp.

# Arguments
- `device`: the NEM device.
- `stamps`: the first timestamps of the intervals, consecutive at the series' resolution.
- `source`: the [`StateSource`](@ref).

# Returns
A `Vector` the length of `stamps` of `(; target, invoked)` named tuples.
"""
function _fixed_load_step_series(device, stamps::AbstractVector{DateTime}; source::StateSource = _state_source())
    gens = _fixed_load_mw_series(device, OfferSide.GEN, stamps)
    loads = _fixed_load_mw_series(device, OfferSide.LOAD, stamps)
    storage = device isa PSY.Storage
    return map(eachindex(stamps)) do i
        state = unit_state(source, device, stamps[i])
        gen, load = gens[i], loads[i]
        target = if storage
            effective_fixed_load(gen, state) - effective_fixed_load(load, state)
        else
            effective_fixed_load(gen, state) + effective_fixed_load(load, state)
        end
        return (; target, invoked = fixed_load_invoked(gen, state) || fixed_load_invoked(load, state))
    end
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
