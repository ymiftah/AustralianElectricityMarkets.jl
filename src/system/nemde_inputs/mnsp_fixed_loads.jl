"""
    _set_mnsp_fixed_loads!(sys::PSY.System, grid = _nemde_grid(sys)) -> Nothing

Adds, for each MNSP link direction of `sys` with a bid, the four series named by
[`NEM_MNSP_FIXED_LOAD_SERIES`](@ref): the loading in MW given by [`mnsp_fixed_load`](@ref) and its
invocation flag, on `grid`. A bid without a fixed loading writes zeros.

# Arguments
- `sys`: the system whose MNSP bids [`nem_system`](@ref) attached.
- `grid`: the timestamps the single time series of `sys` share; read from `sys` by default.

# Returns
`nothing`.
"""
function _set_mnsp_fixed_loads!(sys::PSY.System, grid = _nemde_grid(sys))
    for device in PSY.get_components(PSY.AreaInterchange, sys)
        for dir in _MNSP_DIRECTIONS
            bid = _mnsp_bid(device, dir)
            isnothing(bid) && continue
            loads = mnsp_fixed_load.(_values_on_grid(device, bid.fixed_load, grid))
            for (kind, data) in ((:value, first.(loads)), (:invoked, last.(loads)))
                name = getproperty(NEM_MNSP_FIXED_LOAD_SERIES, Symbol(dir, "_", kind))
                PSY.add_time_series!(sys, device, single_series(name, first(grid), data, step(grid)))
            end
        end
    end
    return
end
