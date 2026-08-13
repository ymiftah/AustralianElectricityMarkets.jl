using Dates
using DuckDB
using DataFrames
using Chain
using Statistics


"""
    set_demand!(sys, db, date_range; kwargs...)

Adds load time series data to the system from the database.

This function reads demand data for a specified date range, processes it into a time series,
and attaches it to the `PowerLoad` components in the system.

# Arguments
- `sys`: The `PowerSystems.System` object.
- `db`: The database connection.
- `date_range`: A range of dates for which to fetch demand data.
- `kwargs`: Additional keyword arguments passed to `read_demand`.
"""
function set_demand!(sys, db, date_range; kwargs...)
    demand = read_demand(db; kwargs...)
    ts = @chain demand begin
        transform!(:REGIONID => ByRow(x -> x * " Load") => :name)
        subset!(:SETTLEMENTDATE => ByRow(x -> first(date_range) <= x < last(date_range)))
        _as_timearray(:SETTLEMENTDATE, :name, :TOTALDEMAND)
    end
    return _add_demand_ts_to_components!(sys, ts, PowerLoad)
end

"""
    set_renewable_pv!(sys, db, date_range; kwargs...)

Adds photovoltaic (PV) renewable generation time series data to the system.

This function reads solar availability data for a specified date range from the database,
processes it into a time series, and attaches it to the `RenewableDispatch` components
representing PV generators.

# Arguments
- `sys`: The `PowerSystems.System` object.
- `db`: The database connection.
- `date_range`: A range of dates for which to fetch the data.
- `kwargs`: Additional keyword arguments passed to `read_demand`.
"""
function set_renewable_pv!(sys, db, date_range; kwargs...)
    demand = read_demand(db; kwargs...)
    ts = @chain demand begin
        subset!(:SETTLEMENTDATE => ByRow(x -> first(date_range) <= x < last(date_range)))
        select!(:SETTLEMENTDATE, :REGIONID, :SS_SOLAR_AVAILABILITY)
        disallowmissing!
        _as_timearray(:SETTLEMENTDATE, :REGIONID, :SS_SOLAR_AVAILABILITY)
    end
    @info "Setting PV power time series"
    return _add_renewable_ts_to_components!(sys, ts, PrimeMovers.PVe)
end

"""
    set_renewable_wind!(sys, db, date_range; kwargs...)

Adds wind turbine renewable generation time series data to the system.

This function reads wind availability data for a specified date range from the database,
processes it into a time series, and attaches it to the `RenewableDispatch` components
representing wind turbines.

# Arguments
- `sys`: The `PowerSystems.System` object.
- `db`: The database connection.
- `date_range`: A range of dates for which to fetch the data.
- `kwargs`: Additional keyword arguments passed to `read_demand`.
"""
function set_renewable_wind!(sys, db, date_range; kwargs...)
    demand = read_demand(db; kwargs...)
    ts = @chain demand begin
        subset!(:SETTLEMENTDATE => ByRow(x -> first(date_range) <= x < last(date_range)))
        select!(:SETTLEMENTDATE, :REGIONID, :SS_WIND_AVAILABILITY)
        disallowmissing!
        _as_timearray(:SETTLEMENTDATE, :REGIONID, :SS_WIND_AVAILABILITY)
    end
    @info "Setting wind power time series"
    return _add_renewable_ts_to_components!(sys, ts, PrimeMovers.WT)
end

function set_hydro_limits!(sys, db, date_range; kwargs...)
    energy_bids = read_energy_bids(db, date_range; kwargs...)
    ts = @chain energy_bids begin
        subset!(:DIRECTION => ByRow(==("GEN")))
        select!(:INTERVAL_DATETIME, :DUID, :MAXAVAIL)
        unstack(:INTERVAL_DATETIME, :DUID, :MAXAVAIL; combine = maximum)
        disallowmissing!
        TimeArray(timestamp = :INTERVAL_DATETIME)
    end
    return _add_demand_ts_to_components!(sys, ts, HydroDispatch)
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
    _add_demand_ts_to_components!(sys, ts, type)

Adds demand time series data to the system components.

# Arguments
- `sys`: The `PowerSystems.System` object.
- `ts`: A `TimeArray` of demand data.
- `type`: The type of component to add the time series to.
"""
function _add_demand_ts_to_components!(sys, ts, type)
    loads = colnames(ts)
    for component in get_components(type, sys)
        name = Symbol(get_name(component))
        if !in(name, loads)
            @info "Setting loads to 0 for $name"
            ts_component = ts[first(loads)] .* 0.0
        else
            ts_component = ts[name]
        end
        max_active_power = get_max_active_power(component)
        psy_ts = SingleTimeSeries(;
            name = "max_active_power",
            data = Float64.(ts_component ./ max_active_power ./ get_base_power(sys)),
            scaling_factor_multiplier = get_max_active_power,
        )
        add_time_series!(sys, component, psy_ts)
    end
    return
end

"""
    _add_renewable_ts_to_components!(sys, ts, prime_mover)

