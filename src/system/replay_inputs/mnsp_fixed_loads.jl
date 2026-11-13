# The directions of an MNSP link, as `set_mnsp_offers!` names them.
const _MNSP_DIRECTIONS = ("forward", "reverse")


# The `NEMMNSPBid` of `device` for `direction` (`"forward"` or `"reverse"`), or `nothing` when it has none.
function _mnsp_bid(device::PSY.AreaInterchange, direction::AbstractString)
    dir = direction == "forward" ? MNSPDirection.FORWARD : MNSPDirection.REVERSE
    bids = [b for b in PSY.get_supplemental_attributes(NEMMNSPBid, device) if b.direction == dir]
    isempty(bids) && return nothing
    length(bids) == 1 || throw(
        ArgumentError("AreaInterchange \"$(PSY.get_name(device))\" carries $(length(bids)) NEMMNSPBid for its $direction link; it requires one."),
    )
    return only(bids)
end


"""
    _set_mnsp_fixed_loads!(sys::PSY.System) -> Nothing

Adds, for each MNSP link direction of `sys` with a bid, the four series named by
[`NEM_MNSP_FIXED_LOAD_SERIES`](@ref): the loading in MW given by [`mnsp_fixed_load`](@ref) and its
invocation flag, on the timestamps of the bid's `FIXEDLOAD` series. A bid without a fixed loading writes
zeros on the timestamps of its `MAXAVAIL` series.

# Arguments
- `sys`: the system whose MNSP bids [`nem_system`](@ref) attached.

# Returns
`nothing`.
"""
function _set_mnsp_fixed_loads!(sys::PSY.System)
    for device in PSY.get_components(PSY.AreaInterchange, sys)
        for dir in _MNSP_DIRECTIONS
            bid = _mnsp_bid(device, dir)
            isnothing(bid) && continue
            series = isnothing(bid.fixed_load) ? _bid_series(device, bid.max_avail, :max_avail) :
                _bid_series(device, bid.fixed_load, :fixed_load)
            raw = isnothing(bid.fixed_load) ? fill(NaN, length(series.values)) : Float64.(series.values)
            loads = mnsp_fixed_load.(raw)
            for (kind, data) in ((:value, first.(loads)), (:invoked, last.(loads)))
                name = getproperty(NEM_MNSP_FIXED_LOAD_SERIES, Symbol(dir, "_", kind))
                PSY.add_time_series!(sys, device, single_series(name, first(series.timestamps), data, series.resolution))
            end
        end
    end
    return
end
