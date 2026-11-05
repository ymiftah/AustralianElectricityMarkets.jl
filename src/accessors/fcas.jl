"""
    _fcas_units_multiplier(component) -> Float64

Factor to bring a per-unit-of-system-base FCAS value stored on `component` into its
`System`'s current display units: `get_base_power(sys)` under `NATURAL_UNITS`, `1.0` under
`SYSTEM_BASE`. Throws under `DEVICE_BASE`.
"""
function _fcas_units_multiplier(component)
    info = IS.get_internal(component).units_info
    isnothing(info) && return 1.0
    # FCAS values are per-unit of the *system* base, while a device's own fields are per-unit
    # of its `base_power`. Under DEVICE_BASE the two would read as the same number meaning
    # different MW, so refuse rather than return a mislabelled value.
    if info.unit_system == UnitSystem.DEVICE_BASE
        throw(
            ArgumentError(
                "FCAS values cannot be read while \"$(get_name(component))\"'s `System` is in " *
                    "DEVICE_BASE: they are stored per-unit of the system base " *
                    "($(info.base_value) MVA), not of the device's own base power " *
                    "($(PSY.get_base_power(component)) MVA). Read them under NATURAL_UNITS or " *
                    "SYSTEM_BASE, e.g. `with_units_base(sys, \"NATURAL_UNITS\") do ... end`.",
            ),
        )
    end
    return info.unit_system == UnitSystem.NATURAL_UNITS ? info.base_value : 1.0
end


"""
    _fcas_system_base(component) -> Float64

The system base power, in MVA, that `component`'s FCAS offer curves are divided by on read. Throws
`ArgumentError` if `component` is not attached to a `System`.
"""
function _fcas_system_base(component)
    info = IS.get_internal(component).units_info
    isnothing(info) && throw(
        ArgumentError(
            "\"$(get_name(component))\" is not attached to a System, so its FCAS offer curves " *
                "have no system base to convert from.",
        ),
    )
    return Float64(info.base_value)
end


function _read_fcas_series(kind::AbstractString, component, name::AbstractString, service::BidType, decremental::Bool, initial_time, horizon::Integer)
    if !has_time_series(component, SingleTimeSeries, name)
        throw(
            ArgumentError(
                "No FCAS $kind series \"$name\" attached to component \"$(get_name(component))\" " *
                    "for service $(string(service))" * (decremental ? " (decremental)" : "") *
                    " — call set_fcas_bids! first.",
            ),
        )
    end
    return get_time_series_values(SingleTimeSeries, component, name; start_time = initial_time, len = horizon)
end


"""
    _get_fcas_trapezium(component, service, initial_time, horizon; decremental = false) -> Vector{FCASTrapezium}

Full-series read of `component`'s FCAS trapezium for `service`, `horizon` steps from
`initial_time`, in `component`'s `System`'s current display units (MW under `NATURAL_UNITS`,
per-unit of the system base under `SYSTEM_BASE`). `decremental` selects the storage
`DIRECTION == "LOAD"` series, or `name` reads the series of that name. Throws `ArgumentError` if the
series isn't attached, or if any step holds a malformed trapezium (out-of-order limits or a negative `MaxAvail`).
"""
function _get_fcas_trapezium(
        component, service::BidType, initial_time, horizon::Integer; decremental::Bool = false,
        name::AbstractString = fcas_series_name("fcas_trapezium", service, decremental),
    )
    rows = _read_fcas_series("trapezium", component, name, service, decremental, initial_time, horizon)
    multiplier = _fcas_units_multiplier(component)
    return [
        _validate_fcas_trapezium(FCASTrapezium(t .* multiplier), "\"$name\" on \"$(get_name(component))\" at step $i")
            for (i, t) in enumerate(rows)
    ]
end


"""
    _get_fcas_offer_curve(component, service, initial_time, horizon; decremental = false) -> Vector{PSY.PiecewiseStepData}

Full-series read of `component`'s FCAS offer curve for `service`, `horizon` steps from
`initial_time`. The series is stored in MW and divided by the system base on read. Quantities
(`x_coords`) are then in `component`'s `System`'s current display units (MW under `NATURAL_UNITS`,
per-unit of the system base under `SYSTEM_BASE`); prices (`y_coords`) are always \$/MW, never
per-unitized. `decremental` selects the storage `DIRECTION == "LOAD"` series, or `name` reads the
series of that name. Throws `ArgumentError` if the series isn't attached.
"""
function _get_fcas_offer_curve(
        component, service::BidType, initial_time, horizon::Integer; decremental::Bool = false,
        name::AbstractString = fcas_offer_series_name(fcas_service(component, service), decremental),
    )
    rows = _read_fcas_series("curve", component, name, service, decremental, initial_time, horizon)
    base_power = _fcas_system_base(component)
    multiplier = _fcas_units_multiplier(component)
    return [PSY.PiecewiseStepData(get_x_coords(c) ./ base_power .* multiplier, get_y_coords(c)) for c in rows]
end
