"""
    _fcas_bid_direction(device, bid_type) -> Symbol

`:incremental`, `:decremental`, `:both` or `:none`, describing which `"fcas_trapezium_<bid_type>
[_decremental]"` series `device` carries.
"""
function _fcas_bid_direction(device, bid_type::BidType)
    bid_type_str = string(bid_type)
    has_inc = has_time_series(device, Deterministic, "fcas_trapezium_$bid_type_str")
    has_dec = has_time_series(device, Deterministic, "fcas_trapezium_$(bid_type_str)_decremental")
    has_inc && has_dec && return :both
    has_inc && return :incremental
    has_dec && return :decremental
    return :none
end


"""
    _fcas_bid_modeled(device, bid_type) -> Bool

Whether `device`'s `bid_type` FCAS bid has a direction the FCAS market formulation models: an
incremental bid on any device but a load, a decremental-only bid on a `Storage` device or an
`InterruptiblePowerLoad`, or a `Storage` device's regulation bid on both sides.
"""
function _fcas_bid_modeled(device, bid_type::BidType)
    direction = _fcas_bid_direction(device, bid_type)
    direction == :incremental && return !(device isa InterruptiblePowerLoad)
    direction == :decremental && return device isa Storage || device isa InterruptiblePowerLoad
    direction == :both && return device isa Storage && bid_type in FCAS_REGULATION_MARKETS
    return false
end


# A device bids a (region, bid_type) market if it carries either direction's curve series - a
# storage device can provide the market while charging or discharging.
function _fcas_service_devices(devices, bid_type::BidType)
    inc_name = _fcas_series_name("fcas_curve", bid_type, false)
    dec_name = _fcas_series_name("fcas_curve", bid_type, true)
    return filter(devices) do d
        has_time_series(d, Deterministic, inc_name) || has_time_series(d, Deterministic, dec_name)
    end
end


"""
    add_fcas_services!(sys) -> (added, excluded)

Adds one [`FCASService`](@ref) named `"<REGIONID>_<BIDTYPE>"` for every region and FCAS market
with at least one available device bidding it, attached via `add_service!` to those devices
whose bid direction the FCAS market formulation models (an incremental bid, a decremental-only
bid on a `Storage` device or a load, or a `Storage` device's regulation bid on both sides). A
service already in `sys` under that name is left as is. Devices bidding a market in a direction the formulation does not model are left out and
reported.

# Arguments
- `sys`: the `System` to add to, after [`set_fcas_bids!`](@ref) has run.

# Returns
`(added, excluded)`: `added::Vector{String}` of service names created, and
`excluded::Dict{String, Vector{String}}` mapping a service name to the device names left out of
it.
"""
function add_fcas_services!(sys)
    added = String[]
    excluded = Dict{String, Vector{String}}()
    for region in sort(get_name.(get_components(Area, sys)))
        region_devices = filter(get_available, _region_devices(sys, region; loads = true))
        for bid_type in FCAS_BID_TYPES
            name = fcas_service_name(region, bid_type)
            isnothing(get_component(FCASService, sys, name)) || continue
            bidders = _fcas_service_devices(region_devices, bid_type)
            devices = filter(d -> _fcas_bid_modeled(d, bid_type), bidders)
            left_out = setdiff(get_name.(bidders), get_name.(devices))
            isempty(left_out) || (excluded[name] = sort(left_out))
            isempty(devices) && continue
            add_service!(sys, FCASService(; name = name, region = region, bid_type = bid_type), devices)
            push!(added, name)
        end
    end
    if !isempty(excluded)
        @warn "add_fcas_services!: left $(sum(length, values(excluded))) device(s) out of $(length(excluded)) FCAS market(s) - their bid direction is not modeled" excluded
    end
    return added, excluded
end


