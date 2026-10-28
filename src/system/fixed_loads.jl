"""
    _fixed_load_series(sys, fixed_loads) -> Dict{String, Dict{DateTime, Float64}}

Fixed-loading targets on each available device's energy axis: scheduled-load consumption is
positive, and a storage charging target is negative net injection. Rows for units that are not
components of `sys`, or are unavailable, are ignored.
"""
function _fixed_load_series(sys, fixed_loads)
    series = Dict{String, Dict{DateTime, Float64}}()
    for row in eachrow(fixed_loads)
        device = get_component(Device, sys, row.DUID)
        (isnothing(device) || !get_available(device)) && continue
        by_time = get!(series, row.DUID, Dict{DateTime, Float64}())
        sign = device isa Storage && row.DIRECTION == "LOAD" ? -1.0 : 1.0
        by_time[row.INTERVAL_DATETIME] = get(by_time, row.INTERVAL_DATETIME, 0.0) + sign * row.FIXEDLOAD
    end
    return series
end


function _set_nem_fixed_loads!(sys, rows, date_range)
    grid = collect(date_range)[1:(end - 1)]
    base_power = get_base_power(sys)
    for (duid, by_time) in _fixed_load_series(sys, rows)
        device = get_component(Device, sys, duid)
        target = [get(by_time, t, 0.0) / base_power for t in grid]
        invoked = [haskey(by_time, t) ? 1.0 : 0.0 for t in grid]
        any(isone, invoked) || continue
        replace_single_series!(sys, device, single_series(NEM_SERIES.fixed_load, grid, target))
        replace_single_series!(sys, device, single_series(NEM_SERIES.fixed_load_invoked, grid, invoked))
    end
    return
end
