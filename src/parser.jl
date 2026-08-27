using Dates
using DuckDB
using DataFrames
using Chain
using Statistics

# The fixed set of AEMO BIDTYPE values this repo's bid-reading functions accept. A scoped
# enum rather than a free-floating String, since only these values are ever valid - this
# catches a typo'd bid type at construction time instead of it silently becoming a WHERE
# clause that matches zero rows.
#
# RAISE1SEC/LOWER1SEC are included so the enum doesn't need a breaking change when the
# deferred 1-second markets are picked up later - no function in this initial pass
# constructs or accepts them.
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
(not `"\$x"` - see the note below on `@scoped_enum` and `Base.show`).
""" BidType

# The 6 in-scope contingency FCAS markets. Was a `Dict{BidType, FCASResponseTime}` keyed dict
# (response-time band per market); the `FCASResponseTime`-based `Reserve` API that was its
# only consumer is gone (see `GenericConstraint`/`FCASBid` types design,
# docs/superpowers/specs/2026-08-16-*), so this is now just the plain tuple of markets.
const FCAS_CONTINGENCY_MARKETS = (
    BidType.RAISE6SEC, BidType.LOWER6SEC, BidType.RAISE60SEC,
    BidType.LOWER60SEC, BidType.RAISE5MIN, BidType.LOWER5MIN,
)
const FCAS_REGULATION_MARKETS = (BidType.RAISEREG, BidType.LOWERREG)
const FCAS_BID_TYPES = (FCAS_CONTINGENCY_MARKETS..., FCAS_REGULATION_MARKETS...)

# Note: string(bid_type), not "$bid_type" - @scoped_enum overrides Base.show (for a
# human-readable "BidType.RAISE6SEC = 2" REPL display), and Julia's string interpolation
# calls print -> show by default, not Base.string, so bare interpolation would silently
# produce the wrong text anywhere a bid type is spliced into a name or SQL filter.

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

Adds photovoltaic (PV) generation ceilings to the system, from each unit's own
[`read_uigf`](@ref) forecast.

`UIGF` is the per-`DUID` upper limit NEMDE itself applied to a semi-scheduled unit. Units with no `UIGF` (scheduled units, or
intervals AEMO did not publish) keep their static `max_active_power` and get no time series.

# Arguments
- `sys`: The `PowerSystems.System` object.
- `db`: The database connection.
- `date_range`: A range of dates for which to fetch the data.
- `kwargs`: Additional keyword arguments passed to [`read_uigf`](@ref), e.g. `resolution`.
"""
function set_renewable_pv!(sys, db, date_range; kwargs...)
    uigf = read_uigf(db, date_range; kwargs...)
    @info "Setting PV power time series"
    return _add_uigf_ts_to_components!(sys, uigf, PrimeMovers.PVe)
end

"""
    set_renewable_wind!(sys, db, date_range; kwargs...)

Adds wind generation ceilings to the system, from each unit's own [`read_uigf`](@ref) forecast.

`UIGF` is the per-`DUID` upper limit NEMDE itself applied to a semi-scheduled unit. Units with no `UIGF` (scheduled units, or
intervals AEMO did not publish) keep their static `max_active_power` and get no time series.

# Arguments
- `sys`: The `PowerSystems.System` object.
- `db`: The database connection.
- `date_range`: A range of dates for which to fetch the data.
- `kwargs`: Additional keyword arguments passed to [`read_uigf`](@ref), e.g. `resolution`.
"""
function set_renewable_wind!(sys, db, date_range; kwargs...)
    uigf = read_uigf(db, date_range; kwargs...)
    @info "Setting wind power time series"
    return _add_uigf_ts_to_components!(sys, uigf, PrimeMovers.WT)
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
        max_active_power = with_units_base(() -> get_max_active_power(component), sys, "NATURAL_UNITS")
        psy_ts = SingleTimeSeries(;
            name = "max_active_power",
            data = Float64.(ts_component ./ max_active_power),
            scaling_factor_multiplier = get_max_active_power,
        )
        add_time_series!(sys, component, psy_ts)
    end
    return
end

