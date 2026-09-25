"""
    _nem_dispatch_devices(sys)

Collects every available `ThermalStandard`, `HydroDispatch`, `RenewableDispatch` and
`EnergyReservoirStorage` in `sys` — the device types that [`set_nem_dispatch_limits!`](@ref)
and [`set_nem_initial_conditions!`](@ref) apply to.

# Arguments
- `sys`: the `System` to collect from.

# Returns
A `Vector{Device}`.
"""
function _nem_dispatch_devices(sys)
    devices = Device[]
    append!(devices, collect(get_components(get_available, ThermalStandard, sys)))
    append!(devices, collect(get_components(get_available, HydroDispatch, sys)))
    append!(devices, collect(get_components(get_available, RenewableDispatch, sys)))
    append!(devices, collect(get_components(get_available, EnergyReservoirStorage, sys)))
    return devices
end

"""
    _report_ramp_data_problems!(problems, allow_missing_ramp_rates, fn_name)

Applies the shared missing-`DISPATCHLOAD`-data policy for [`set_nem_dispatch_limits!`](@ref)
and [`set_nem_initial_conditions!`](@ref): with `allow_missing_ramp_rates = false`, a non-empty
`problems` is raised as one aggregated `ArgumentError` naming `fn_name`; with
`allow_missing_ramp_rates = true`, one summary `@warn` is issued instead.

# Arguments
- `problems`: a `Vector{String}`, one entry per affected `DUID`.
- `allow_missing_ramp_rates`: proceed with a `@warn` instead of throwing.
- `fn_name`: the calling function's name, for the error/warning message.

# Returns
`nothing`.
"""
function _report_ramp_data_problems!(problems, allow_missing_ramp_rates::Bool, fn_name::AbstractString)
    isempty(problems) && return
    detail = join(problems, "; ")
    if allow_missing_ramp_rates
        @warn "$fn_name: $(length(problems)) device(s) have unusable DISPATCHLOAD ramp data; proceeding without them (allow_missing_ramp_rates=true): $detail"
    else
        throw(
            ArgumentError(
                "$fn_name: $(length(problems)) device(s) have unusable DISPATCHLOAD ramp data: $detail. " *
                    "Pass allow_missing_ramp_rates=true to proceed with the buildable subset.",
            ),
        )
    end
    return
end

