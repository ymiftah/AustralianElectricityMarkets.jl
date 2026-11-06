"""
    _require_fcas_float(row, field::Symbol)

`Float64(getproperty(row, field))`, or an actionable `ArgumentError` naming `field` and the
row's `DUID` if the value is `missing`.
"""
function _require_fcas_float(row, field::Symbol)
    return _require_fcas_float(row, Val(field))
end


function _require_fcas_float(row, ::Val{field}) where {field}
    value = getproperty(row, field)
    ismissing(value) && throw(
        ArgumentError(
            "BIDPEROFFER_D.$field is missing for DUID $(row.DUID) - cannot build an " *
                "FCASTrapezium without it.",
        ),
    )
    return Float64(value)
end


IS.@scoped_enum(FCASBidDirection, NONE = 0, INCREMENTAL = 1, DECREMENTAL = 2, BOTH = 3)


@doc """
    FCASBidDirection

Which sides of an FCAS bid a device carries: `NONE`, `INCREMENTAL` (generation side),
`DECREMENTAL` (load side) or `BOTH`. Returned by [`fcas_bid_direction`](@ref).
""" FCASBidDirection


"""
    fcas_bid_direction(device, bid_type) -> FCASBidDirection

Which sides of a `bid_type` FCAS bid `device` carries, read from its `"fcas_trapezium_<bid_type>"`
and `"fcas_trapezium_<bid_type>_decremental"` series ([`fcas_series_name`](@ref)).

# Arguments
- `device`: any component.
- `bid_type`: the FCAS [`BidType`](@ref).

# Returns
An [`FCASBidDirection`](@ref).
"""
function fcas_bid_direction(device, bid_type::BidType)
    has_inc, has_dec = (has_time_series(device, SingleTimeSeries, fcas_series_name("fcas_trapezium", bid_type, dec)) for dec in (false, true))
    has_inc && has_dec && return FCASBidDirection.BOTH
    has_inc && return FCASBidDirection.INCREMENTAL
    has_dec && return FCASBidDirection.DECREMENTAL
    return FCASBidDirection.NONE
end


"""
    _fcas_bid_side(device, bid::NEMFCASBid) -> Union{Nothing, OfferSide}

The side of `device`'s FCAS `bid` that the formulation models: a `LOAD` bid is the load side of a
storage device or a controllable load, and a `GEN` or `BIDIRECTIONAL` bid is the generation side of a
generator or a storage device. `nothing` for a bid the formulation does not model (a generator's
`LOAD` bid, a controllable load's `GEN` or `BIDIRECTIONAL` bid).
"""
function _fcas_bid_side(device, bid::NEMFCASBid)
    if bid.direction == BidDirection.LOAD
        return device isa PSY.ControllableLoad || device isa PSY.Storage ? OfferSide.LOAD : nothing
    end
    return device isa PSY.ControllableLoad ? nothing : OfferSide.GEN
end


"""
    _fcas_bids_direction(device, bid_type) -> FCASBidDirection

Which sides of `device`'s `bid_type` FCAS bids the formulation models ([`_fcas_bid_side`](@ref)),
read from the [`NEMFCASBid`](@ref)s of its [`NEMOfferCost`](@ref).
"""
function _fcas_bids_direction(device, bid_type::BidType)
    cost = _nem_offer_cost(device)
    isnothing(cost) && return FCASBidDirection.NONE
    sides = Set{OfferSide}()
    for bid in get_fcas_bids(cost)
        bid.service == bid_type || continue
        side = _fcas_bid_side(device, bid)
        isnothing(side) || push!(sides, side)
    end
    has_inc, has_dec = OfferSide.GEN in sides, OfferSide.LOAD in sides
    has_inc && has_dec && return FCASBidDirection.BOTH
    has_inc && return FCASBidDirection.INCREMENTAL
    has_dec && return FCASBidDirection.DECREMENTAL
    return FCASBidDirection.NONE
end


"""
    _fcas_bid_modeled(device, bid_type) -> Bool

Whether `device`'s `bid_type` FCAS bid has a direction the FCAS market formulation models: an
incremental bid on any device but a load, a decremental-only bid on a `Storage` device or an
`ControllableLoad`, or a `Storage` device's regulation bid on both sides.
"""
function _fcas_bid_modeled(device, bid_type::BidType)
    direction = _fcas_bids_direction(device, bid_type)
    direction == FCASBidDirection.INCREMENTAL && return !(device isa ControllableLoad)
    direction == FCASBidDirection.DECREMENTAL && return device isa Storage || device isa ControllableLoad
    direction == FCASBidDirection.BOTH && return device isa Storage && bid_type in FCAS_REGULATION_MARKETS
    return false