Adds renewable generation time series data to the system components.

# Arguments
- `sys`: The `PowerSystems.System` object.
- `ts`: A `TimeArray` of renewable generation data.
- `prime_mover`: The prime mover type of the renewable generator.
"""
function _add_renewable_ts_to_components!(sys, ts, prime_mover)
    for area in get_components(area -> get_name(area) in string.(colnames(ts)), Area, sys)
        area_symbol = Symbol(get_name(area))
        components_in_area = get_components(
            x -> get_area(get_bus(x)) == area && get_prime_mover_type(x) == prime_mover,
            RenewableDispatch,
            sys,
        )
        psy_ts = SingleTimeSeries(;
            name = "max_active_power",
            data = ts[area_symbol] ./ values(maximum(ts[area_symbol]))[1],
            scaling_factor_multiplier = get_max_active_power,
        )
        add_time_series!(sys, components_in_area, psy_ts)
    end
    return
end


"""
    _set_incremental_bid_cost!(sys, gen, gen_bids, start_date, resolution)

Sets `gen` available with a `MarketBidCost` and attaches its incremental
(generation-side) variable cost time series and initial input, derived from
`gen_bids.piecewise_step_data`. Shared by the generator and battery branches
of `set_market_bids!`.
"""
function _set_incremental_bid_cost!(sys, gen, gen_bids, start_date, resolution)
    set_available!(gen, true)
    set_operation_cost!(
        gen,
        MarketBidCost(;
            no_load_cost = 0.0,
            start_up = (hot = 0.0, warm = 0.0, cold = 0.0),
            shut_down = 0.0,
        )
    )
    psd = gen_bids.piecewise_step_data
    time_series_data = Deterministic(;
        name = "variable_cost",
        data = Dict(start_date => psd),
        resolution = resolution,
        interval = resolution
    )
    set_incremental_variable_cost!(sys, gen, time_series_data, UnitSystem.NATURAL_UNITS)
    time_series_incremental_initial_input = Deterministic(;
        name = "incremental_initial_input",
        data = Dict(start_date => zeros(size(psd))),
        resolution = resolution,
        interval = resolution
    )
    set_incremental_initial_input!(sys, gen, time_series_incremental_initial_input)
    return
end

"""
    set_market_bids!(sys, db, date_range; kwargs...)

Adds market bid cost time series data to the system.

This function reads energy and price bid data for a specified date range from the
database, converts it into piecewise `MarketBidCost` variable cost time series, and
attaches it to `Generator` and `EnergyReservoirStorage` components (the latter also
gets decremental/load-side bid costs).

