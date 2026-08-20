const DISPATCH_INTERVAL_HOURS = 1 / 12

"""
    resolve_rebids(bids)

Keeps the latest rebid per `(DUID, BIDTYPE, DIRECTION)`, ordering by `VERSIONNO`. Participants
may rebid quantities up to gate closure, so the archive holds several rows per unit per
interval and only the last one was dispatched.

# Returns
A `DataFrame` with one row per `(DUID, BIDTYPE, DIRECTION)`.
"""
function resolve_rebids(bids::DataFrame)
    isempty(bids) && return bids
    sorted = sort(bids, [:DUID, :BIDTYPE, :DIRECTION, :VERSIONNO])
    return combine(groupby(sorted, [:DUID, :BIDTYPE, :DIRECTION]), last)
end

"""
    energy_bounds(; initial_mw, ramp_up_rate, ramp_down_rate, max_avail, min_load, uigf,
        is_semi_scheduled)

Physical energy dispatch bounds for one unit in one interval, applied in NEMDE's order: ramp
limits from `initial_mw`, then `MAXAVAIL`, then the UIGF weather ceiling for semi-scheduled
units, then `MINIMUMLOAD` for an online unit.

`uigf` caps semi-scheduled units unconditionally — `SEMIDISPATCHCAP = 0` means AEMO did not
actively curtail, not that the weather limit is absent.

# Returns
`(lower, upper)` in MW, guaranteed non-inverting.
"""
function energy_bounds(;
        initial_mw::Float64,
        ramp_up_rate::Float64,
        ramp_down_rate::Float64,
        max_avail::Float64,
        min_load::Float64,
        uigf::Union{Nothing, Float64},
        is_semi_scheduled::Bool,
    )
    upper = initial_mw + ramp_up_rate * DISPATCH_INTERVAL_HOURS
    lower = initial_mw - ramp_down_rate * DISPATCH_INTERVAL_HOURS

    upper = min(upper, max_avail)
    if is_semi_scheduled && !isnothing(uigf)
        upper = min(upper, uigf)
    end
    lower = max(lower, 0.0)
    if initial_mw > 0.0 && min_load > 0.0
        lower = max(lower, min(min_load, upper))
    end
    lower = min(lower, upper)
    return (lower = lower, upper = upper)
end
