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
    _require_fcas_float(row, field::Symbol)

`Float64(getproperty(row, field))`, or an actionable `ArgumentError` naming `field` and the
row's `DUID` if the value is `missing`.
"""
function _require_fcas_float(row, field::Symbol)
    value = getproperty(row, field)
    ismissing(value) && throw(
        ArgumentError(
            "BIDPEROFFER_D.$field is missing for DUID $(row.DUID) - cannot build an " *
                "FCASTrapezium without it.",
        ),
    )
    return Float64(value)
end

"""
    _extract_fcas_bid(row)

Mirrors [`_extract_power_bids`](@ref), also building the FCAS trapezium.

# Returns
`(curve_data, trapezium_row)`: a `PiecewiseStepData` and the `NTuple{7,Float64}` wire form
of an [`FCASTrapezium`](@ref).
"""
function _extract_fcas_bid(row)
    curve_data = _extract_power_bids(row)
    trapezium = FCASTrapezium(;
        enablement_min = _require_fcas_float(row, :ENABLEMENTMIN),
        low_breakpoint = _require_fcas_float(row, :LOWBREAKPOINT),
        high_breakpoint = _require_fcas_float(row, :HIGHBREAKPOINT),
        enablement_max = _require_fcas_float(row, :ENABLEMENTMAX),
        max_avail = _require_fcas_float(row, :MAXAVAIL),
        ramp_up_rate = ismissing(row.ROCUP) ? nothing : Float64(row.ROCUP),
        ramp_down_rate = ismissing(row.ROCDOWN) ? nothing : Float64(row.ROCDOWN),
    )
    return curve_data, Tuple(trapezium)
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

Both series' MW quantities (curve `x_coords`, all trapezium fields but not prices) are stored
per-unit of `sys`'s system base; [`get_fcas_trapezium`](@ref)/[`get_fcas_offer_curve`](@ref)
convert back on read.

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
per-step element type - see `test/fcas/fcas.jl`'s `"FCASBid time series round-trip"` testset for
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
    base_power = get_base_power(sys)

    for bid_type in FCAS_BID_TYPES
        bids = read_fcas_bids(db, date_range, bid_type; kwargs...)
        DataFrames.isempty(bids) && continue
        transform!(bids, AsTable(:) => ByRow(_extract_fcas_bid) => [:curve_data, :trapezium_row])
        # Per-unitize quantities (offer curve x_coords, trapezium MW/ramp-rate fields), not
        # prices (curve y_coords) - src/fcas/access.jl converts back on read.
        transform!(
            bids,
            :curve_data => ByRow(psd -> PiecewiseStepData(get_x_coords(psd) ./ base_power, get_y_coords(psd))) => :curve_data,
            :trapezium_row => ByRow(t -> t ./ base_power) => :trapezium_row,
        )
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