"""
    _add_uigf_ts_to_components!(sys, uigf, prime_mover)

Attaches each semi-scheduled unit's own `UIGF` upper limit to the matching `RenewableDispatch`
component, keyed by `DUID`.

Units absent from `uigf` are left untouched.

# Arguments
- `sys`: The `PowerSystems.System` object.
- `uigf`: A `DataFrame` from [`read_uigf`](@ref) (`SETTLEMENTDATE`, `DUID`, `UIGF`).
- `prime_mover`: The prime mover type of the renewable generator.
"""
function _add_uigf_ts_to_components!(sys, uigf, prime_mover)
    isempty(uigf) && return
    by_duid = groupby(uigf, :DUID)
    for component in get_components(x -> get_prime_mover_type(x) == prime_mover, RenewableDispatch, sys)
        name = get_name(component)
        haskey(by_duid, (DUID = name,)) || continue
        rows = sort(DataFrame(by_duid[(DUID = name,)]), :SETTLEMENTDATE)
        nrow(rows) > 1 || continue
        max_active_power = with_units_base(() -> get_max_active_power(component), sys, "NATURAL_UNITS")
        psy_ts = SingleTimeSeries(;
            name = "max_active_power",
            data = TimeArray(rows.SETTLEMENTDATE, Float64.(rows.UIGF ./ max_active_power)),
            scaling_factor_multiplier = get_max_active_power,
        )
        add_time_series!(sys, component, psy_ts)
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
collapsed into a `piecewise_step_data` column, plus `MAXAVAIL` (`BIDPEROFFER_D`) and
`MINIMUMLOAD`/`DAILYENERGYCONSTRAINT` (`BIDDAYOFFER_D`) - the physical bounds a caller needs
to clip dispatch to, not just the priced curve. See [`read_fcas_bids`](@ref) for the
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
            transform(:INTERVAL_DATETIME => ByRow(x -> ceil.(x, resolution)); renamecols = false)
            groupby([:SETTLEMENTDATE, :INTERVAL_DATETIME, :DUID, :DIRECTION])
            combine(
                _,
                :MAXAVAIL => mean ∘ skipmissing,
                Cols(r"^BANDAVAIL") .=> mean ∘ skipmissing,
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
            :MAXAVAIL, :MINIMUMLOAD, :DAILYENERGYCONSTRAINT,
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
`ROCUP`, `ROCDOWN`) from `BIDPEROFFER_D` for `bid_type`, latest-`VERSIONNO` resolved per
`(SETTLEMENTDATE, INTERVAL_DATETIME, DUID, DIRECTION)`. Does not select `MAXAVAIL` - `bids`
already carries it from the same table/filter via [`_massage_bids`](@ref), and duplicating it
here would force `read_fcas_bids`'s join to rename one copy out from under `_extract_fcas_bid`.
"""
function _read_fcas_trapezium(db, energy_bids_table, bid_type::BidType, start_date, end_date)
    sd = Date(start_date) - Day(1)
    ed = Date(end_date) + Day(1)
    bid_type_str = string(bid_type)
    trapezium = _query(
        db,
        """
        SELECT SETTLEMENTDATE, INTERVAL_DATETIME, DUID, DIRECTION,
               ENABLEMENTMIN, LOWBREAKPOINT, HIGHBREAKPOINT, ENABLEMENTMAX,
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
    _extract_fcas_bid(row)

