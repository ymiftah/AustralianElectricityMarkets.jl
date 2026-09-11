_fcas_series_name(prefix::AbstractString, service::BidType, decremental::Bool) =
    decremental ? "$(prefix)_$(string(service))_decremental" : "$(prefix)_$(string(service))"

"""
    _fcas_units_multiplier(component) -> Float64

Factor to bring a per-unit-of-system-base FCAS value stored on `component` into its
`System`'s current display units: `get_base_power(sys)` under `NATURAL_UNITS`, `1.0` under
`SYSTEM_BASE`/`DEVICE_BASE`.
"""
function _fcas_units_multiplier(component)
    info = IS.get_internal(component).units_info
    isnothing(info) && return 1.0
    return info.unit_system == UnitSystem.NATURAL_UNITS ? info.base_value : 1.0
end

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
`initial_time`, in `component`'s `System`'s current display units (MW under `NATURAL_UNITS`,
per-unit of the system base under `SYSTEM_BASE`). `decremental` selects the storage
`DIRECTION == "LOAD"` series. Throws `ArgumentError` if the series isn't attached.
"""
function get_fcas_trapezium(component, service::BidType, initial_time, horizon::Integer; decremental::Bool = false)
    name = _fcas_series_name("fcas_trapezium", service, decremental)
    rows = _read_fcas_series("trapezium", component, name, service, decremental, initial_time, horizon)
    multiplier = _fcas_units_multiplier(component)
    return [FCASTrapezium(t .* multiplier) for t in rows]
end

"""
    get_fcas_offer_curve(component, service, initial_time, horizon; decremental = false) -> Vector{PSY.PiecewiseStepData}

Full-series read of `component`'s FCAS offer curve for `service`, `horizon` steps from
`initial_time`. Quantities (`x_coords`) are in `component`'s `System`'s current display units
(MW under `NATURAL_UNITS`, per-unit of the system base under `SYSTEM_BASE`); prices
(`y_coords`) are always \$/MW, never per-unitized. `decremental` selects the storage
`DIRECTION == "LOAD"` series. Throws `ArgumentError` if the series isn't attached.
"""
function get_fcas_offer_curve(component, service::BidType, initial_time, horizon::Integer; decremental::Bool = false)
    name = _fcas_series_name("fcas_curve", service, decremental)
    rows = _read_fcas_series("curve", component, name, service, decremental, initial_time, horizon)
    multiplier = _fcas_units_multiplier(component)
    return [PSY.PiecewiseStepData(get_x_coords(c) .* multiplier, get_y_coords(c)) for c in rows]
end

"""
    _require_equal_length(a, b, service, component)

`nothing` if `a` and `b` have the same length; otherwise an `ArgumentError` naming `service`
and `component`.
"""
function _require_equal_length(a::AbstractVector, b::AbstractVector, service::BidType, component)
    length(a) == length(b) || throw(
        ArgumentError(
            "FCAS trapezium series ($(length(a)) points) and offer curve series " *
                "($(length(b)) points) for $(string(service)) on \"$(get_name(component))\" " *
                "have different lengths - cannot pair them into FCASBids.",
        ),
    )
    return nothing
end

"""
    get_fcas_bid(component, service, initial_time, horizon; decremental = false) -> Vector{FCASBid}

Full-series read of `component`'s FCAS bid for `service`, `horizon` steps from
`initial_time`. `decremental` selects the storage `DIRECTION == "LOAD"` series. Throws
`ArgumentError` if the series isn't attached or if the trapezium and curve series have
different lengths.
"""
function get_fcas_bid(component, service::BidType, initial_time, horizon::Integer; decremental::Bool = false)
    trapeziums = get_fcas_trapezium(component, service, initial_time, horizon; decremental = decremental)
    curves = get_fcas_offer_curve(component, service, initial_time, horizon; decremental = decremental)
    _require_equal_length(trapeziums, curves, service, component)
    return [FCASBid(service, curve, trapezium) for (curve, trapezium) in zip(curves, trapeziums)]
end