# Arguments
- `sys`: The `PowerSystems.System` object.
- `db`: The database connection.
- `date_range`: A range of dates for which to fetch the data.
- `kwargs`: Additional keyword arguments passed to `_massage_bids` (e.g. `resolution`).
"""
function set_market_bids!(sys, db, date_range; kwargs...)
    start_date = first(date_range)
    end_date = last(date_range)
    resolution = get(kwargs, :resolution, Minute(5))

    energy_bids_table = read_hive(db, :BIDPEROFFER_D)
    pricebids_table = read_hive(db, :BIDDAYOFFER_D)
    bids = _massage_bids(db, energy_bids_table, pricebids_table, start_date, end_date; resolution = get(kwargs, :resolution, nothing))

    # Sets all generator subtype first
    foreach(get_components(Generator, sys)) do gen
        gen_id = get_name(gen)
        gen_bids = subset(bids, :DUID => ByRow(==(gen_id)), :DIRECTION => ByRow(==("GEN")))
        if DataFrames.isempty(gen_bids)
            @warn "No bid data for generator $(gen_id), setting to unavailable."
            set_available!(gen, false)
        else
            _set_incremental_bid_cost!(sys, gen, gen_bids, start_date, resolution)
        end
    end

    # Then sets the batteries
    return foreach(get_components(EnergyReservoirStorage, sys)) do gen
        gen_id = get_name(gen)
        gen_bids = subset(bids, :DUID => ByRow(==(gen_id)), :DIRECTION => ByRow(==("GEN")))
        load_bids = subset(bids, :DUID => ByRow(==(gen_id)), :DIRECTION => ByRow(==("LOAD")))

        if DataFrames.isempty(gen_bids) || DataFrames.isempty(load_bids)
            @warn "No bid data for generator $(gen_id), setting to unavailable."
            set_available!(gen, false)
        else
            _set_incremental_bid_cost!(sys, gen, gen_bids, start_date, resolution)

            # Load bids as decremental inputs
            psd = load_bids.piecewise_step_data
            time_series_data = Deterministic(;
                name = "decremental_variable_cost",
                data = Dict(start_date => psd),
                resolution = get(kwargs, :resolution, Minute(5)),
                interval = get(kwargs, :resolution, Minute(5)),
            )
            set_decremental_variable_cost!(sys, gen, time_series_data, UnitSystem.NATURAL_UNITS)
            time_series_decremental_initial_input = Deterministic(;
                name = "decremental_initial_input",
                data = Dict(
                    start_date => (first ∘ get_y_coords).(psd)
                ),
                resolution = get(kwargs, :resolution, Minute(5)),
                interval = get(kwargs, :resolution, Minute(5)),
            )
            set_decremental_initial_input!(sys, gen, time_series_decremental_initial_input)
        end
    end
end

function read_bids(db, date_range; kwargs...)
    energy_bids_table = read_hive(db, :BIDPEROFFER_D)
    pricebids_table = read_hive(db, :BIDDAYOFFER_D)
    start_date = first(date_range)
    end_date = last(date_range)
    bids = _massage_bids(db, energy_bids_table, pricebids_table, start_date, end_date; resolution = get(kwargs, :resolution, nothing))
    return bids
end

function _extract_power_bids(row)
    price_band_array = copy(row.PRICEBANDARRAY)
    bandavail_array = copy(row.BANDAVAILARRAY)
    if row.DIRECTION == "LOAD"
        # Reverse the order for loads, so the decremental curves are concave
        reverse!(price_band_array)
        reverse!(bandavail_array)
    end
    a = price_band_array[bandavail_array .> 0]
    b = [zero(eltype(price_band_array)); bandavail_array[bandavail_array .> 0] |> cumsum]
    return PiecewiseStepData(b, a)
end

function _massage_bids(db, energy_bids_table, pricebids_table, start_date, end_date; resolution = nothing)
    sd = Date(start_date) - Day(1)
    ed = Date(end_date) + Day(1)
    energy_schema = names(_query(db, "SELECT * FROM $energy_bids_table LIMIT 0"))
    energy_band_cols = join(filter(startswith("BANDAVAIL"), energy_schema), ", ")
    energy_bids = _query(
        db,
        """
        SELECT SETTLEMENTDATE, INTERVAL_DATETIME, DUID, DIRECTION, MAXAVAIL, $energy_band_cols
        FROM $energy_bids_table
        WHERE BIDTYPE = 'ENERGY' AND SETTLEMENTDATE BETWEEN ? AND ?
        QUALIFY row_number() OVER (
            PARTITION BY SETTLEMENTDATE, INTERVAL_DATETIME, DUID, DIRECTION ORDER BY VERSIONNO DESC
        ) = 1
        ORDER BY SETTLEMENTDATE, INTERVAL_DATETIME
        """,
        [sd, ed],
    )

    priceband_schema = names(_query(db, "SELECT * FROM $pricebids_table LIMIT 0"))
    priceband_cols = join(filter(startswith("PRICEBAND"), priceband_schema), ", ")
    pricebids = _query(
        db,
        """
        SELECT SETTLEMENTDATE, DUID, DIRECTION, MINIMUMLOAD, DAILYENERGYCONSTRAINT, $priceband_cols
        FROM $pricebids_table
        WHERE BIDTYPE = 'ENERGY' AND SETTLEMENTDATE BETWEEN ? AND ?
        QUALIFY row_number() OVER (
            PARTITION BY SETTLEMENTDATE, DUID, DIRECTION ORDER BY VERSIONNO DESC
        ) = 1
        ORDER BY SETTLEMENTDATE
        """,
        [sd, ed],
    )

    if !isnothing(resolution)
        energy_bids = @chain energy_bids begin
            transform(
                :INTERVAL_DATETIME => ByRow(x -> ceil.(x, resolution)),
                Cols(r"^BANDAVAIL") .=> ByRow(x -> x * Minute(5) / resolution)
                ;
                renamecols = false
            )
            groupby([:SETTLEMENTDATE, :INTERVAL_DATETIME, :DUID, :DIRECTION])
            combine(
                _,
                :MAXAVAIL => sum ∘ skipmissing,
                Cols(r"^BANDAVAIL") .=> sum,
                ;
                renamecols = false
            )
        end
    end

    all_bids = innerjoin(pricebids, energy_bids, on = [:SETTLEMENTDATE, :DUID, :DIRECTION])
    prep_for_psy = @chain all_bids begin
        subset!(:INTERVAL_DATETIME => ByRow(x -> start_date <= x < end_date))
        transform(
            AsTable(r"^PRICEBAND") => ByRow(collect) => :PRICEBANDARRAY,
            AsTable(r"^BANDAVAIL") => ByRow(collect) => :BANDAVAILARRAY,
        )
        select(
            :SETTLEMENTDATE, :DUID, :DIRECTION, :INTERVAL_DATETIME, :PRICEBANDARRAY, :BANDAVAILARRAY,
            AsTable(:) => ByRow(_extract_power_bids) => :piecewise_step_data
        )
    end
    return prep_for_psy
end