"""
    set_nem_dispatch_limits!(sys, db, date_range; allow_missing_ramp_rates = false, kwargs...)

Attaches per-device `SingleTimeSeries` from [`read_dispatch_limits`](@ref) to every available
`ThermalStandard`, `HydroDispatch`, `RenewableDispatch` and `EnergyReservoirStorage` in `sys`:
`"ramp_up_rate"` and `"ramp_down_rate"` (from `RAMPUPRATE`/`RAMPDOWNRATE`) and `"initial_mw"`
(from `INITIALMW`, net MW for a battery). A `ThermalStandard`, `HydroDispatch` or
`RenewableDispatch` also gets `"max_active_power"` — the device's upper dispatch limit,
`AVAILABILITY` raised to the ramp-down floor `INITIALMW - RAMPDOWNRATE × Δ` when that floor is
higher, where Δ is the interval length in hours taken from `date_range`'s step — replacing any
`UIGF`- or bid-derived `"max_active_power"` series a device already carries. An
`EnergyReservoirStorage` gets no `"max_active_power"` series: its per-direction availability is
the energy bid `MAXAVAIL` series [`set_market_bids!`](@ref) attaches, read back by
[`get_storage_energy_max_avail`](@ref); the same ramp-floor rule is applied to it on the net
axis when its dispatch model is built.

`"ramp_up_rate"`, `"ramp_down_rate"` and `"initial_mw"` are stored per-unit of `sys`'s system
base, rates per minute. `"max_active_power"` follows PSY's native convention instead: data
normalised by the device's own static `max_active_power` (read under `NATURAL_UNITS`), with
`scaling_factor_multiplier = get_max_active_power`.

A device with no `DISPATCHLOAD` rows in `date_range`, missing intervals, a `missing` rate or
`INITIALMW`, or a negative `RAMPUPRATE`/`RAMPDOWNRATE` is a problem; for a `ThermalStandard`,
`HydroDispatch` or `RenewableDispatch`, a `missing` or negative `AVAILABILITY`, or a
non-positive static `max_active_power`, is also a problem. A zero `RAMPUPRATE`,
`RAMPDOWNRATE` or `AVAILABILITY` is carried through as-is: it is AEMO stating that the device
cannot move, or cannot generate, in that interval. With `allow_missing_ramp_rates = false`
(the default), every problem across every device is collected and raised as one aggregated
`ArgumentError` naming the affected `DUID`s, and `sys` is left unmodified. With
`allow_missing_ramp_rates = true`, one summary `@warn` is issued and series are attached only
to the devices with complete, valid data.

# Arguments
- `sys`: the `System` to add to.
- `db`: an `AEMDB` connection.
- `date_range`: the dispatch intervals to replay.
- `allow_missing_ramp_rates`: proceed with the buildable subset instead of throwing.
- `kwargs`: passed to [`read_dispatch_limits`](@ref) (e.g. `intervention`).

# Returns
`nothing`.
"""
function set_nem_dispatch_limits!(sys, db, date_range; allow_missing_ramp_rates::Bool = false, kwargs...)
    base_power = get_base_power(sys)
    full_grid = collect(date_range)[1:(end - 1)]
    interval_hours = Dates.value(Millisecond(step(date_range))) / (1000 * 60 * 60)

    rows = read_dispatch_limits(db, date_range; kwargs...)
    by_duid = DataFrames.isempty(rows) ? nothing : groupby(rows, :DUID)

    devices = _nem_dispatch_devices(sys)

    problems = String[]
    buildable = Dict{
        String,
        @NamedTuple{
            initial_mw::Vector{Float64}, ramp_up_rate::Vector{Float64},
            ramp_down_rate::Vector{Float64}, max_active_power::Union{Nothing, Vector{Float64}},
        }
    }()

    for device in devices
        duid = get_name(device)
        is_storage = device isa EnergyReservoirStorage
        if isnothing(by_duid) || !haskey(by_duid, (duid,))
            push!(problems, "$duid: no DISPATCHLOAD rows in $date_range")
            continue
        end
        by_time = Dict(zip(by_duid[(duid,)].SETTLEMENTDATE, eachrow(by_duid[(duid,)])))
        missing_intervals = setdiff(full_grid, keys(by_time))
        if !isempty(missing_intervals)
            push!(
                problems,
                "$duid: missing DISPATCHLOAD row(s) for $(length(missing_intervals)) of $(length(full_grid)) interval(s) (e.g. $(minimum(missing_intervals)))",
            )
            continue
        end

        static_max_active_power = if is_storage
            nothing
        else
            smap = with_units_base(() -> get_max_active_power(device), sys, "NATURAL_UNITS")
            if smap <= 0
                push!(
                    problems,
                    "$duid: static max_active_power is $smap — cannot normalise AVAILABILITY without dividing by zero",
                )
                continue
            end
            smap
        end

        initial_mw = Float64[]
        ramp_up_rate = Float64[]
        ramp_down_rate = Float64[]
        max_active_power = is_storage ? nothing : Float64[]
        reason = nothing
        for t in full_grid
            row = by_time[t]
            if ismissing(row.INITIALMW) || ismissing(row.RAMPUPRATE) || ismissing(row.RAMPDOWNRATE) ||
                    (!is_storage && ismissing(row.AVAILABILITY))
                reason = "missing INITIALMW/RAMPUPRATE/RAMPDOWNRATE" * (is_storage ? "" : "/AVAILABILITY") * " at $t"
                break
            elseif row.RAMPUPRATE < 0 || row.RAMPDOWNRATE < 0
                reason = "negative RAMPUPRATE/RAMPDOWNRATE ($(row.RAMPUPRATE)/$(row.RAMPDOWNRATE)) at $t"
                break
            elseif !is_storage && row.AVAILABILITY < 0
                reason = "negative AVAILABILITY ($(row.AVAILABILITY)) at $t"
                break
            end
            push!(initial_mw, row.INITIALMW)
            push!(ramp_up_rate, row.RAMPUPRATE)
            push!(ramp_down_rate, row.RAMPDOWNRATE)
            if !is_storage
                ramp_down_floor = row.INITIALMW - row.RAMPDOWNRATE * interval_hours
                push!(max_active_power, max(row.AVAILABILITY, ramp_down_floor) / static_max_active_power)
            end
        end
        if !isnothing(reason)
            push!(problems, "$duid: $reason")
            continue
        end
        buildable[duid] = (
            initial_mw = initial_mw, ramp_up_rate = ramp_up_rate,
            ramp_down_rate = ramp_down_rate, max_active_power = max_active_power,
        )
    end

    _report_ramp_data_problems!(problems, allow_missing_ramp_rates, "set_nem_dispatch_limits!")

    # sys is mutated only past this point - every throw above leaves it untouched, so a caller
    # retrying with allow_missing_ramp_rates=true on the same sys never double-adds anything.
    for device in devices
        duid = get_name(device)
        haskey(buildable, duid) || continue
        d = buildable[duid]
        add_time_series!(
            sys, device,
            SingleTimeSeries(; name = "ramp_up_rate", data = TimeArray(full_grid, d.ramp_up_rate ./ 60 ./ base_power)),
        )
        add_time_series!(
            sys, device,
            SingleTimeSeries(; name = "ramp_down_rate", data = TimeArray(full_grid, d.ramp_down_rate ./ 60 ./ base_power)),
        )
        add_time_series!(
            sys, device,
            SingleTimeSeries(; name = "initial_mw", data = TimeArray(full_grid, d.initial_mw ./ base_power)),
        )
        isnothing(d.max_active_power) && continue
        # RenewableDispatch/HydroDispatch may already carry a "max_active_power" series from
        # set_renewable_pv!/set_renewable_wind!/set_hydro_limits! - add_time_series! throws on a
        # duplicate name, so the existing series is removed first, deterministically overwriting
        # it regardless of call order.
        has_time_series(device, SingleTimeSeries, "max_active_power") &&
            remove_time_series!(sys, SingleTimeSeries, device, "max_active_power")
        add_time_series!(
            sys, device,
            SingleTimeSeries(;
                name = "max_active_power",
                data = TimeArray(full_grid, d.max_active_power),
                scaling_factor_multiplier = get_max_active_power,
            ),
        )
    end
    return