end


# A device bids a (region, bid_type) market if it carries an FCAS bid on a side the formulation
# models; a storage device can provide the market while charging or discharging.
function _fcas_service_devices(
        sys, region::AbstractString, bid_type::BidType;
        candidates = _region_devices(sys, region; loads = true),
    )
    return filter(d -> _fcas_bids_direction(d, bid_type) != FCASBidDirection.NONE, candidates)
end


"""
    add_fcas_services!(sys; bid_types = FCAS_BID_TYPES) -> (added, excluded)

Adds one [`FCASService`](@ref) named `"<REGIONID>_<BIDTYPE>"` for every region and FCAS market in
`bid_types` with at least one available device bidding it, attached via `add_service!` to those devices
whose bid direction the FCAS market formulation models (an incremental bid, a decremental-only
bid on a `Storage` device or a load, or a `Storage` device's regulation bid on both sides). The bids
are the [`NEMFCASBid`](@ref)s stored by [`set_market_bids!`](@ref). A service already in `sys` under
that name is left as is. Devices bidding a market in a direction the formulation does not model are
left out and reported.

# Arguments
- `sys`: the `System` to add to, holding the FCAS bids of its devices.
- `bid_types`: the FCAS markets to add services for.

# Returns
`(added, excluded)`: `added::Vector{String}` of service names created, and
`excluded::Dict{String, Vector{String}}` mapping a service name to the device names left out of
it.
"""
function add_fcas_services!(sys; bid_types = FCAS_BID_TYPES)
    added = String[]
    excluded = Dict{String, Vector{String}}()
    for region in sort(get_name.(get_components(Area, sys)))
        # The region's devices are the same for every bid type; only the bids filter differs.
        candidates = _region_devices(sys, region; loads = true)
        for bid_type in bid_types
            _add_fcas_service!(sys, region, bid_type, candidates, added, excluded)
        end
    end
    if !isempty(excluded)
        @warn "add_fcas_services!: left $(sum(length, values(excluded))) device(s) out of $(length(excluded)) FCAS market(s) - their bid direction is not modeled" excluded
    end
    return added, excluded
end

function _add_fcas_service!(sys, region, bid_type, candidates, added, excluded)
    name = fcas_service_name(region, bid_type)
    isnothing(get_component(FCASService, sys, name)) || return
    bidders = filter(get_available, _fcas_service_devices(sys, region, bid_type; candidates = candidates))
    devices = filter(d -> _fcas_bid_modeled(d, bid_type), bidders)
    left_out = setdiff(get_name.(bidders), get_name.(devices))
    isempty(left_out) || (excluded[name] = sort(left_out))
    isempty(devices) && return
    add_service!(sys, FCASService(; name = name, region = region, bid_type = bid_type), devices)
    push!(added, name)
    return
end


"""
    _fcas_scaling_devices(sys, component_types)

Collects the available devices of each requested component type for FCAS scaling inputs.

# Arguments
- `sys`: the `System` to search.
- `component_types`: a tuple of non-overlapping `Device` types.

# Returns
A `Vector{Device}`.
"""
function _fcas_scaling_devices(sys, component_types)
    devices = Device[]
    for component_type in component_types
        append!(devices, get_components(get_available, component_type, sys))
    end
    return devices
end


"""
    _agc_ramp_rate(ramp_rate, availability, interval_hours) -> Union{Missing, Float64}

The AGC ramp rate (MW/h) for one regulation side of one unit-interval: the larger of the
`DISPATCHLOAD` ramp rate and the regulation `availability` (MW) spread over `interval_hours`. A
`missing` ramp rate stays `missing`; a `missing` availability leaves the ramp rate as it is.

# Arguments
- `ramp_rate`: `RAMPUPRATE` or `RAMPDOWNRATE`, in MW/h.
- `availability`: `RAISEREGAVAILABILITY` or `LOWERREGAVAILABILITY`, in MW.
- `interval_hours`: the length of one dispatch interval in hours.

# Returns
`Union{Missing, Float64}`.
"""
function _agc_ramp_rate(ramp_rate, availability, interval_hours::Real)
    # MMSDM omits the telemetered AGC ramp rate, and RAMPUPRATE is capped by the bid rate. Availability
    # over the interval is the exact regulation cap, so this lower bound can leave joint ramping tighter than NEMDE's.
    ismissing(ramp_rate) && return missing
    ismissing(availability) && return ramp_rate
    return max(ramp_rate, availability / interval_hours)