"""
    _attach_fcas_bid_series!(sys, component, gdf, duid, series_suffix, start_date, resolution)

Attaches the two per-`(component, FCAS market)` `Deterministic` series - `"fcas_curve_\$
series_suffix"` and `"fcas_trapezium_\$series_suffix"` - from `gdf` (a `DUID`-grouped bids
`DataFrame`) if `duid` has a group in it. No-op otherwise, so callers can probe a component
against several `DIRECTION` groupings without checking `haskey` themselves. Returns whether
the series were attached.
"""
function _attach_fcas_bid_series!(sys, component, gdf, duid::AbstractString, series_suffix::AbstractString, start_date, resolution)
    (isnothing(gdf) || !haskey(gdf, (duid,))) && return false
    rows = gdf[(duid,)]
    # rows.curve_data/.trapezium_row are SubArray views into the grouped DataFrame -
    # Deterministic's convert_data only accepts a plain Vector.
    curve_ts = Deterministic(;
        name = "fcas_curve_$(series_suffix)",
        data = Dict(start_date => collect(rows.curve_data)),
        resolution = resolution,
        interval = resolution,
    )
    add_time_series!(sys, component, curve_ts)
    trapezium_ts = Deterministic(;
        name = "fcas_trapezium_$(series_suffix)",
        data = Dict(start_date => collect(rows.trapezium_row)),
        resolution = resolution,
        interval = resolution,
    )
    add_time_series!(sys, component, trapezium_ts)
    return true
end


"""
    set_fcas_bids!(sys, db, date_range; kwargs...)

Attaches FCAS bid data to the system as two `Deterministic` time series per `(component,
FCAS market)` with bid data in `date_range`:
- `"fcas_curve_<SERVICE>"` (e.g. `"fcas_curve_RAISE6SEC"`), a `Vector{PiecewiseStepData}` -
  the priced 10-band offer curve per interval;
- `"fcas_trapezium_<SERVICE>"`, a `Vector{NTuple{7,Float64}}` - the AEMO trapezium per
  interval, packed by [`_extract_fcas_bid`](@ref).

Both series' MW quantities (curve `x_coords`, all trapezium fields but not prices) are stored
per-unit of `sys`'s system base; [`get_fcas_trapezium`](@ref)/[`get_fcas_offer_curve`](@ref)
convert back on read.

`DIRECTION` routes and names the series, mirroring [`set_market_bids!`](@ref)'s energy-bid
GEN/LOAD split: `GEN` and `BIDIRECTIONAL` rows are both capability offered while the unit
dispatches normally (a `BIDIRECTIONAL` bid doesn't distinguish charge/discharge, so it's
attached under the plain `<SERVICE>` name alongside `GEN`), attached to every matching
`Generator` and `EnergyReservoirStorage`; `LOAD` rows are decremental capability, attached
to `EnergyReservoirStorage` and `InterruptiblePowerLoad` under `"<SERVICE>_decremental"`. A
non-scheduled load (no energy bid) that gets a series is made available if its unit is
commissioned; one without any FCAS bid stays unavailable. Run this before
[`set_nem_dispatch_limits!`](@ref), which attaches the ramp and limit series a newly available load
needs. Dropping `LOAD`/
`BIDIRECTIONAL` rows entirely (as an earlier version of this function did) silently loses a
large share of real FCAS providers - measured on 2 Jan 2025 `BIDPEROFFER_D`, `LOAD` and
`BIDIRECTIONAL` rows together outnumber `GEN` rows for several contingency markets.

Two series, not one carrying [`FCASBid`](@ref)/[`FCASTrapezium`](@ref) objects directly:
confirmed directly that `Deterministic` rejects those (and bare `Vector{Float64}`) as a
per-step element type - see `test/fcas/fcas.jl`'s `"FCASBid time series round-trip"` testset for
the proven shape this mirrors. Does not require or create any `Reserve`/service - FCAS
requirements are [`GenericConstraint`](@ref)s built separately by
[`add_nem_constraints!`](@ref).

Unlike the deleted `set_fcas_offers!`, this is genuinely time-varying (mirrors
[`set_market_bids!`](@ref)'s energy-bid path), not a single-interval snapshot.

# Arguments
- `sys`: The `PowerSystems.System` object.
- `db`: The database connection.
- `date_range`: A range of dates for which to fetch FCAS bid data.
"""
function set_fcas_bids!(sys, db, date_range; kwargs...)
    start_date = first(date_range)
    resolution = get(kwargs, :resolution, Minute(5))
    base_power = get_base_power(sys)
    generators = collect(get_components(Generator, sys))
    storages = collect(get_components(EnergyReservoirStorage, sys))
    loads = collect(get_components(InterruptiblePowerLoad, sys))

    for bid_type in FCAS_BID_TYPES
        bids = read_fcas_bids(db, date_range, bid_type; kwargs...)
        DataFrames.isempty(bids) && continue
        transform!(bids, AsTable(:) => ByRow(_extract_fcas_bid) => [:curve_data, :trapezium_row])
        # Per-unitize quantities (offer curve x_coords, trapezium MW/ramp-rate fields), not
        # prices (curve y_coords); component accessors convert back on read.
        transform!(
            bids,
            :curve_data => ByRow(psd -> PiecewiseStepData(get_x_coords(psd) ./ base_power, get_y_coords(psd))) => :curve_data,
            :trapezium_row => ByRow(t -> t ./ base_power) => :trapezium_row,
        )
        sort!(bids, :INTERVAL_DATETIME)
        bid_type_str = string(bid_type)

        incremental = subset(bids, :DIRECTION => ByRow(in(("GEN", "BIDIRECTIONAL"))))
        decremental = subset(bids, :DIRECTION => ByRow(==("LOAD")))
        gdf_inc = DataFrames.isempty(incremental) ? nothing : groupby(incremental, :DUID)
        gdf_dec = DataFrames.isempty(decremental) ? nothing : groupby(decremental, :DUID)

        foreach(generators) do gen
            _attach_fcas_bid_series!(sys, gen, gdf_inc, get_name(gen), bid_type_str, start_date, resolution)
        end
        foreach(storages) do stor
            duid = get_name(stor)
            _attach_fcas_bid_series!(sys, stor, gdf_inc, duid, bid_type_str, start_date, resolution)
            _attach_fcas_bid_series!(sys, stor, gdf_dec, duid, "$(bid_type_str)_decremental", start_date, resolution)
        end
        foreach(loads) do load
            attached = _attach_fcas_bid_series!(
                sys, load, gdf_dec, get_name(load), "$(bid_type_str)_decremental", start_date, resolution,
            )
            attached && _is_non_scheduled_load(load) && get(get_ext(load), "commissioned", true) === true &&
                set_available!(load, true)
        end
    end
    return
