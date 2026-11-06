"""
    nem_dispatch_devices(sys) -> Vector{Device}

Collects every available device whose type is in [`NEM_DISPATCH_DEVICE_TYPES`](@ref) in `sys`, the
device types that the dispatch limits applies to.

# Arguments
- `sys`: the `System` to collect from.

# Returns
A `Vector{Device}`.
"""
function nem_dispatch_devices(sys)
    devices = Device[]
    for T in NEM_DISPATCH_DEVICE_TYPES
        append!(devices, collect(get_components(get_available, T, sys)))
    end
    return devices
end


"""
    set_nem_dispatch_limits!(sys, db, date_range; kwargs...)

Attaches per-device `SingleTimeSeries` from [`read_dispatch_limits`](@ref) to every available
`NEMThermalGen`, `NEMHydroGen`, `NEMRenewableGen`, `NEMLoad` and
`NEMStorage` in `sys`:
`"ramp_up_rate"` and `"ramp_down_rate"` (from `RAMPUPRATE`/`RAMPDOWNRATE`) and `"initial_mw"`
(from `INITIALMW`, net MW for a battery, consumed MW for a load). A `NEMThermalGen`,
`NEMHydroGen`, `NEMRenewableGen` or `NEMLoad` also gets `"max_active_power"`, the device's upper dispatch limit,
`AVAILABILITY` raised to the ramp-down floor `INITIALMW - RAMPDOWNRATE × Δ` when that floor is
higher, where Δ is the interval length in hours taken from `date_range`'s step, replacing any
`UIGF`- or bid-derived `"max_active_power"` series a device already carries - and
`"availability"`, the raw `AVAILABILITY` (for a semi-scheduled unit, the lower of bid `MAXAVAIL`
and `UIGF`), read back by `get_energy_availability`. An
`NEMStorage` gets no `"max_active_power"` series: its per-direction availability is
the energy bid `MAXAVAIL` series [`set_market_bids!`](@ref) attaches, read back by
`get_storage_energy_max_avail`.

`"ramp_up_rate"`, `"ramp_down_rate"`, `"initial_mw"` and `"availability"` are stored per-unit of
`sys`'s system base, rates per minute. `"max_active_power"` follows PSY's native convention instead: data
normalised by the device's own static `max_active_power` (read under `NATURAL_UNITS`), with
`scaling_factor_multiplier = get_max_active_power`.

A non-scheduled load (see [`set_market_bids!`](@ref)) gets zero `"initial_mw"`, ramp rates, `"availability"`
and `"max_active_power"` whatever `DISPATCHLOAD` meters: its consumption is already in regional demand
and is not dispatched. This function must run after [`set_market_bids!`](@ref), which makes such a load
available; a load made available later has no ramp or limit series.

A device with no `DISPATCHLOAD` rows in `date_range`, missing intervals, a `missing` rate or
`INITIALMW`, or a negative `RAMPUPRATE`/`RAMPDOWNRATE` is a problem; for a `NEMThermalGen`,
`NEMHydroGen` or `NEMRenewableGen`, a `missing` or negative `AVAILABILITY`, or a
non-positive static `max_active_power`, is also a problem. A zero `RAMPUPRATE`,
`RAMPDOWNRATE` or `AVAILABILITY` is carried through as-is: it is AEMO stating that the device
cannot move, or cannot generate, in that interval. Every problem across every device is
collected and raised as one aggregated `ArgumentError` naming the affected `DUID`s, and `sys` is
left unmodified. A second call on the same system throws an `ArgumentError` for the series already
attached.

!!! warning
    Coarse buckets aggregate the available rows without checking five-minute coverage. An
    incomplete bucket can shift `INITIALMW` away from the period start and omit more restrictive
    ramp rates or availability limits. Ensure the cache covers every five-minute interval.

# Arguments
- `sys`: the `System` to add to.
- `db`: an `AEMDB` connection.
- `date_range`: the dispatch intervals to replay. Its step is the model resolution: `DISPATCHLOAD`
  is aggregated onto it as [`read_dispatch_limits`](@ref) describes.
- `registered`: the registration span of each unit, keyed by `DUID` (see [`registration_spans`](@ref)),
  or `nothing` when every unit is registered at every interval.
- `kwargs`: passed to [`read_dispatch_limits`](@ref) (e.g. `intervention`).

# Returns
`nothing`.
"""
function set_nem_dispatch_limits!(sys, db, date_range; registered = nothing, kwargs...)
    rows = read_dispatch_limits(db, date_range; resolution = step(date_range), kwargs...)
    return _set_nem_dispatch_limits!(sys, rows, date_range; registered)
