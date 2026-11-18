"""
    _fixed_load_series(sys, fixed_loads) -> DataFrame

Fixed-loading targets on each available device's energy axis: scheduled-load consumption is
positive, and a storage charging target is negative net injection. Rows for units that are not
components of `sys`, or are unavailable, are ignored.

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
