_fcas_series_name(prefix::AbstractString, service::BidType, decremental::Bool) =
    decremental ? "$(prefix)_$(string(service))_decremental" : "$(prefix)_$(string(service))"

function _read_fcas_series(kind::AbstractString, component, name::AbstractString, service::BidType, decremental::Bool, initial_time, horizon::Integer)
    if !has_time_series(component, Deterministic, name)
        throw(
            ArgumentError(
                "No FCAS $kind series \"$name\" attached to component \"$(get_name(component))\" " *
                    "for service $(string(service))" * (decremental ? " (decremental)" : "") *
                    " — call set_fcas_bids! first.",
            ),
        )
    end
    return get_time_series_values(Deterministic, component, name; start_time = initial_time, len = horizon)
end

"""
    get_fcas_trapezium(component, service, initial_time, horizon; decremental = false) -> Vector{FCASTrapezium}

Full-series read of `component`'s FCAS trapezium for `service`, `horizon` steps from
`initial_time`. `decremental` selects the storage `DIRECTION == "LOAD"` series. Throws
`ArgumentError` if the series isn't attached.
"""
function get_fcas_trapezium(component, service::BidType, initial_time, horizon::Integer; decremental::Bool = false)
    name = _fcas_series_name("fcas_trapezium", service, decremental)
    rows = _read_fcas_series("trapezium", component, name, service, decremental, initial_time, horizon)
    return FCASTrapezium.(rows)
end

"""
    get_fcas_offer_curve(component, service, initial_time, horizon; decremental = false) -> Vector{PSY.PiecewiseStepData}

Full-series read of `component`'s FCAS offer curve for `service`, `horizon` steps from
`initial_time`. `decremental` selects the storage `DIRECTION == "LOAD"` series. Throws
`ArgumentError` if the series isn't attached.
"""
function get_fcas_offer_curve(component, service::BidType, initial_time, horizon::Integer; decremental::Bool = false)
    name = _fcas_series_name("fcas_curve", service, decremental)
    rows = _read_fcas_series("curve", component, name, service, decremental, initial_time, horizon)
    return PSY.PiecewiseStepData[c for c in rows]
end

"""
    get_fcas_bid(component, service, initial_time, horizon; decremental = false) -> Vector{FCASBid}

Full-series read of `component`'s FCAS bid for `service`, `horizon` steps from
`initial_time`. `decremental` selects the storage `DIRECTION == "LOAD"` series. Throws
`ArgumentError` if the series isn't attached.
"""
function get_fcas_bid(component, service::BidType, initial_time, horizon::Integer; decremental::Bool = false)
    trapeziums = get_fcas_trapezium(component, service, initial_time, horizon; decremental = decremental)
    curves = get_fcas_offer_curve(component, service, initial_time, horizon; decremental = decremental)
    return [FCASBid(service, curve, trapezium) for (curve, trapezium) in zip(curves, trapeziums)]
end
