using Dates
using DuckDB
using DataFrames
using Chain
using Statistics

# The fixed set of AEMO BIDTYPE values this repo's bid-reading functions accept. A scoped
# enum (same convention as FCASResponseTime) rather than a free-floating String, since only
# these values are ever valid - this catches a typo'd bid type at construction time instead
# of it silently becoming a WHERE clause that matches zero rows.
#
# RAISE1SEC/LOWER1SEC are included so the enum doesn't need a breaking change when the
# deferred 1-second markets are picked up later (see FCASResponseTime.SEC1 docstring) - no
# function in this initial pass constructs or accepts them.
#
# A docstring can't be attached directly above this call: `@scoped_enum` expands to an
# `Expr(:toplevel, ...)`, which Julia's docsystem cannot document.
IS.@scoped_enum(
    BidType,
    ENERGY = 1,
    RAISE6SEC = 2,
    LOWER6SEC = 3,
    RAISE60SEC = 4,
    LOWER60SEC = 5,
    RAISE5MIN = 6,
    LOWER5MIN = 7,
    RAISEREG = 8,
    LOWERREG = 9,
    RAISE1SEC = 10,  # deferred 1-second market, unused for now
    LOWER1SEC = 11,  # deferred 1-second market, unused for now
)

@doc """
    BidType

AEMO's `BIDTYPE` values this repo's bid-reading functions accept: `ENERGY`, and the eight
in-scope FCAS markets (`RAISE6SEC`, `LOWER6SEC`, `RAISE60SEC`, `LOWER60SEC`, `RAISE5MIN`,
`LOWER5MIN`, `RAISEREG`, `LOWERREG`). `RAISE1SEC`/`LOWER1SEC` are also defined (AEMO's newer
1-second markets), but deferred - no function in this package constructs or accepts them
yet. Construct from a string with `BidType("RAISE6SEC")`; convert back with `string(x)`
(not `"\$x"` - see `_fcas_direction`).
""" BidType

# AEMO BIDTYPE -> FCASResponseTime for the 6 contingency FCAS markets in scope.
# RAISE1SEC/LOWER1SEC are deferred (see FCASResponseTime.SEC1 docstring).
const FCAS_CONTINGENCY_MARKETS = Dict(
    BidType.RAISE6SEC => FCASResponseTime.SEC6,
    BidType.LOWER6SEC => FCASResponseTime.SEC6,
    BidType.RAISE60SEC => FCASResponseTime.SEC60,
    BidType.LOWER60SEC => FCASResponseTime.SEC60,
    BidType.RAISE5MIN => FCASResponseTime.MIN5,
    BidType.LOWER5MIN => FCASResponseTime.MIN5,
)
const FCAS_REGULATION_MARKETS = (BidType.RAISEREG, BidType.LOWERREG)
const FCAS_BID_TYPES = (keys(FCAS_CONTINGENCY_MARKETS)..., FCAS_REGULATION_MARKETS...)

# Note: string(bid_type), not "$bid_type" - @scoped_enum overrides Base.show (for a
# human-readable "BidType.RAISE6SEC = 2" REPL display), and Julia's string interpolation
# calls print -> show by default, not Base.string, so bare interpolation would silently
# produce the wrong text anywhere a bid type is spliced into a name or SQL filter.
_fcas_direction(bid_type::BidType) = startswith(string(bid_type), "RAISE") ? ReserveUp : ReserveDown


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

"""
    read_bids(db, date_range; kwargs...)

Reads energy offers from `BIDPEROFFER_D`/`BIDDAYOFFER_D` and returns one row per
`(SETTLEMENTDATE, DUID, DIRECTION, INTERVAL_DATETIME)` with the 10-band offer curve
collapsed into a `piecewise_step_data` column. See [`read_fcas_bids`](@ref) for the
FCAS-market equivalent.
"""
function read_bids(db, date_range; kwargs...)
    energy_bids_table = read_hive(db, :BIDPEROFFER_D)
    pricebids_table = read_hive(db, :BIDDAYOFFER_D)
    start_date = first(date_range)
    end_date = last(date_range)
    bids = _massage_bids(db, energy_bids_table, pricebids_table, start_date, end_date; resolution = get(kwargs, :resolution, nothing))
    return bids
end

"""
    _extract_power_bids(row)

Builds a `PiecewiseStepData` offer curve from a row's `PRICEBANDARRAY`/`BANDAVAILARRAY`
columns, reversing band order for `DIRECTION == "LOAD"` rows so the resulting curve stays
concave.
"""
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