end

"""
    _fcas_scaling_devices(sys)

Every available `Generator` and `EnergyReservoirStorage` in `sys` - the device population
[`set_fcas_bids!`](@ref) attaches FCAS bid series to, and so the population
[`set_fcas_scaling_inputs!`](@ref) mirrors.

# Returns
A `Vector{Device}`.
"""
function _fcas_scaling_devices(sys)
    devices = Device[]
    append!(devices, collect(get_components(get_available, Generator, sys)))
    append!(devices, collect(get_components(get_available, EnergyReservoirStorage, sys)))
    return devices
end


"""
    _attach_fcas_scaling_series!(sys, device, by_time, full_grid, col, name, base_power; scale = 1.0)

Attaches a `SingleTimeSeries` named `name` to `device`, per-unitised by `base_power` and
`scale`, from `by_time[t][col]` at every `t` in `full_grid`. An interval with no row in
`by_time`, or a `missing` value for `col`, is stored as `NaN`, which
[`get_scaled_fcas_trapezium`](@ref) reads as an absent input for that interval. No-op if every
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
    add_time_series!(
        sys, device, SingleTimeSeries(; name = name, data = TimeArray(full_grid, values)),
    )
    return nothing
end


"""
    set_fcas_scaling_inputs!(sys, db, date_range; kwargs...)

