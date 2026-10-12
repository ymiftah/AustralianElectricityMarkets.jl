"""
    set_demand!(sys, db, date_range; kwargs...)

Adds load time series data to the system from the database.

This function reads demand data for a specified date range, processes it into a time series,
and attaches it to the `PowerLoad` components in the system. `TOTALDEMAND` becomes the
`"max_active_power"` series and `LOSSDEMAND` (see [`read_demand`](@ref)) a second `"loss_demand"`
series.

# Arguments
- `sys`: The `PowerSystems.System` object.
- `db`: The database connection.
- `date_range`: A range of dates for which to fetch demand data.
- `kwargs`: Additional keyword arguments passed to `read_demand`.
"""
function set_demand!(sys, db, date_range; kwargs...)
    demand = read_demand(db; kwargs...)
    demand = @chain demand begin
        transform!(:REGIONID => ByRow(x -> x * " Load") => :name)
        subset!(:SETTLEMENTDATE => ByRow(x -> first(date_range) <= x < last(date_range)))
    end
    ts = _as_timearray(demand, :SETTLEMENTDATE, :name, :TOTALDEMAND)
    loss_ts = _as_timearray(demand, :SETTLEMENTDATE, :name, :LOSSDEMAND)
    _add_demand_ts_to_components!(sys, loss_ts, PowerLoad; name = "loss_demand")
    return _add_demand_ts_to_components!(sys, ts, PowerLoad)
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
    _add_demand_ts_to_components!(sys, ts, type; name = "max_active_power")

Adds demand time series data to the system components under the series name `name`.

# Arguments
- `sys`: The `PowerSystems.System` object.
- `ts`: A `TimeArray` of demand data.
- `type`: The type of component to add the time series to.
- `name`: The time series name to attach it under.
"""
function _add_demand_ts_to_components!(sys, ts, type; name = "max_active_power")
    loads = colnames(ts)
    for component in get_components(type, sys)
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