function _massage_bids(db, energy_bids_table, pricebids_table, start_date, end_date; resolution = nothing, bid_type::BidType = BidType.ENERGY)
    sd = Date(start_date) - Day(1)
    ed = Date(end_date) + Day(1)
    bid_type_str = string(bid_type)

    energy_schema = names(_query(db, "SELECT * FROM $energy_bids_table LIMIT 0"))
    energy_band_cols = join(filter(startswith("BANDAVAIL"), energy_schema), ", ")
    energy_bids = _query(
        db,
        """
        SELECT SETTLEMENTDATE, INTERVAL_DATETIME, DUID, DIRECTION, MAXAVAIL, $energy_band_cols
        FROM $energy_bids_table
        WHERE BIDTYPE = ? AND SETTLEMENTDATE BETWEEN ? AND ?
        QUALIFY row_number() OVER (
            PARTITION BY SETTLEMENTDATE, INTERVAL_DATETIME, DUID, DIRECTION ORDER BY VERSIONNO DESC
        ) = 1
        ORDER BY SETTLEMENTDATE, INTERVAL_DATETIME
        """,
        [bid_type_str, sd, ed],
    )

    priceband_schema = names(_query(db, "SELECT * FROM $pricebids_table LIMIT 0"))
    priceband_cols = join(filter(startswith("PRICEBAND"), priceband_schema), ", ")
    pricebids = _query(
        db,
        """
        SELECT SETTLEMENTDATE, DUID, DIRECTION, MINIMUMLOAD, DAILYENERGYCONSTRAINT, $priceband_cols
        FROM $pricebids_table
        WHERE BIDTYPE = ? AND SETTLEMENTDATE BETWEEN ? AND ?
        QUALIFY row_number() OVER (
            PARTITION BY SETTLEMENTDATE, DUID, DIRECTION ORDER BY VERSIONNO DESC
        ) = 1
        ORDER BY SETTLEMENTDATE
        """,
        [bid_type_str, sd, ed],
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

"""
    read_fcas_bids(db, date_range, bid_type::BidType; kwargs...)

Like [`read_bids`](@ref), but for an AEMO FCAS `bid_type` (e.g. `BidType.RAISE6SEC`,
`BidType.RAISEREG` — see `FCAS_BID_TYPES`). Reuses `_massage_bids` for the 10-band offer
curve (same shape as the energy bid path), and additionally reads the AEMO FCAS trapezium
columns from `BIDPEROFFER_D` (`ENABLEMENTMIN/MAX`, `LOWBREAKPOINT`, `HIGHBREAKPOINT`,
`ROCUP`, `ROCDOWN` — already present in that table, just never selected by the
energy-only bid path).
"""
function read_fcas_bids(db, date_range, bid_type::BidType; kwargs...)
    start_date = first(date_range)
    end_date = last(date_range)
    energy_bids_table = read_hive(db, :BIDPEROFFER_D)
    pricebids_table = read_hive(db, :BIDDAYOFFER_D)

    bids = _massage_bids(
        db, energy_bids_table, pricebids_table, start_date, end_date;
        bid_type = bid_type, resolution = get(kwargs, :resolution, nothing),
    )
    trapezium = _read_fcas_trapezium(db, energy_bids_table, bid_type, start_date, end_date)
    return innerjoin(
        bids, trapezium; on = [:SETTLEMENTDATE, :INTERVAL_DATETIME, :DUID, :DIRECTION],
    )
end

"""
    _read_fcas_trapezium(db, energy_bids_table, bid_type::BidType, start_date, end_date)

Reads the FCAS trapezium columns (`ENABLEMENTMIN/MAX`, `LOWBREAKPOINT`, `HIGHBREAKPOINT`,
`MAXAVAIL`, `ROCUP`, `ROCDOWN`) from `BIDPEROFFER_D` for `bid_type`, latest-`VERSIONNO`
resolved per `(SETTLEMENTDATE, INTERVAL_DATETIME, DUID, DIRECTION)`.
"""
function _read_fcas_trapezium(db, energy_bids_table, bid_type::BidType, start_date, end_date)
    sd = Date(start_date) - Day(1)
    ed = Date(end_date) + Day(1)
    bid_type_str = string(bid_type)
    trapezium = _query(
        db,
        """
        SELECT SETTLEMENTDATE, INTERVAL_DATETIME, DUID, DIRECTION,
               ENABLEMENTMIN, LOWBREAKPOINT, HIGHBREAKPOINT, ENABLEMENTMAX, MAXAVAIL,
               ROCUP, ROCDOWN
        FROM $energy_bids_table
        WHERE BIDTYPE = ? AND SETTLEMENTDATE BETWEEN ? AND ?
        QUALIFY row_number() OVER (
            PARTITION BY SETTLEMENTDATE, INTERVAL_DATETIME, DUID, DIRECTION ORDER BY VERSIONNO DESC
        ) = 1
        ORDER BY SETTLEMENTDATE, INTERVAL_DATETIME
        """,
        [bid_type_str, sd, ed],
    )
    subset!(trapezium, :INTERVAL_DATETIME => ByRow(x -> start_date <= x < end_date))
    return trapezium
end

"""
    _extract_fcas_offer(row)

Mirrors [`_extract_power_bids`](@ref), additionally building an [`FCASTrapezium`](@ref).
Expects `row` to have the same `PRICEBANDARRAY`/`BANDAVAILARRAY` columns as
`_extract_power_bids`, the trapezium columns from [`_read_fcas_trapezium`](@ref), and a
`reserve_name` column (the target [`NEMFCASReserve`](@ref)'s name, e.g. `"RAISE6SEC_NSW1"`).
"""
function _extract_fcas_offer(row)
    curve_data = _extract_power_bids(row)
    offer_curve = make_market_bid_curve(curve_data, 0.0)
    trapezium = FCASTrapezium(;
        enablement_min = row.ENABLEMENTMIN,
        low_breakpoint = row.LOWBREAKPOINT,
        high_breakpoint = row.HIGHBREAKPOINT,
        enablement_max = row.ENABLEMENTMAX,
        max_avail = row.MAXAVAIL,
        ramp_up_rate = ismissing(row.ROCUP) ? nothing : Float64(row.ROCUP),
        ramp_down_rate = ismissing(row.ROCDOWN) ? nothing : Float64(row.ROCDOWN),
    )
    return FCASOffer(row.reserve_name, offer_curve, trapezium)
end

"""
    add_fcas_reserves!(sys, regions; bid_types = FCAS_BID_TYPES, requirement = 0.0)

Adds one [`ContingencyFCASReserve`](@ref)/[`RegulationFCASReserve`](@ref) service to `sys`
per (FCAS market, region) pair, matching how AEMO settles regional FCAS requirements
(mainland-vs-local contingency splits, e.g. SA islanding, are out of scope — see plan §4).
`regions` is an iterable of NEM region names (e.g. `["NSW1", "QLD1", ...]`) already present
as `PowerSystems.Area`s in `sys` (see `region_model.jl`).

Returns a `Dict{String, PowerSystems.Reserve}` keyed by reserve name (e.g.
`"RAISE6SEC_NSW1"`), for use by [`set_fcas_offers!`](@ref).
"""
function add_fcas_reserves!(sys, regions; bid_types = FCAS_BID_TYPES, requirement = 0.0)
    reserves = Dict{String, Reserve}()
    for region in regions
        area = get_component(Area, sys, region)
        for bid_type in bid_types
            direction = _fcas_direction(bid_type)
            name = "$(string(bid_type))_$(region)"
            reserve = if haskey(FCAS_CONTINGENCY_MARKETS, bid_type)
                ContingencyFCASReserve{direction}(;
                    name = name, available = true, region = area,
                    response_time = FCAS_CONTINGENCY_MARKETS[bid_type],
                    requirement = Float64(requirement),
                )
            else
                RegulationFCASReserve{direction}(;
                    name = name, available = true, region = area,
                    requirement = Float64(requirement),
                )
            end
            # No contributing devices yet - those attach incrementally in set_fcas_offers!
            # via add_service!(device, reserve, sys). PSY has no add_service!(sys, service)
            # two-arg form; every documented form takes a (possibly empty) devices arg too.
            add_service!(sys, reserve, Device[])
            reserves[name] = reserve
        end
    end
    return reserves
end

"""
    set_fcas_offers!(sys, db, date_range, region_reserves; kwargs...)

Adds FCAS bid data to the system, mirroring [`set_market_bids!`](@ref) for the energy bid
path. For every (market, device) combination with bid data in `date_range`:
- links the device to its regional [`NEMFCASReserve`](@ref) as a contributing device, via
  `PowerSystems.add_service!(device, reserve, sys)` (so `get_contributing_devices(sys,
  reserve)` finds it, same as any other PSY reserve);
- stores the priced [`FCASOffer`](@ref) (10-band offer curve + [`FCASTrapezium`](@ref)) in
  the device's `ext["fcas_offers"]::Vector{FCASOffer}`.

`ext` is used rather than swapping the device's `operation_cost` to a
[`NEMMarketBidCost`](@ref): confirmed directly (not just by reading the schema) that PSY's
auto-generated device structs declare `operation_cost` as a *closed* `Union` of specific
concrete cost types (e.g. `ThermalStandard.operation_cost::Union{ThermalGenerationCost,
MarketBidCost}`), not the abstract `OperationalCost`/`OfferCurveCost` supertype — so no
externally-defined `OfferCurveCost` subtype can ever be assigned there without modifying
PowerSystems' generated structs, which would violate the zero-core-changes goal this plan
is built on. `ext` is PSY's own sanctioned extension point for exactly this situation
("metadata that [isn't] used in simulation" — e.g. `region_model.jl`'s existing
`ext["station_name"]`/`ext["postcode"]` usage). The tradeoff: values stored there round-trip
through `to_json`/`System(path)` as plain `Dict`s, not reconstructed `FCASOffer` structs —
acceptable since simulation-time consumption of this data isn't in scope here (see plan §4).

Unlike energy bids (attached as a full `Deterministic` time series across `date_range` by
[`set_market_bids!`](@ref)), this attaches a single snapshot offer per device per market,
taken from the first interval in `date_range` — full time-varying FCAS bid ingestion is
deferred; see the NEMDE co-optimization scope note in the FCAS types plan.

# Arguments
- `sys`: The `PowerSystems.System` object. Should already have FCAS reserves added via
  [`add_fcas_reserves!`](@ref).
- `db`: The database connection.
- `date_range`: A range of dates for which to fetch FCAS bid data.
- `region_reserves::Dict{String, <:Reserve}`: FCAS reserves already added to `sys`, keyed
  by name (e.g. `"RAISE6SEC_NSW1"`) — see [`add_fcas_reserves!`](@ref).
"""
function set_fcas_offers!(sys, db, date_range, region_reserves::Dict{String, <:Reserve}; kwargs...)
    units = read_units(db)
    duid_region = Dict(zip(units.DUID, units.REGIONID))

    for bid_type in FCAS_BID_TYPES
        bids = read_fcas_bids(db, date_range, bid_type; kwargs...)
        DataFrames.isempty(bids) && continue
        transform!(bids, :DUID => ByRow(x -> get(duid_region, x, missing)) => :REGIONID)
        dropmissing!(bids, :REGIONID)
        DataFrames.isempty(bids) && continue
        bid_type_str = string(bid_type)
        transform!(bids, :REGIONID => ByRow(region -> "$(bid_type_str)_$(region)") => :reserve_name)
        transform!(bids, AsTable(:) => ByRow(_extract_fcas_offer) => :fcas_offer)

        foreach(get_components(Generator, sys)) do gen
            gen_id = get_name(gen)
            gen_bids = subset(bids, :DUID => ByRow(==(gen_id)), :DIRECTION => ByRow(==("GEN")))
            DataFrames.isempty(gen_bids) && return
            reserve_name = first(gen_bids.reserve_name)
            haskey(region_reserves, reserve_name) || return
            _add_fcas_offer!(sys, gen, region_reserves[reserve_name], first(gen_bids.fcas_offer))
        end
    end
    return
end

function _add_fcas_offer!(sys, gen, reserve::Reserve, offer::FCASOffer)
    add_service!(gen, reserve, sys)
    offers = get(get_ext(gen), "fcas_offers", FCASOffer[])
    push!(offers, offer)
    get_ext(gen)["fcas_offers"] = offers
    return
end

# Some cached partitions predate this repo's `_TABLE_SPECS` adding a given column (observed
# directly: RUNNO is entirely absent from every DISPATCHCONSTRAINT/DISPATCHPRICE partition,
# and INTERVENTION from some DISPATCHLOAD/DISPATCHPRICE partitions, in a real, years-old
# cache - apparently a legacy ingestion artifact). `read_hive`'s `union_by_name` only fills
# NULL for a column present in *some* globbed file; referencing a column absent from *every*
# file is still a hard Binder Error. So `INTERVENTION` filtering is built conditionally on
# whether the column is actually in the resolved schema - a partition with no INTERVENTION
# data was written by a pipeline that never distinguished intervention runs, so it is always
# the normal run. RUNNO is "always 1" for ordinary dispatch per AEMO's data model, so it is
# simply never used as a join/filter/partition key by these FCAS readers.
_intervention_where(schema) = "INTERVENTION" in schema ? "AND COALESCE(INTERVENTION, 0) = ?" : ""
_push_intervention!(params, schema, intervention) = "INTERVENTION" in schema ? push!(params, intervention) : params

# `union_by_name` fixes *missing*-column schema drift (see above), but not *conflicting*-type
# drift: observed directly on a real cache, one DISPATCHLOAD partition (out of 19) stores
# TOTALCLEARED as VARCHAR while every other partition stores it as FLOAT, and DuckDB resolves
# that conflict by widening the column to VARCHAR across the *entire* glob - silently turning
# every row's TOTALCLEARED, even from well-typed partitions, into a string. `SELECT *` cannot
# be trusted for a numeric column for this reason; every numeric column these FCAS readers
# return is explicitly `TRY_CAST` to `DOUBLE`.
_cast_double(col) = "TRY_CAST($col AS DOUBLE) AS $col"

"""
    read_fcas_requirements(db, date_range; intervention = 0)

Reads per-interval, per-region FCAS requirement quantities (MW) actually enforced in
dispatch, long-format: one row per `(SETTLEMENTDATE, REGIONID, BIDTYPE::BidType,
GENCONID)`.

AEMO stopped populating the `RESERVE` table (and `DISPATCHREGIONSUM`'s `*REQ` columns) in
Dec 2003 - confirmed directly, both URL patterns 404 for every month tried. The modern
mechanism is generic-constraint-based: `DISPATCH_FCAS_REQ` maps each
`(region, service, interval)` to the `GENCONID` of the generic constraint governing it (a
region/service can be governed by more than one constraint at once - e.g. a regulation
market's target also appears on a contingency constraint's LHS - so this is joined, not
aggregated, to one row per governing constraint), and `DISPATCHCONSTRAINT.RHS` holds the
requirement quantity that constraint actually enforced. `REQUIREMENT` is that RHS;
`MARGINALVALUE` is the constraint's shadow price, and summing it per `(REGIONID, BIDTYPE)`
reproduces the regional FCAS price (see [`read_fcas_prices`](@ref)). `GENCONDATA` is joined
in only for its human-readable `DESCRIPTION`/`CONSTRAINTTYPE`.

`intervention` selects the dispatch run: `0` is the normal (non-intervention) run, which is
the right choice for almost all uses.
"""
function read_fcas_requirements(db, date_range; intervention::Integer = 0)
    start_date = first(date_range)
    end_date = last(date_range)
    sd = Date(start_date) - Day(1)
    ed = Date(end_date) + Day(1)
    req_table = read_hive(db, :DISPATCH_FCAS_REQ)
    constraint_table = read_hive(db, :DISPATCHCONSTRAINT)
    gencon_table = read_hive(db, :GENCONDATA)
    req_schema = names(_query(db, "SELECT * FROM $req_table LIMIT 0"))
    constraint_schema = names(_query(db, "SELECT * FROM $constraint_table LIMIT 0"))
    params = Any[sd, ed]
    _push_intervention!(params, req_schema, intervention)
    append!(params, [sd, ed])
    _push_intervention!(params, constraint_schema, intervention)
    df = _query(
        db,
        """
        WITH req AS (
            SELECT *
            FROM $req_table
            WHERE SETTLEMENTDATE BETWEEN ? AND ? $(_intervention_where(req_schema))
            QUALIFY row_number() OVER (
                PARTITION BY SETTLEMENTDATE, GENCONID, REGIONID, BIDTYPE
                ORDER BY archive_month DESC
            ) = 1
        ),
        constraint_rhs AS (
            SELECT SETTLEMENTDATE, CONSTRAINTID, RHS
            FROM $constraint_table
            WHERE SETTLEMENTDATE BETWEEN ? AND ? $(_intervention_where(constraint_schema))
            QUALIFY row_number() OVER (
                PARTITION BY SETTLEMENTDATE, CONSTRAINTID
                ORDER BY archive_month DESC
            ) = 1
        ),
        gencon AS (
            SELECT GENCONID, EFFECTIVEDATE, VERSIONNO, DESCRIPTION, CONSTRAINTTYPE
            FROM $gencon_table
            QUALIFY row_number() OVER (
                PARTITION BY GENCONID, EFFECTIVEDATE, VERSIONNO ORDER BY archive_month DESC
            ) = 1
        )
        SELECT
            req.SETTLEMENTDATE, req.REGIONID, req.BIDTYPE, req.GENCONID,
            TRY_CAST(c.RHS AS DOUBLE) AS REQUIREMENT, TRY_CAST(req.MARGINALVALUE AS DOUBLE) AS MARGINALVALUE,
            g.DESCRIPTION, g.CONSTRAINTTYPE
        FROM req
        INNER JOIN constraint_rhs c
            ON c.SETTLEMENTDATE = req.SETTLEMENTDATE AND c.CONSTRAINTID = req.GENCONID
        LEFT JOIN gencon g
            ON g.GENCONID = req.GENCONID AND g.EFFECTIVEDATE = req.GENCONEFFECTIVEDATE
               AND g.VERSIONNO = req.GENCONVERSIONNO
        ORDER BY req.SETTLEMENTDATE, req.REGIONID, req.BIDTYPE
        """,
        params,
    )
    subset!(df, :SETTLEMENTDATE => ByRow(x -> start_date <= x < end_date))
    # Restrict to the 8 in-scope FCAS markets (see FCAS_BID_TYPES) - DISPATCH_FCAS_REQ also
    # carries the deferred RAISE1SEC/LOWER1SEC 1-second markets.
    subset!(df, :BIDTYPE => ByRow(in(string.(FCAS_BID_TYPES))))
    transform!(df, :BIDTYPE => ByRow(BidType) => :BIDTYPE)
    return df
end

"""
    read_fcas_prices(db, date_range; intervention = 0)

Reads per-interval, per-region FCAS clearing prices from `DISPATCHPRICE`, long-format: one
row per `(SETTLEMENTDATE, REGIONID, BIDTYPE::BidType, RRP, ROP, APCFLAG)`.

`RRP` is the settlement price; `ROP` is the price before scaling, capping, or VoLL
override - they differ exactly when `APCFLAG != 0` (an administered price cap event).
Summing [`read_fcas_requirements`](@ref)'s `MARGINALVALUE` per `(REGIONID, BIDTYPE)`
reproduces `ROP` for that interval (not `RRP`, which may additionally be capped).

`intervention` selects the dispatch run: `0` is the normal (non-intervention) run.

`APCFLAG` is `missing` for cached partitions that predate its addition to `_TABLE_SPECS`
(and `INTERVENTION` is compared via `COALESCE(INTERVENTION, 0)` for the same reason - see
[`read_fcas_requirements`](@ref)).
"""
function read_fcas_prices(db, date_range; intervention::Integer = 0)
    start_date = first(date_range)
    end_date = last(date_range)
    sd = Date(start_date) - Day(1)
    ed = Date(end_date) + Day(1)
    table = read_hive(db, :DISPATCHPRICE)
    schema = names(_query(db, "SELECT * FROM $table LIMIT 0"))
    params = Any[sd, ed]
    _push_intervention!(params, schema, intervention)

    price_cols = String[]
    for bid_type in FCAS_BID_TYPES
        bid_type_str = string(bid_type)
        rrp_col, rop_col = "$(bid_type_str)RRP", "$(bid_type_str)ROP"
        all(in(schema), (rrp_col, rop_col)) || continue
        push!(price_cols, _cast_double(rrp_col), _cast_double(rop_col))
        apc_col = "$(bid_type_str)APCFLAG"
        apc_col in schema && push!(price_cols, "TRY_CAST($apc_col AS INTEGER) AS $apc_col")
    end
    select_list = join(["SETTLEMENTDATE", "REGIONID", price_cols...], ", ")
    df = _query(
        db,
        """
        SELECT $select_list
        FROM $table
        WHERE SETTLEMENTDATE BETWEEN ? AND ? $(_intervention_where(schema))
        QUALIFY row_number() OVER (
            PARTITION BY SETTLEMENTDATE, REGIONID ORDER BY archive_month DESC
        ) = 1
        """,
        params,
    )
    subset!(df, :SETTLEMENTDATE => ByRow(x -> start_date <= x < end_date))

    long = DataFrame()
    for bid_type in FCAS_BID_TYPES
        bid_type_str = string(bid_type)
        rrp_col, rop_col, apc_col = "$(bid_type_str)RRP", "$(bid_type_str)ROP", "$(bid_type_str)APCFLAG"
        rrp_col in names(df) || continue
        block = select(df, :SETTLEMENTDATE, :REGIONID, rrp_col => :RRP, rop_col => :ROP)
        block[!, :APCFLAG] = apc_col in names(df) ? df[!, apc_col] : fill(missing, nrow(block))
        block[!, :BIDTYPE] = fill(bid_type, nrow(block))
        append!(long, block; promote = true)
    end
    return long
end

"""
    read_fcas_dispatch(db, date_range; intervention = 0)

Reads per-interval, per-unit FCAS dispatch outcomes from `DISPATCHLOAD`, long-format: one
row per `(SETTLEMENTDATE, DUID, BIDTYPE::BidType, TARGET, ACTUALAVAILABILITY)`, plus the
unit's energy context columns `INITIALMW`, `TOTALCLEARED`, `AVAILABILITY`, `AGCSTATUS`. This
is the cleared counterpart to [`read_fcas_bids`](@ref)'s offered trapezium - comparing
`TARGET`/`ACTUALAVAILABILITY` against the offer's trapezium shows how much of what a unit
offered was actually deliverable at its dispatched energy level (see [`FCASTrapezium`](@ref)).

`ACTUALAVAILABILITY` is `missing` for the two regulation markets (`RAISEREG`/`LOWERREG`) -
AEMO does not publish a trapezium-adjusted availability for regulation, only the raw offer
availability (`RAISEREGAVAILABILITY`/`LOWERREGAVAILABILITY`).

`intervention` selects the dispatch run: `0` is the normal (non-intervention) run
(`INTERVENTION` is compared via `COALESCE(INTERVENTION, 0)` for partitions predating that
column - see [`read_fcas_requirements`](@ref)).
"""
function read_fcas_dispatch(db, date_range; intervention::Integer = 0)
    start_date = first(date_range)
    end_date = last(date_range)
    sd = Date(start_date) - Day(1)
    ed = Date(end_date) + Day(1)
    table = read_hive(db, :DISPATCHLOAD)
    dispatch_schema = names(_query(db, "SELECT * FROM $table LIMIT 0"))
    params = Any[sd, ed]
    _push_intervention!(params, dispatch_schema, intervention)

    bidtype_cols = String[]
    for bid_type in FCAS_BID_TYPES
        bid_type_str = string(bid_type)
        bid_type_str in dispatch_schema || continue
        push!(bidtype_cols, _cast_double(bid_type_str))
        avail_col = "$(bid_type_str)ACTUALAVAILABILITY"
        avail_col in dispatch_schema && push!(bidtype_cols, _cast_double(avail_col))
    end
    select_list = join(
        [
            "SETTLEMENTDATE", "DUID",
            _cast_double("INITIALMW"), _cast_double("TOTALCLEARED"), _cast_double("AVAILABILITY"),
            "TRY_CAST(AGCSTATUS AS INTEGER) AS AGCSTATUS",
            bidtype_cols...,
        ],
        ", ",
    )
    df = _query(
        db,
        """
        SELECT $select_list
        FROM $table
        WHERE SETTLEMENTDATE BETWEEN ? AND ? $(_intervention_where(dispatch_schema))
        QUALIFY row_number() OVER (
            PARTITION BY SETTLEMENTDATE, DUID ORDER BY archive_month DESC
        ) = 1
        """,
        params,
    )
    subset!(df, :SETTLEMENTDATE => ByRow(x -> start_date <= x < end_date))

    long = DataFrame()
    for bid_type in FCAS_BID_TYPES
        bid_type_str = string(bid_type)
        target_col = bid_type_str
        avail_col = "$(bid_type_str)ACTUALAVAILABILITY"
        target_col in names(df) || continue
        block = select(
            df,
            :SETTLEMENTDATE, :DUID, :INITIALMW, :TOTALCLEARED, :AVAILABILITY, :AGCSTATUS,
            target_col => :TARGET,
        )
        block[!, :ACTUALAVAILABILITY] = avail_col in names(df) ? df[!, avail_col] : fill(missing, nrow(block))
        block[!, :BIDTYPE] = fill(bid_type, nrow(block))
        append!(long, block; promote = true)
    end
    return long
end