Mirrors [`_extract_power_bids`](@ref), additionally building the FCAS trapezium row from
`row`'s trapezium columns ([`_read_fcas_trapezium`](@ref)). Returns `(curve_data,
trapezium_row)`: a `PiecewiseStepData` plus an `NTuple{7,Float64}` packing
`(enablement_min, low_breakpoint, high_breakpoint, enablement_max, max_avail, ramp_up_rate,
ramp_down_rate)` (`NaN` where a ramp rate is missing, i.e. non-regulation markets) - the
shape [`set_fcas_bids!`](@ref) attaches as two `Deterministic` series per (generator,
market). Not a single [`FCASBid`](@ref)/[`FCASTrapezium`](@ref) object: confirmed directly
that `Deterministic` rejects `FCASBid` and bare `Vector{Float64}` as a per-step element type
(see `test/fcas.jl`'s `"FCASBid time series round-trip"` testset).
"""
function _extract_fcas_bid(row)
    curve_data = _extract_power_bids(row)
    trapezium_row = (
        row.ENABLEMENTMIN, row.LOWBREAKPOINT, row.HIGHBREAKPOINT, row.ENABLEMENTMAX, row.MAXAVAIL,
        ismissing(row.ROCUP) ? NaN : Float64(row.ROCUP),
        ismissing(row.ROCDOWN) ? NaN : Float64(row.ROCDOWN),
    )
    return curve_data, trapezium_row
end

"""
    _attach_fcas_bid_series!(sys, component, gdf, duid, series_suffix, start_date, resolution)

Attaches the two per-`(component, FCAS market)` `Deterministic` series - `"fcas_curve_\$
series_suffix"` and `"fcas_trapezium_\$series_suffix"` - from `gdf` (a `DUID`-grouped bids
`DataFrame`) if `duid` has a group in it. No-op otherwise, so callers can probe a component
against several `DIRECTION` groupings without checking `haskey` themselves.
"""
function _attach_fcas_bid_series!(sys, component, gdf, duid::AbstractString, series_suffix::AbstractString, start_date, resolution)
    (isnothing(gdf) || !haskey(gdf, (duid,))) && return
    rows = gdf[(duid,)]
    # rows.curve_data/.trapezium_row are SubArray views into the grouped DataFrame -
    # Deterministic's convert_data only accepts a plain Vector.
    curve_ts = Deterministic(;
        name = "fcas_curve_$(series_suffix)",
        data = Dict(start_date => collect(rows.curve_data)),
        resolution = resolution,
        interval = resolution,
    )
    add_time_series!(sys, component, curve_ts)
    trapezium_ts = Deterministic(;
        name = "fcas_trapezium_$(series_suffix)",
        data = Dict(start_date => collect(rows.trapezium_row)),
        resolution = resolution,
        interval = resolution,
    )
    add_time_series!(sys, component, trapezium_ts)
    return
end

"""
    set_fcas_bids!(sys, db, date_range; kwargs...)

Attaches FCAS bid data to the system as two `Deterministic` time series per `(component,
FCAS market)` with bid data in `date_range`:
- `"fcas_curve_<SERVICE>"` (e.g. `"fcas_curve_RAISE6SEC"`), a `Vector{PiecewiseStepData}` -
  the priced 10-band offer curve per interval;
- `"fcas_trapezium_<SERVICE>"`, a `Vector{NTuple{7,Float64}}` - the AEMO trapezium per
  interval, packed by [`_extract_fcas_bid`](@ref).

`DIRECTION` routes and names the series, mirroring [`set_market_bids!`](@ref)'s energy-bid
GEN/LOAD split: `GEN` and `BIDIRECTIONAL` rows are both capability offered while the unit
dispatches normally (a `BIDIRECTIONAL` bid doesn't distinguish charge/discharge, so it's
attached under the plain `<SERVICE>` name alongside `GEN`), attached to every matching
`Generator` and `EnergyReservoirStorage`; `LOAD` rows are decremental capability, attached
only to `EnergyReservoirStorage` under `"<SERVICE>_decremental"`. Dropping `LOAD`/
`BIDIRECTIONAL` rows entirely (as an earlier version of this function did) silently loses a
large share of real FCAS providers - measured on 2 Jan 2025 `BIDPEROFFER_D`, `LOAD` and
`BIDIRECTIONAL` rows together outnumber `GEN` rows for several contingency markets.

Two series, not one carrying [`FCASBid`](@ref)/[`FCASTrapezium`](@ref) objects directly:
confirmed directly that `Deterministic` rejects those (and bare `Vector{Float64}`) as a
per-step element type - see `test/fcas.jl`'s `"FCASBid time series round-trip"` testset for
the proven shape this mirrors. Does not require or create any `Reserve`/service - FCAS
requirements are [`GenericConstraint`](@ref)s built separately by
[`add_nem_constraints!`](@ref).

