"""
    _set_demand!(sys, rows, date_range; resolution = Minute(5))

Adds load time series data to the `PowerLoad` components of `sys` from `rows`, as [`read_demand`](@ref)
returns them. `TOTALDEMAND` becomes the `"max_active_power"` series and `LOSSDEMAND` a second
`"loss_demand"` series. Throws an `ArgumentError` if any available load or area has no demand row for an
interval of `date_range`, or if a demand value is not finite.

# Arguments
- `sys`: the `PowerSystems.System` to add to.
- `rows`: the demand rows over `date_range`, as [`read_demand`](@ref) returns them.
- `date_range`: the dispatch intervals to replay; its last timestamp ends the final interval.
- `resolution`: the spacing of the intervals (default five minutes).

# Returns
`nothing`.
"""
function _set_demand!(sys, rows, date_range; resolution = Minute(5))
    demand = @chain rows begin
        transform(:REGIONID => ByRow(x -> x * " Load") => :name)
    end
    grid = DateTime(first(date_range)):resolution:(DateTime(last(date_range)) - resolution)
    present = Set(zip(demand.SETTLEMENTDATE, demand.name))
    required_names = union(
        Set(get_name(load) for load in get_components(get_available, PowerLoad, sys)),
        Set(get_name(area) * " Load" for area in get_components(Area, sys)),
    )
    missing_rows = [(name, t) for name in sort!(collect(required_names)), t in grid if !((t, name) in present)]
    isempty(missing_rows) || throw(
        ArgumentError(
            "missing regional demand inputs: $(join(string.(first(missing_rows, 5)), ", "))",
        )
    )
    all(isfinite, demand.TOTALDEMAND) && all(isfinite, demand.LOSSDEMAND) ||
        throw(ArgumentError("regional demand inputs must be finite"))
    ts = _as_timearray(demand, :SETTLEMENTDATE, :name, :TOTALDEMAND)
    loss_ts = _as_timearray(demand, :SETTLEMENTDATE, :name, :LOSSDEMAND)
    _add_demand_ts_to_components!(sys, loss_ts; name = "loss_demand")
    return _add_demand_ts_to_components!(sys, ts)
end


"""
    _as_timearray(df, index, col, value)

Converts a DataFrame to a TimeArray.

# Arguments
- `df`: The input `DataFrame`.
- `index`: The column to use as the timestamp.
- `col`: The column to use for the column names of the `TimeArray`.
- `value`: The column to use for the values of the `TimeArray`.
"""
function _as_timearray(df, index, col, value)
    out = TimeArray(unstack(df, index, col, value); timestamp = index)
    return Float64.(out)
end


"""
    _add_demand_ts_to_components!(sys, ts; name = NEM_SERIES.max_active_power)

Adds each `PowerLoad`'s demand time series under the series name `name`.

# Arguments
- `sys`: The `PowerSystems.System` object.
- `ts`: A `TimeArray` of demand data, one column per load name.
- `name`: The time series name to attach it under.
"""
function _add_demand_ts_to_components!(sys, ts; name = NEM_SERIES.max_active_power)
    loads = colnames(ts)
    for component in get_components(PowerLoad, sys)
        column = Symbol(get_name(component))
        if !in(column, loads)
            @info "Setting loads to 0 for $column"
            ts_component = ts[first(loads)] .* 0.0
        else
            ts_component = ts[column]
        end
        max_active_power = with_units_base(() -> get_max_active_power(component), sys, "NATURAL_UNITS")
        psy_ts = SingleTimeSeries(;
            name = name,
            data = Float64.(ts_component ./ max_active_power),
            scaling_factor_multiplier = get_max_active_power,
        )
        add_time_series!(sys, component, psy_ts)
    end
    return
end