Attaches per-device, per-interval [`FCASTrapezium`](@ref) scaling inputs (AEMO *FCAS Model in
NEMDE* §4) and the §5 AGC-status pre-condition input to every available `Generator` and
`EnergyReservoirStorage` in `sys`, read from [`read_fcas_scaling_inputs`](@ref)/[`read_uigf`](@ref):

- `"fcas_agc_enablement_min_RAISEREG"`/`"fcas_agc_enablement_max_RAISEREG"` from
  `RAISEREGENABLEMENTMIN`/`RAISEREGENABLEMENTMAX` (§4.1);
- `"fcas_agc_enablement_min_LOWERREG"`/`"fcas_agc_enablement_max_LOWERREG"` from
  `LOWERREGENABLEMENTMIN`/`LOWERREGENABLEMENTMAX` (§4.1);
- `"fcas_agc_ramp_rate_RAISEREG"`/`"fcas_agc_ramp_rate_LOWERREG"` from `RAMPUPRATE`/
  `RAMPDOWNRATE`, in MW/h (§4.2's AGC ramping capability is this rate times the model's interval
  length, applied on read);
- `"fcas_agc_status"` from `AGCSTATUS` (§5: `1` while the unit is under AGC control, `0`
  otherwise), not per-unitized;
- `"fcas_uigf"` from `UIGF`, for semi-scheduled units only (§4.3).

Every series but `"fcas_agc_status"` is per-unit of `sys`'s system base, read back by
[`get_scaled_fcas_trapezium`](@ref); `"fcas_agc_status"` carries AGCSTATUS's raw `0`/`1` value,
read back by [`get_fcas_agc_status`](@ref). An interval with no source row or a `missing` source
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
    by_duid = DataFrames.isempty(scaling_rows) ? nothing : groupby(scaling_rows, :DUID)
    uigf_rows = read_uigf(db, date_range; kwargs...)
    uigf_by_duid = DataFrames.isempty(uigf_rows) ? nothing : groupby(uigf_rows, :DUID)

    for device in _fcas_scaling_devices(sys)
        duid = get_name(device)

        if !isnothing(by_duid) && haskey(by_duid, (duid,))
            by_time = Dict(zip(by_duid[(duid,)].SETTLEMENTDATE, eachrow(by_duid[(duid,)])))
            _attach_fcas_scaling_series!(
                sys, device, by_time, full_grid, :RAISEREGENABLEMENTMIN,
                "fcas_agc_enablement_min_RAISEREG", base_power,
            )
            _attach_fcas_scaling_series!(
                sys, device, by_time, full_grid, :RAISEREGENABLEMENTMAX,
                "fcas_agc_enablement_max_RAISEREG", base_power,
            )
            _attach_fcas_scaling_series!(
                sys, device, by_time, full_grid, :LOWERREGENABLEMENTMIN,
                "fcas_agc_enablement_min_LOWERREG", base_power,
            )
            _attach_fcas_scaling_series!(
                sys, device, by_time, full_grid, :LOWERREGENABLEMENTMAX,
                "fcas_agc_enablement_max_LOWERREG", base_power,
            )
            _attach_fcas_scaling_series!(
                sys, device, by_time, full_grid, :RAMPUPRATE, "fcas_agc_ramp_rate_RAISEREG", base_power,
            )
            _attach_fcas_scaling_series!(
                sys, device, by_time, full_grid, :RAMPDOWNRATE, "fcas_agc_ramp_rate_LOWERREG", base_power,
            )
            _attach_fcas_scaling_series!(
                sys, device, by_time, full_grid, :AGCSTATUS, "fcas_agc_status", 1.0,
            )
        end

        if !isnothing(uigf_by_duid) && haskey(uigf_by_duid, (duid,))
            by_time = Dict(zip(uigf_by_duid[(duid,)].SETTLEMENTDATE, eachrow(uigf_by_duid[(duid,)])))
            _attach_fcas_scaling_series!(sys, device, by_time, full_grid, :UIGF, "fcas_uigf", base_power)
        end
    end
    return
end
