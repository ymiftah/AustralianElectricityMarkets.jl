"""
    _fixed_load_series(sys, fixed_loads) -> DataFrame

Fixed-loading targets on each available device's energy axis: scheduled-load consumption is
positive, and a storage charging target is negative net injection. Rows for units that are not
components of `sys`, or are unavailable, are ignored. Rows flagged `IN_PROFILE` are not filtered
here; the caller filters them.

# Returns
A `DataFrame` with columns `DUID`, `INTERVAL_DATETIME` and `TARGET` (net injection in MW; a storage
`LOAD` target is negative), one row per device and interval.
"""
function _fixed_load_series(sys, fixed_loads)
    available = Set{String}()
    storages = Set{String}()
    for device in get_components(Device, sys)
        get_available(device) || continue
        push!(available, get_name(device))
        device isa Storage && push!(storages, get_name(device))
    end
    return @chain fixed_loads begin
        subset(:DUID => ByRow(in(available)))
        transform(
            [:DUID, :DIRECTION, :FIXEDLOAD] =>
                ByRow((duid, direction, value) -> duid in storages && direction == "LOAD" ? -value : value) =>
                :TARGET,
        )
        groupby([:DUID, :INTERVAL_DATETIME])
        combine(:TARGET => sum => :TARGET)
    end
end


"""
    _set_nem_fixed_loads!(sys, rows, date_range)

Attaches each available device's participant fixed loading (AEMO's Energy Inflexible Offer,
`BIDPEROFFER_D.FIXEDLOAD > 0`, excluding rows flagged `IN_PROFILE`, where a fast-start unit is in
`DISPATCHMODE` 1 or 2; see [`read_fixed_loads`](@ref))
over the intervals of `date_range` as two series: `"fixed_load"`, the target net injection in system-base
per-unit (`0` where none applies), and `"fixed_load_invoked"`, `1` at the intervals that carry a
fixed loading and `0` elsewhere. A storage device's `GEN` and `LOAD` loadings net into one target.
Devices with no fixed loading in the range get no series; existing series are replaced.

# Arguments
- `sys`: the `System` to add to.
- `rows`: the fixed-loading rows, as [`read_fixed_loads`](@ref) returns them.
- `date_range`: the interval range; its last timestamp ends the final interval.

# Returns
`nothing`.
"""
function _set_nem_fixed_loads!(sys, rows, date_range)
    grid = collect(date_range)[1:(end - 1)]
    base_power = get_base_power(sys)
    attached = subset(rows, :IN_PROFILE => ByRow(!))
    targets = _fixed_load_series(sys, attached)
    for target_rows in groupby(targets, :DUID)
        duid = first(target_rows.DUID)
        device = get_component(Device, sys, duid)
        by_time = Dict(zip(target_rows.INTERVAL_DATETIME, target_rows.TARGET))
        target = [get(by_time, t, 0.0) / base_power for t in grid]
        invoked = [haskey(by_time, t) ? 1.0 : 0.0 for t in grid]
        any(isone, invoked) || continue
        replace_single_series!(sys, device, single_series(NEM_SERIES.fixed_load, grid, target))
        replace_single_series!(sys, device, single_series(NEM_SERIES.fixed_load_invoked, grid, invoked))
    end
    return
end