end


"""
    _attach_fcas_scaling_series!(sys, device, by_time, full_grid, col, name, base_power; scale = 1.0)

Attaches a `SingleTimeSeries` named `name` to `device`, per-unitised by `base_power` and
`scale`, from `by_time[t][col]` at every `t` in `full_grid`. An interval with no row in
`by_time`, or a `missing` value for `col`, is stored as `NaN`, which
`get_scaled_fcas_trapezium` reads as an absent input for that interval. No-op if every
interval is absent.

# Returns
`nothing`.
"""
function _attach_fcas_scaling_series!(
        sys, device, by_time, full_grid::Vector, col::Symbol, name::AbstractString,
        base_power::Float64; scale::Float64 = 1.0,
    )
    values = Float64[]
    for t in full_grid
        row = get(by_time, t, nothing)
        absent = isnothing(row) || ismissing(row[col])
        push!(values, absent ? NaN : row[col] * scale / base_power)
    end
    all(isnan, values) && return nothing
    replace_single_series!(sys, device, single_series(name, full_grid, values))
    return nothing
end


"""
    set_fcas_scaling_inputs!(sys, db, date_range; kwargs...)

Attaches per-device, per-interval [`FCASTrapezium`](@ref) scaling inputs (AEMO *FCAS Model in
NEMDE* §4) and the §5 AGC-status pre-condition input to every available `Generator`,
`Storage` and `ControllableLoad` in `sys`, read from [`read_fcas_scaling_inputs`](@ref)/[`read_uigf`](@ref):

- `"fcas_agc_enablement_min_RAISEREG"`/`"fcas_agc_enablement_max_RAISEREG"` from
  `RAISEREGENABLEMENTMIN`/`RAISEREGENABLEMENTMAX` (§4.1);
- `"fcas_agc_enablement_min_LOWERREG"`/`"fcas_agc_enablement_max_LOWERREG"` from
  `LOWERREGENABLEMENTMIN`/`LOWERREGENABLEMENTMAX` (§4.1);
- `"fcas_agc_ramp_rate_RAISEREG"`/`"fcas_agc_ramp_rate_LOWERREG"` from the larger of the ramp
  rate and the regulation availability spread over the interval, in MW/h (§4.2's AGC ramping
  capability is this rate times the model's interval length, applied on read; see
  `_agc_ramp_rate`). Pairing is per device, as described below;
- `"fcas_agc_status"` from `AGCSTATUS` (§5: `1` while the unit is under AGC control, `0`
  otherwise), not per-unitized;
- `"uigf"` from `UIGF`, for semi-scheduled units only (§4.3), shared with [`set_nem_energy_limits!`](@ref).

Generators and storage pair each ramp rate with its own service's availability: `RAMPUPRATE` with
`RAISEREGAVAILABILITY`, and `RAMPDOWNRATE` with `LOWERREGAVAILABILITY`. An
`ControllableLoad` pairs them with the service that reads each series: its
`"fcas_agc_ramp_rate_RAISEREG"` (read for lower regulation) takes `RAMPUPRATE` with
`LOWERREGAVAILABILITY`, and its `"fcas_agc_ramp_rate_LOWERREG"` (read for raise regulation) takes
`RAMPDOWNRATE` with `RAISEREGAVAILABILITY`.

Every series but `"fcas_agc_status"` is per-unit of `sys`'s system base, read back by
`get_scaled_fcas_trapezium`; `"fcas_agc_status"` carries AGCSTATUS's raw `0`/`1` value,
read back by `get_fcas_agc_status`. An interval with no source row or a `missing` source
value is stored as `NaN`: it applies no scaling at that interval, per §4's "zero or absent" rule,
and reads back as an unknown AGC status.

# Arguments
- `sys`: the `System` to add to.
- `db`: an `AEMDB` connection.
- `date_range`: the dispatch intervals to replay.
- `kwargs`: passed to [`read_fcas_scaling_inputs`](@ref)/[`read_uigf`](@ref) (e.g.
  `intervention`).

# Returns
`nothing`.
"""
function set_fcas_scaling_inputs!(sys, db, date_range; kwargs...)
    base_power = get_base_power(sys)
    full_grid = collect(date_range)[1:(end - 1)]

    scaling_rows = read_fcas_scaling_inputs(db, date_range; kwargs...)
    interval_hours = Dates.value(Millisecond(step(date_range))) / (1000 * 60 * 60)
    scaling_rows[!, :AGC_RAMP_RAISEREG] = _agc_ramp_rate.(
        scaling_rows.RAMPUPRATE, scaling_rows.RAISEREGAVAILABILITY, interval_hours,
    )
    scaling_rows[!, :AGC_RAMP_LOWERREG] = _agc_ramp_rate.(
        scaling_rows.RAMPDOWNRATE, scaling_rows.LOWERREGAVAILABILITY, interval_hours,
    )
    scaling_rows[!, :AGC_RAMP_LOAD_RAISEREG] = _agc_ramp_rate.(
        scaling_rows.RAMPUPRATE, scaling_rows.LOWERREGAVAILABILITY, interval_hours,
    )
    scaling_rows[!, :AGC_RAMP_LOAD_LOWERREG] = _agc_ramp_rate.(
        scaling_rows.RAMPDOWNRATE, scaling_rows.RAISEREGAVAILABILITY, interval_hours,
    )
    by_duid = DataFrames.isempty(scaling_rows) ? nothing : groupby(scaling_rows, :DUID)
    uigf_rows = read_uigf(db, date_range; kwargs...)
    uigf_by_duid = DataFrames.isempty(uigf_rows) ? nothing : groupby(uigf_rows, :DUID)

    component_types = (Generator, Storage, ControllableLoad)
    for device in _fcas_scaling_devices(sys, component_types)
        duid = get_name(device)
        ramp_raise, ramp_lower = device isa ControllableLoad ?
            (:AGC_RAMP_LOAD_RAISEREG, :AGC_RAMP_LOAD_LOWERREG) : (:AGC_RAMP_RAISEREG, :AGC_RAMP_LOWERREG)

        if !isnothing(by_duid) && haskey(by_duid, (duid,))
            by_time = Dict(zip(by_duid[(duid,)].SETTLEMENTDATE, eachrow(by_duid[(duid,)])))
            _attach_fcas_scaling_series!(
                sys, device, by_time, full_grid, :RAISEREGENABLEMENTMIN,
                fcas_series_name("fcas_agc_enablement_min", BidType.RAISEREG), base_power,
            )
            _attach_fcas_scaling_series!(
                sys, device, by_time, full_grid, :RAISEREGENABLEMENTMAX,
                fcas_series_name("fcas_agc_enablement_max", BidType.RAISEREG), base_power,
            )
            _attach_fcas_scaling_series!(
                sys, device, by_time, full_grid, :LOWERREGENABLEMENTMIN,
                fcas_series_name("fcas_agc_enablement_min", BidType.LOWERREG), base_power,
            )
            _attach_fcas_scaling_series!(
                sys, device, by_time, full_grid, :LOWERREGENABLEMENTMAX,
                fcas_series_name("fcas_agc_enablement_max", BidType.LOWERREG), base_power,
            )
            _attach_fcas_scaling_series!(
                sys, device, by_time, full_grid, ramp_raise, fcas_series_name("fcas_agc_ramp_rate", BidType.RAISEREG), base_power,
            )
            _attach_fcas_scaling_series!(
                sys, device, by_time, full_grid, ramp_lower, fcas_series_name("fcas_agc_ramp_rate", BidType.LOWERREG), base_power,
            )
            _attach_fcas_scaling_series!(
                sys, device, by_time, full_grid, :AGCSTATUS, NEM_SERIES.fcas_agc_status, 1.0,
            )
        end

        if !isnothing(uigf_by_duid) && haskey(uigf_by_duid, (duid,))
            by_time = Dict(zip(uigf_by_duid[(duid,)].SETTLEMENTDATE, eachrow(uigf_by_duid[(duid,)])))
            _attach_fcas_scaling_series!(sys, device, by_time, full_grid, :UIGF, NEM_SERIES.uigf, base_power)
        end
    end
    return
end
