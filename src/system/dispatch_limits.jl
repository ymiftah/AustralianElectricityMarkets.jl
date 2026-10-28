"""
    nem_dispatch_devices(sys) -> Vector{Device}

Collects every available `ThermalStandard`, `HydroDispatch`, `RenewableDispatch`,
`InterruptiblePowerLoad` and `EnergyReservoirStorage` in `sys`, the device types that the dispatch limits
applies to.

# Arguments
- `sys`: the `System` to collect from.

# Returns
A `Vector{Device}`.
"""
function nem_dispatch_devices(sys)
    devices = Device[]
    append!(devices, collect(get_components(get_available, ThermalStandard, sys)))
    append!(devices, collect(get_components(get_available, HydroDispatch, sys)))
    append!(devices, collect(get_components(get_available, RenewableDispatch, sys)))
    append!(devices, collect(get_components(get_available, InterruptiblePowerLoad, sys)))
    append!(devices, collect(get_components(get_available, EnergyReservoirStorage, sys)))
    return devices
end


function _set_nem_dispatch_limits!(sys, rows, date_range)
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
        availability = is_storage ? nothing : Float64[]
        reason = nothing
        pinned = is_non_scheduled_load(device)
        for t in full_grid
            row = by_time[t]
            if pinned
                # A non-scheduled load's consumption is already in regional demand and is not
                # dispatched: its energy is fixed at zero whatever DISPATCHLOAD meters.
                push!(initial_mw, 0.0)
                push!(ramp_up_rate, 0.0)
                push!(ramp_down_rate, 0.0)
                push!(max_active_power, 0.0)
                push!(availability, 0.0)
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
