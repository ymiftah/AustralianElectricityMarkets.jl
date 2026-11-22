"""
    set_demand!(sys, db, date_range; kwargs...)

Reads [`read_demand`](@ref) over `date_range` and attaches it to the `PowerLoad` components of `sys`:
`TOTALDEMAND` as the `"max_active_power"` series and `LOSSDEMAND` as the `"loss_demand"`
series. Throws an `ArgumentError` if any available load or area has no demand row for an
interval of `date_range`, or if a demand value is not finite. A second call on the same system throws
an `ArgumentError` for the series already attached.

# Arguments
- `sys`: The `PowerSystems.System` object.
- `db`: The database connection.
- `date_range`: A range of dates for which to fetch demand data.
- `kwargs`: Additional keyword arguments passed to `read_demand`.

# Returns
`nothing`.
"""
function set_demand!(sys, db, date_range; kwargs...)
    return set_demand!(sys, read_demand(db, date_range; kwargs...), date_range; resolution = get(kwargs, :resolution, Minute(5)))
end


"""
    set_demand!(sys, demand::DataFrame, date_range; resolution = Minute(5))

Adds load time series to the `PowerLoad` components of `sys` from `demand` rows already read with
[`read_demand`](@ref), with the same series, errors and repeat-call behaviour as the database form.

# Arguments
- `sys`: The `PowerSystems.System` object.
- `demand`: The demand rows over `date_range`, as [`read_demand`](@ref) returns them.
- `date_range`: The dispatch intervals to run; its last timestamp ends the final interval.
- `resolution`: The spacing of the intervals (default five minutes).

# Returns
`nothing`.
"""
function set_demand!(sys, demand::DataFrame, date_range; resolution = Minute(5))
    demand = transform(demand, :REGIONID => ByRow(x -> x * " Load") => :name)
    grid = DateTime(first(date_range)):resolution:(DateTime(last(date_range)) - resolution)
    present = Set(zip(demand.SETTLEMENTDATE, demand.name))
    required_names::Set{String} = union(
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
    # One series pair per load; a load with no demand rows gets zeros.
    stamps = sort(unique(demand.SETTLEMENTDATE))
    by_load = Dict(only(unique(g.name)) => g for g in groupby(demand, :name))
    for load in get_components(PowerLoad, sys)
        rows = get(by_load, get_name(load), nothing)
        max_active_power = with_units_base(() -> get_max_active_power(load), sys, "NATURAL_UNITS")
        for (name, column) in (("loss_demand", :LOSSDEMAND), (NEM_SERIES.max_active_power, :TOTALDEMAND))
            values = isnothing(rows) ? zeros(length(stamps)) : Float64.(sort(rows, :SETTLEMENTDATE)[!, column])
            add_time_series!(
                sys, load,
                SingleTimeSeries(;
                    name, data = TimeArray(stamps, values ./ max_active_power),
                    scaling_factor_multiplier = get_max_active_power,
                ),
            )
        end
    end
    return
end