Unlike the deleted `set_fcas_offers!`, this is genuinely time-varying (mirrors
[`set_market_bids!`](@ref)'s energy-bid path), not a single-interval snapshot.

# Arguments
- `sys`: The `PowerSystems.System` object.
- `db`: The database connection.
- `date_range`: A range of dates for which to fetch FCAS bid data.
"""
function set_fcas_bids!(sys, db, date_range; kwargs...)
    start_date = first(date_range)
    resolution = get(kwargs, :resolution, Minute(5))

    for bid_type in FCAS_BID_TYPES
        bids = read_fcas_bids(db, date_range, bid_type; kwargs...)
        DataFrames.isempty(bids) && continue
        transform!(bids, AsTable(:) => ByRow(_extract_fcas_bid) => [:curve_data, :trapezium_row])
        sort!(bids, :INTERVAL_DATETIME)
        bid_type_str = string(bid_type)

        incremental = subset(bids, :DIRECTION => ByRow(in(("GEN", "BIDIRECTIONAL"))))
        decremental = subset(bids, :DIRECTION => ByRow(==("LOAD")))
        gdf_inc = DataFrames.isempty(incremental) ? nothing : groupby(incremental, :DUID)
        gdf_dec = DataFrames.isempty(decremental) ? nothing : groupby(decremental, :DUID)

        foreach(get_components(Generator, sys)) do gen
            _attach_fcas_bid_series!(sys, gen, gdf_inc, get_name(gen), bid_type_str, start_date, resolution)
        end
        foreach(get_components(EnergyReservoirStorage, sys)) do stor
            duid = get_name(stor)
            _attach_fcas_bid_series!(sys, stor, gdf_inc, duid, bid_type_str, start_date, resolution)
            _attach_fcas_bid_series!(sys, stor, gdf_dec, duid, "$(bid_type_str)_decremental", start_date, resolution)
        end
    end
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
    _table_is_cached(db, table_name) -> Bool

Whether `table_name` has at least one parquet file in the cache. `read_hive` only builds a
glob string, so referencing an uncached table is a hard DuckDB error rather than an empty
result - readers that tolerate a partially-populated cache (e.g. only one side of AEMO's
`DISPATCH_FCAS_REQ` split) must check first. Uses DuckDB's `glob` so it works for remote
filesystems too, not just a local `isdir`.

A glob matching zero files is a legitimate, silent `false` - confirmed directly, DuckDB's
`glob` returns an empty result rather than erroring for a nonexistent local path. It is
*not* silent about a genuine failure to check (bad S3/GS credentials, a network drop,
corrupt parquet): those raise DuckDB's own exception uncaught, naming the real cause,
rather than being swallowed into a false "not cached".
"""
function _table_is_cached(db, table_name::Symbol)
    hive_root = AustralianElectricityMarketsData._parse_hive_root(db.config)
    df = _query(db, "SELECT COUNT(*) AS n FROM glob('$hive_root/$table_name/**/*.parquet')")
    return df.n[1] > 0
end

"""
    read_fcas_requirements(db, date_range; intervention = 0)

Reads per-interval, per-region FCAS requirement constraints actually enforced in dispatch,
long-format: one row per `(SETTLEMENTDATE, REGIONID, BIDTYPE::BidType, GENCONID)`.

AEMO stopped populating the `RESERVE` table (and `DISPATCHREGIONSUM`'s `*REQ` columns) in
Dec 2003 - confirmed directly, both URL patterns 404 for every month tried. The modern
mechanism is generic-constraint-based: `DISPATCH_FCAS_REQ` maps each
`(region, service, interval)` to the `GENCONID` of the generic constraint governing it (a
region/service can be governed by more than one constraint at once - e.g. a regulation
market's target also appears on a contingency constraint's LHS - so this is joined, not
aggregated, to one row per governing constraint).

Each row is a linear constraint `LHS CONSTRAINTTYPE REQUIREMENT` (`CONSTRAINTTYPE` is
`<=`/`>=`/`=`), not a standalone MW quantity - `REQUIREMENT` (`DISPATCHCONSTRAINT.RHS`) is
only meaningful together with `LHS` (`DISPATCHCONSTRAINT.LHS`, the FCAS-and-related dispatch
terms NEMDE actually summed) and `CONSTRAINTTYPE`. Two regimes are common in practice:

- **Disarmed**: AEMO switches an inapplicable constraint variant off by offsetting its
  `REQUIREMENT` by a large negative multiple of 10,000 so it can never bind regardless of
  `LHS` - a `REQUIREMENT` far below any plausible FCAS quantity (in the thousands or tens of
  thousands negative) is this, not a literal deficit. `MARGINALVALUE` is always `0.0` for
  these rows.
- **Armed**: `REQUIREMENT` is the real bound. It can still be negative here - the same
  region/service is often governed by more than one constraint variant (e.g. one that nets
  FCAS against an interconnector flow term on `LHS`), and only one variant is armed at a
  time. Compare `LHS` to `REQUIREMENT` under `CONSTRAINTTYPE` to see whether the constraint
  is satisfied or violated; `MARGINALVALUE != 0.0` confirms it is binding.

`MARGINALVALUE` is the constraint's shadow price, and summing it per `(REGIONID, BIDTYPE)`
reproduces the regional FCAS price (see [`read_fcas_prices`](@ref)). `GENCONDATA` is joined
in only for its human-readable `DESCRIPTION`/`CONSTRAINTTYPE` - `GENCONDATA` is a
change-only table (a constraint version appears only in the archive month it was published),
so a `missing` `DESCRIPTION`/`CONSTRAINTTYPE` usually means the defining archive month isn't
in the local cache, not that AEMO never published one.

`intervention` selects the dispatch run: `0` is the normal (non-intervention) run, which is
the right choice for almost all uses.

Throws an `ArgumentError` when neither `DISPATCH_FCAS_REQ` nor `DISPATCH_FCAS_REQ_CONSTRAINT`
is cached.
"""
function read_fcas_requirements(db, date_range; intervention::Integer = 0)
    start_date = first(date_range)
    end_date = last(date_range)
    sd = Date(start_date) - Day(1)
    ed = Date(end_date) + Day(1)
    constraint_table = read_hive(db, :DISPATCHCONSTRAINT)
    gencon_table = read_hive(db, :GENCONDATA)
    constraint_schema = names(_query(db, "SELECT * FROM $constraint_table LIMIT 0"))
    req_union_sql, req_param_spec = _fcas_req_union_sql(db, intervention)
    if isnothing(req_union_sql)
        throw(
            ArgumentError(
                "Neither DISPATCH_FCAS_REQ nor DISPATCH_FCAS_REQ_CONSTRAINT is cached — run " *
                    "`populate(db, :DISPATCH_FCAS_REQ, ...)` or `populate(db, :DISPATCH_FCAS_REQ_CONSTRAINT, ...)` " *
                    "first (AEMO switched tables at the 2025-05/2025-06 boundary; which one you need depends on the date range).",
            ),
        )
    end
    params = _expand_fcas_req_params(req_param_spec, sd, ed)
    append!(params, [sd, ed])
    _push_intervention!(params, constraint_schema, intervention)
    df = _query(
        db,
        """
        WITH req AS (
            SELECT *
            FROM ($req_union_sql)
            QUALIFY row_number() OVER (
                PARTITION BY SETTLEMENTDATE, GENCONID, REGIONID, BIDTYPE
                ORDER BY GENCONEFFECTIVEDATE DESC NULLS LAST
            ) = 1
        ),
        constraint_rhs AS (
            SELECT SETTLEMENTDATE, CONSTRAINTID, RHS, LHS
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
            TRY_CAST(c.RHS AS DOUBLE) AS REQUIREMENT, TRY_CAST(c.LHS AS DOUBLE) AS LHS,
            TRY_CAST(req.MARGINALVALUE AS DOUBLE) AS MARGINALVALUE,
            g.DESCRIPTION, g.CONSTRAINTTYPE
        FROM req
        INNER JOIN constraint_rhs c
            ON c.SETTLEMENTDATE = req.SETTLEMENTDATE AND c.CONSTRAINTID = req.GENCONID
        -- Exact-version join on the old table's GENCONEFFECTIVEDATE/GENCONVERSIONNO pair;
        -- DISPATCH_FCAS_REQ_CONSTRAINT dropped both, so post-2025-05 rows fall back to the
        -- latest version effective at the interval. DESCRIPTION/CONSTRAINTTYPE are
        -- cosmetic enrichment, so a looser match is acceptable here - it is NOT acceptable
        -- for LHS term joins, which stay exact-equality (see read_constraint_terms).
        LEFT JOIN gencon g
            ON g.GENCONID = req.GENCONID
               AND (
                   (req.GENCONEFFECTIVEDATE IS NOT NULL
                        AND g.EFFECTIVEDATE = req.GENCONEFFECTIVEDATE
                        AND g.VERSIONNO = req.GENCONVERSIONNO)
                   OR (req.GENCONEFFECTIVEDATE IS NULL AND g.EFFECTIVEDATE <= req.SETTLEMENTDATE)
               )
        QUALIFY row_number() OVER (
            PARTITION BY req.SETTLEMENTDATE, req.GENCONID, req.REGIONID, req.BIDTYPE
            ORDER BY g.EFFECTIVEDATE DESC NULLS LAST, g.VERSIONNO DESC NULLS LAST
        ) = 1
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
    read_prices(db, date_range; intervention = 0)

Reads per-interval, per-region **energy** spot prices from `DISPATCHPRICE`: one row per
`(SETTLEMENTDATE, REGIONID)` with `RRP`, `ROP`, `APCFLAG`.

`RRP` is the settlement price; `ROP` is the price before scaling, capping, or VoLL
override - they differ exactly when `APCFLAG != 0` (an administered price cap event). See
[`read_fcas_prices`](@ref) for the FCAS-market equivalent.

`intervention` selects the dispatch run: `0` is the normal (non-intervention) run.

`APCFLAG` is `missing` for cached partitions that predate its addition to `_TABLE_SPECS`
(and `INTERVENTION` is compared via `COALESCE(INTERVENTION, 0)` for the same reason).
"""
function read_prices(db, date_range; intervention::Integer = 0)
    start_date = first(date_range)
    end_date = last(date_range)
    sd = Date(start_date) - Day(1)
    ed = Date(end_date) + Day(1)
    table = read_hive(db, :DISPATCHPRICE)
    schema = names(_query(db, "SELECT * FROM $table LIMIT 0"))
    params = Any[sd, ed]
    _push_intervention!(params, schema, intervention)

    select_cols = ["SETTLEMENTDATE", "REGIONID", _cast_double("RRP"), _cast_double("ROP")]
    "APCFLAG" in schema && push!(select_cols, "TRY_CAST(APCFLAG AS INTEGER) AS APCFLAG")
    select_list = join(select_cols, ", ")
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
    "APCFLAG" in names(df) || (df[!, :APCFLAG] = fill(missing, nrow(df)))
    return df
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

"""
    _uigf_rows(db, where_sql, params, intervention)

Raw `(SETTLEMENTDATE, DUID, UIGF)` rows behind both [`read_uigf`](@ref) methods, deduplicating
archive-month overlap.

`DISPATCHLOAD` carries one row per `(SETTLEMENTDATE, DUID, INTERVENTION)`, so ranking by
`archive_month` alone is enough - there is no forecast-priority dimension to break ties on
(unlike `INTERMITTENT_DS_RUN`, which publishes several forecast runs per interval).

Throws an `ArgumentError` when `DISPATCHLOAD` isn't cached at all. Warns and returns an empty
frame when it *is* cached but every cached partition predates the `UIGF` column - that is
legitimate schema evolution (`read_hive`'s `union_by_name` exists to tolerate it), not a
missing download, so it is not an error; referencing a column absent from *every* file in a
`read_hive` glob would otherwise be a hard DuckDB Binder Error.
"""
function _uigf_rows(db, where_sql::AbstractString, params::Vector{Any}, intervention::Integer)
    _table_is_cached(db, :DISPATCHLOAD) || throw(
        ArgumentError(
            "DISPATCHLOAD is not cached — run `populate(db, :DISPATCHLOAD, <from>, <to>)` first.",
        ),
    )
    table = read_hive(db, :DISPATCHLOAD)
    schema = names(_query(db, "SELECT * FROM $table LIMIT 0"))
    if !("UIGF" in schema)
        @warn "DISPATCHLOAD is cached, but none of its cached partitions have a UIGF column (they predate AEMO adding it); returning no UIGF rows."
        return DataFrame(SETTLEMENTDATE = DateTime[], DUID = String[], UIGF = Float64[])
    end
    _push_intervention!(params, schema, intervention)
    df = _query(
        db,
        """
        SELECT SETTLEMENTDATE, DUID, $(_cast_double("UIGF"))
        FROM $table
        WHERE $where_sql AND UIGF IS NOT NULL
          $(_intervention_where(schema))
        QUALIFY row_number() OVER (
            PARTITION BY SETTLEMENTDATE, DUID ORDER BY archive_month DESC
        ) = 1
        """,
        params,
    )
    dropmissing!(df, :UIGF)
    return df
end

"""
    read_uigf(db, date_range; resolution = Minute(5), intervention = 0)
    read_uigf(db, settlement_date::DateTime; intervention = 0)

Reads the per-unit Unconstrained Intermittent Generation Forecast (`DISPATCHLOAD.UIGF`) - the
upper limit NEMDE applies to each semi-scheduled unit for each dispatch interval.

`UIGF` is `NULL` for scheduled units, so only semi-scheduled DUIDs appear in the result. Over a
`date_range`, rows are ceiled onto `resolution` and averaged within each bucket, matching
[`read_demand`](@ref)'s convention. The `DateTime` method reads exactly one interval and skips
both the widened scan and the bucketing - use it when replicating a single dispatch interval.

`intervention` selects the dispatch run: `0` is the normal (non-intervention) run
(`INTERVENTION` is compared via `COALESCE(INTERVENTION, 0)` for partitions predating that
column - see [`read_fcas_requirements`](@ref)).

# Arguments
- `db`: an `AEMDB` connection.
- `date_range`: the range of interval timestamps to read (half-open: `start <= t < stop`).
- `settlement_date`: a single interval end, read exactly.
- `resolution`: the resolution to aggregate onto. Defaults to 5 minutes.
- `intervention`: 0 for the pricing run, 1 for the physical run.

# Returns
A `DataFrame` with `SETTLEMENTDATE`, `DUID` and `UIGF` (MW).

# Example
```julia
uigf = read_uigf(db, Date(2025, 1, 1):Date(2025, 1, 2); resolution = Minute(30))
one_interval = read_uigf(db, DateTime(2025, 1, 1, 0, 5))
```
"""
function read_uigf(db, date_range; resolution::Dates.Period = Minute(5), intervention::Integer = 0)
    start_date = first(date_range)
    end_date = last(date_range)
    df = _uigf_rows(
        db,
        "SETTLEMENTDATE BETWEEN ? AND ?",
        Any[Date(start_date) - Day(1), Date(end_date) + Day(1)],
        intervention,
    )
    isempty(df) && return df
    # Ceil onto `resolution` before filtering, matching `read_demand`/`set_demand!`: filtering
    # the raw stamps first would let an interval just inside the range (e.g. 01:55) round up
    # onto a bucket just outside it (02:00) and add a spurious trailing bucket.
    df[!, :SETTLEMENTDATE] = ceil.(df[!, :SETTLEMENTDATE], resolution)
    return @chain df begin
        groupby([:SETTLEMENTDATE, :DUID])
        combine(:UIGF => mean => :UIGF)
        subset(:SETTLEMENTDATE => ByRow(x -> start_date <= x < end_date))
        sort([:DUID, :SETTLEMENTDATE])
    end
end

function read_uigf(db, settlement_date::DateTime; intervention::Integer = 0)
    return _uigf_rows(db, "SETTLEMENTDATE = ?", Any[settlement_date], intervention)
end