end

"""
    set_nem_initial_conditions!(sys, db, interval; allow_missing_ramp_rates = false, kwargs...)

Seeds `active_power` on every available `ThermalStandard`, `HydroDispatch`, `RenewableDispatch`
and `EnergyReservoirStorage` in `sys` from `DISPATCHLOAD.INITIALMW` at `interval` (net MW for a
battery), via `PSY.set_active_power!`. This is the convenience call for the chained ramp base
mode, whose `DevicePower` initial condition is read from `active_power`; the metered ramp base
mode instead reads the `"initial_mw"` time series attached by [`set_nem_dispatch_limits!`](@ref)
at every interval.

A device with no `DISPATCHLOAD` row at `interval` or a `missing` `INITIALMW` is a problem. With
`allow_missing_ramp_rates = false` (the default), every problem across every device is
collected and raised as one aggregated `ArgumentError` naming the affected `DUID`s, and `sys`
is left unmodified. With `allow_missing_ramp_rates = true`, one summary `@warn` is issued and
`active_power` is set only for the devices with a valid `INITIALMW`.

# Arguments
- `sys`: the `System` to mutate.
- `db`: an `AEMDB` connection.
- `interval`: the single dispatch interval to read `INITIALMW` from.
- `allow_missing_ramp_rates`: proceed with the buildable subset instead of throwing.
- `kwargs`: passed to [`read_dispatch_limits`](@ref) (e.g. `intervention`).

# Returns
`nothing`.
"""
function set_nem_initial_conditions!(sys, db, interval::DateTime; allow_missing_ramp_rates::Bool = false, kwargs...)
    rows = read_dispatch_limits(db, [interval, interval + Minute(1)]; kwargs...)
    by_duid = DataFrames.isempty(rows) ? nothing : groupby(rows, :DUID)

    devices = _nem_dispatch_devices(sys)

    problems = String[]
    initial_mw = Dict{String, Float64}()

    for device in devices
        duid = get_name(device)
        if isnothing(by_duid) || !haskey(by_duid, (duid,))
            push!(problems, "$duid: no DISPATCHLOAD row at $interval")
            continue
        end
        value = only(by_duid[(duid,)].INITIALMW)
        if ismissing(value)
            push!(problems, "$duid: missing INITIALMW at $interval")
            continue
        end
        initial_mw[duid] = value
    end

    _report_ramp_data_problems!(problems, allow_missing_ramp_rates, "set_nem_initial_conditions!")

    # sys is mutated only past this point - every throw above leaves it untouched, so a caller
    # retrying with allow_missing_ramp_rates=true on the same sys never double-sets anything.
    for device in devices
        duid = get_name(device)
        haskey(initial_mw, duid) || continue
        with_units_base(sys, "NATURAL_UNITS") do
            set_active_power!(device, initial_mw[duid])
            return
        end
    end
    return
end
