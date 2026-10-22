"""
    set_fcas_effective_offers!(sys)

Attaches, for every device contributing to an [`FCASService`](@ref), the effective FCAS offer
NEMDE dispatches against in each interval (AEMO *FCAS Model in NEMDE* §4 scaling and §5 enablement
pre-conditions), on the timestamps of the device's `"fcas_trapezium_<BIDTYPE>[_decremental]"`
series, per-unit of the system base:

- `"fcas_effective_<BIDTYPE>[_decremental]"`, one `NTuple{15, Float64}` per interval:
  `(MaxAvail, EnablementMin, EnablementMax, UpperSlopeCoeff, LowerSlopeCoeff, w1, ..., w10)` of the
  scaled trapezium and the offer's band widths, padded with zero widths. An offer not enabled has
  zero `MaxAvail`, slopes and widths and enablement limits `∓FCAS_INACTIVE_LIMIT_MW`.
- `"fcas_ramping_limits_<BIDTYPE>"` for a regulation market, one `NTuple{2, Float64}` per interval:
  the §6.1 joint ramping right-hand side, `+FCAS_INACTIVE_LIMIT_MW` for the upper form and
  `-FCAS_INACTIVE_LIMIT_MW` for the lower form where it does not apply, and, for a `Storage` device
  bidding both sides, the §6.4 SCADA ramping right-hand side, `+FCAS_INACTIVE_LIMIT_MW` where it
  does not apply.

Values follow the dispatch process: AGC scaling, AGC status and `InitialMW` apply at every interval.
Existing series of these names are replaced. Call it after [`set_fcas_bids!`](@ref),
[`set_fcas_scaling_inputs!`](@ref), [`set_market_bids!`](@ref), [`set_nem_dispatch_limits!`](@ref)
and [`add_fcas_services!`](@ref), and before `transform_single_time_series!`; [`FCASMarket`](@ref)
requires these series.

# Arguments
- `sys`: the `System` to add to.

# Returns
`nothing`.
"""
function set_fcas_effective_offers!(sys::PSY.System)
    PSY.with_units_base(sys, "SYSTEM_BASE") do
        inactive = FCAS_INACTIVE_LIMIT_MW / PSY.get_base_power(sys)
        done = Set{Tuple{DataType, String, BidType}}()
        for svc in PSY.get_components(FCASService, sys)
            bid_type = get_bid_type(svc)
            for device in PSY.get_contributing_devices(sys, svc)
                key = (typeof(device), PSY.get_name(device), bid_type)
                key in done && continue
                push!(done, key)
                _attach_fcas_effective_series!(sys, device, bid_type, inactive)
            end
        end
    end
    return
end


"""
    _attach_fcas_effective_series!(sys, device, bid_type, inactive)

Attaches `device`'s [`set_fcas_effective_offers!`](@ref) series for `bid_type`, computed over the
timestamps of its trapezium series under the dispatch process ([`_fcas_effective_values`](@ref)).
No-op for a device without a `bid_type` trapezium series.

# Returns
`nothing`.
"""
function _attach_fcas_effective_series!(sys::PSY.System, device::PSY.Device, bid_type::BidType, inactive::Float64)
    direction = fcas_bid_direction(device, bid_type)
    direction == :none && return
    trapezium = fcas_series_name("fcas_trapezium", bid_type, direction == :decremental)
    stamps = PSY.get_time_series_timestamps(PSY.SingleTimeSeries, device, trapezium)
    resolution = IS.get_resolution(PSY.get_time_series(PSY.SingleTimeSeries, device, trapezium))
    window = _FCASWindow(first(stamps), length(stamps), resolution, :dispatch)
    offers, ramping = _fcas_effective_values(window, device, bid_type, direction, inactive)
    for (decremental, values) in offers
        _replace_fcas_series!(sys, device, _fcas_effective_series_name(bid_type, decremental), stamps, values, resolution)
    end
    isnothing(ramping) || _replace_fcas_series!(sys, device, _fcas_ramping_series_name(bid_type), stamps, ramping, resolution)
    return
end


# Attaches `values` on `stamps` as `device`'s `name` series, replacing an existing one.
function _replace_fcas_series!(sys::PSY.System, device::PSY.Device, name::String, stamps, values, resolution)
    PSY.has_time_series(device, PSY.SingleTimeSeries, name) && PSY.remove_time_series!(sys, PSY.SingleTimeSeries, device, name)
    PSY.add_time_series!(sys, device, single_series(name, first(stamps), values, resolution))
    return
end