end


"""
    set_nem_dispatch_limits!(sys, rows::DataFrame, date_range; registered = nothing)

Attaches the per-device dispatch limit series built from `rows`, already read with
[`read_dispatch_limits`](@ref) at the step of `date_range`, with the same series, errors and
repeat-call behaviour as the database form.

# Arguments
- `sys`: the `System` to add to.
- `rows`: the dispatch-limit rows over `date_range`, as [`read_dispatch_limits`](@ref) returns them.
- `date_range`: the dispatch intervals to replay. Its step is the model resolution.
- `registered`: the registration span of each unit, keyed by `DUID` (see [`registration_spans`](@ref)),
  or `nothing` when every unit is registered at every interval.

# Returns
`nothing`.
"""
function set_nem_dispatch_limits!(sys, rows::DataFrame, date_range; registered = nothing)
    return _set_nem_dispatch_limits!(sys, rows, date_range; registered)
end


"""
    _set_nem_dispatch_limits!(sys, rows, date_range)

Attaches per-device `SingleTimeSeries` built from `rows` (as [`read_dispatch_limits`](@ref) returns
them, at the step of `date_range`) to every available `NEMThermalGen`, `NEMHydroGen`,
`NEMRenewableGen`, `NEMLoad` and `NEMStorage` in `sys`:
`"ramp_up_rate"` and `"ramp_down_rate"` (from `RAMPUPRATE`/`RAMPDOWNRATE`) and `"initial_mw"`
(from `INITIALMW`, net MW for a battery, consumed MW for a load). A `NEMThermalGen`,
`NEMHydroGen`, `NEMRenewableGen` or `NEMLoad` also gets `"max_active_power"`, the
device's upper dispatch limit, `AVAILABILITY` raised to the ramp-down floor `INITIALMW - RAMPDOWNRATE × Δ`
when that floor is higher, where Δ is the interval length in hours taken from `date_range`'s step,
replacing any `UIGF`- or bid-derived `"max_active_power"` series a device already carries, and
`"availability"`, the raw `AVAILABILITY` (for a semi-scheduled unit, the lower of bid `MAXAVAIL`
and `UIGF`), read back by `get_energy_availability`. A `NEMStorage` gets no
`"max_active_power"` series: its per-direction availability is the energy bid `MAXAVAIL` series
[`set_market_bids!`](@ref) attaches, read back by `get_storage_energy_max_avail`.

`"ramp_up_rate"`, `"ramp_down_rate"`, `"initial_mw"` and `"availability"` are stored per-unit of
`sys`'s system base, rates per minute. `"max_active_power"` follows PSY's native convention instead: data
normalised by the device's own static `max_active_power` (read under `NATURAL_UNITS`), with
`scaling_factor_multiplier = get_max_active_power`.

A non-scheduled load (see [`set_market_bids!`](@ref)) is exempt from the missing-row checks below and gets
zero `"initial_mw"`, ramp rates, `"availability"` and `"max_active_power"` whatever `DISPATCHLOAD` meters:
its consumption is already in regional demand and is not dispatched. This function must run after [`set_market_bids!`](@ref), which makes such a load
available; a load made available later has no ramp or limit series.

A device other than a non-scheduled load with no `DISPATCHLOAD` rows in `date_range`, a `missing` rate or
`INITIALMW`, or a negative `RAMPUPRATE`/`RAMPDOWNRATE` is a problem; for a `NEMThermalGen`,
`NEMHydroGen` or `NEMRenewableGen`, a `missing` or negative `AVAILABILITY`, or a
non-positive static `max_active_power`, is also a problem. An interval within the device's
registration (`registered`) with no row is a missing-row problem. An interval with no row outside
that registration, before or after it, is not a problem: the device gets zero `"initial_mw"` and ramp
rates there, and zero `"availability"` and `"max_active_power"` if it is not storage (storage has
neither series), as it is not on the system then. A row outside the registration is read like any other.
A zero `RAMPUPRATE`, `RAMPDOWNRATE` or `AVAILABILITY` is carried through as-is: it is AEMO stating that the device
cannot move, or cannot generate, in that interval. Every problem across every device is
collected and raised as one aggregated `ArgumentError` naming the affected `DUID`s, and `sys` is
left unmodified.

!!! warning
    Coarse buckets aggregate the available rows without checking five-minute coverage. An
    incomplete bucket can shift `INITIALMW` away from the period start and omit more restrictive
    ramp rates or availability limits. Ensure the cache covers every five-minute interval.

# Arguments
- `sys`: the `System` to add to.
- `rows`: the dispatch-limit rows over `date_range`, as [`read_dispatch_limits`](@ref) returns them.
- `date_range`: the dispatch intervals to replay. Its step is the model resolution.
- `registered`: the registration span of each unit, keyed by `DUID` (see [`registration_spans`](@ref)),
  or `nothing` when every unit is registered at every interval.

# Returns
`nothing`.
"""
function _set_nem_dispatch_limits!(sys, rows, date_range; registered = nothing)
    base_power = get_base_power(sys)
    full_grid = collect(date_range)[1:(end - 1)]
    interval_hours = Dates.value(Millisecond(step(date_range))) / (1000 * 60 * 60)

    by_duid = DataFrames.isempty(rows) ? nothing : groupby(rows, :DUID)

    devices = nem_dispatch_devices(sys)

    problems = String[]
    buildable = Dict{
        String,
        @NamedTuple{
            initial_mw::Vector{Float64}, ramp_up_rate::Vector{Float64},
            ramp_down_rate::Vector{Float64}, max_active_power::Union{Nothing, Vector{Float64}},
            availability::Union{Nothing, Vector{Float64}},
        }
    }()

    for device in devices
        duid = get_name(device)
        is_storage = device isa NEMStorage
        # A non-scheduled load's rows are not read: every value it gets is zero.
        pinned = is_non_scheduled_load(device)
        device_rows = isnothing(by_duid) || !haskey(by_duid, (duid,)) ? nothing : by_duid[(duid,)]
        if isnothing(device_rows) && !pinned
            push!(problems, "$duid: no DISPATCHLOAD rows in $date_range")
            continue
        end
        by_time = isnothing(device_rows) ? Dict{DateTime, Nothing}() : Dict(zip(device_rows.SETTLEMENTDATE, eachrow(device_rows)))
        unexplained = [t for t in full_grid if !pinned && !haskey(by_time, t) && _is_registered(registered, duid, t)]
        if !isempty(unexplained)
            push!(
                problems,
                "$duid: missing DISPATCHLOAD row(s) for $(length(unexplained)) of $(length(full_grid)) interval(s) (e.g. $(minimum(unexplained)))",
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
        availability = is_storage ? nothing : Float64[]
        reason = nothing
        for t in full_grid
            # A non-scheduled load is dispatched at zero whatever DISPATCHLOAD meters; an unregistered
            # interval has no row and is zero because the unit is not on the system then.
            row = get(by_time, t, nothing)
            if pinned || isnothing(row)
                push!(initial_mw, 0.0)
                push!(ramp_up_rate, 0.0)
                push!(ramp_down_rate, 0.0)
                if !is_storage
                    push!(max_active_power, 0.0)
                    push!(availability, 0.0)
                end
                continue
            end
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
                push!(availability, row.AVAILABILITY)
            end
        end
        if !isnothing(reason)
            push!(problems, "$duid: $reason")
            continue
        end
        buildable[duid] = (
            initial_mw = initial_mw, ramp_up_rate = ramp_up_rate,
            ramp_down_rate = ramp_down_rate, max_active_power = max_active_power,
            availability = availability,
        )
    end

    isempty(problems) || throw(
        ArgumentError(
            "dispatch limits: $(length(problems)) device(s) have unusable DISPATCHLOAD ramp data: " *
                join(problems, "; ") * ".",
        ),
    )

    # sys is mutated only past this point - every throw above leaves it untouched.
    for device in devices
        duid = get_name(device)
        haskey(buildable, duid) || continue
        d = buildable[duid]
        add_time_series!(sys, device, single_series(NEM_SERIES.ramp_up_rate, full_grid, d.ramp_up_rate ./ 60 ./ base_power))
        add_time_series!(sys, device, single_series(NEM_SERIES.ramp_down_rate, full_grid, d.ramp_down_rate ./ 60 ./ base_power))
        add_time_series!(sys, device, single_series(NEM_SERIES.initial_mw, full_grid, d.initial_mw ./ base_power))
        isnothing(d.max_active_power) && continue
        add_time_series!(sys, device, single_series(NEM_SERIES.availability, full_grid, d.availability ./ base_power))
        # Replaces a "max_active_power" series from an earlier call.
        replace_single_series!(
            sys, device,
            single_series(NEM_SERIES.max_active_power, full_grid, d.max_active_power; scaling_factor_multiplier = get_max_active_power),
        )
    end
    return
end
