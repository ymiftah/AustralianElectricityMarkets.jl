"""
    set_effective_offers!(sys)

Attaches the series the NEM dispatch formulation reads as effective offers, per device of `sys`, from
the bids and unit conditions that [`nem_system`](@ref) attaches, as offered:

- `"fcas_effective_<BIDTYPE>[_decremental]"` and `"fcas_ramping_limits_<BIDTYPE>"`, the FCAS offer
  per interval after AEMO *FCAS Model in NEMDE* §4 scaling and §5 enablement, on the timestamps of
  the device's `"fcas_trapezium_<BIDTYPE>[_decremental]"` series, per-unit of the system base.
- `"tie_break_scale_<k>[_decremental]"`, the tie-break scale of each price-tied energy band, and the
  [`EnergyTieBreak`](@ref) service joining the units that carry them.

Existing series of these names are replaced, so a second call on the same `sys` gives the same result.
[`prepare_replay!`](@ref) calls it before attaching the forecasts. Call it before
`transform_single_time_series!`: the series are single time series until then.

# Arguments
- `sys`: the `System` to add to.

# Returns
`nothing`.
"""
function set_effective_offers!(sys::PSY.System)
    _set_fcas_effective_offers!(sys)
    _set_tie_break_scales!(sys)
    return
end
