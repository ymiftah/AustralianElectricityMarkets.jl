function read_energy_bids(db, date_range; kwargs...)
    start_datetime = first(date_range)
    end_datetime = last(date_range)
    sd = Date(start_datetime) - Day(1)
    ed = Date(end_datetime) + Day(1)
    source = read_hive(db, :BIDPEROFFER_D)
    # Discovered dynamically rather than hardcoded, since the number of bid bands
    # isn't fixed in application code.
    schema = names(_query(db, "SELECT * FROM $source LIMIT 0"))
    band_cols = join(filter(startswith("BANDAVAIL"), schema), ", ")

    # Rows are bounded in SQL before the window: a row ceiled into the range has its raw
    # INTERVAL_DATETIME in [start - resolution, end), so this loses none of them.
    resolution = get(kwargs, :resolution, nothing)
    lower = isnothing(resolution) ? start_datetime : start_datetime - resolution
    energy_bids = _query(
        db,
        """
        SELECT SETTLEMENTDATE, INTERVAL_DATETIME, DUID, DIRECTION, MAXAVAIL, $band_cols
        FROM $source
        WHERE BIDTYPE = 'ENERGY' AND SETTLEMENTDATE BETWEEN ? AND ?
          AND INTERVAL_DATETIME >= ? AND INTERVAL_DATETIME < ?
        QUALIFY row_number() OVER (
            PARTITION BY SETTLEMENTDATE, INTERVAL_DATETIME, DUID, DIRECTION ORDER BY VERSIONNO DESC
        ) = 1
        ORDER BY SETTLEMENTDATE, INTERVAL_DATETIME
        """,
        [sd, ed, lower, end_datetime],
    )

    if !isnothing(resolution)
        energy_bids[!, :INTERVAL_DATETIME] = ceil.(energy_bids[!, :INTERVAL_DATETIME], resolution)
        energy_bids = @chain energy_bids begin
            groupby([:SETTLEMENTDATE, :INTERVAL_DATETIME, :DUID, :DIRECTION])
            combine(_, valuecols(_) .=> maximum ∘ skipmissing; renamecols = false)
        end
    end
    subset!(
        energy_bids,
        :INTERVAL_DATETIME => ByRow(x -> (start_datetime <= x < end_datetime))
    )
    return energy_bids
end


"""
    read_fixed_loads(db, date_range) -> DataFrame

Reads participant-entered energy fixed loadings from `BIDPEROFFER_D`: one row per
`(INTERVAL_DATETIME, DUID, DIRECTION)` whose latest offer version carries `FIXEDLOAD > 0`
(zero means no fixed load). Units with a fast-start inflexibility profile (`BIDDAYOFFER_D.T1 > 0`
on the trading day) are excluded, because the profile overrides a fixed loading in modes 1 to 3
and the profile is not replayed.

# Arguments
- `db`: an `AEMDB` connection.
- `date_range`: the dispatch interval labels; rows with `first <= INTERVAL_DATETIME < last` are kept.

# Returns
A `DataFrame` with `INTERVAL_DATETIME`, `DUID`, `DIRECTION` (`GEN` or `LOAD`) and `FIXEDLOAD` (MW,
positive).
"""
function read_fixed_loads(db, date_range)
    start_datetime = first(date_range)
    end_datetime = last(date_range)
    sd = Date(start_datetime) - Day(1)
    ed = Date(end_datetime) + Day(1)
    offers = read_hive(db, :BIDPEROFFER_D)
    day_offers = read_hive(db, :BIDDAYOFFER_D)
    fixed_loads = _query(
        db,
        """
        WITH latest AS (
            SELECT SETTLEMENTDATE, INTERVAL_DATETIME, DUID, DIRECTION, FIXEDLOAD
            FROM $offers
            WHERE BIDTYPE = 'ENERGY' AND SETTLEMENTDATE BETWEEN ? AND ?
            QUALIFY row_number() OVER (
                PARTITION BY SETTLEMENTDATE, INTERVAL_DATETIME, DUID, DIRECTION ORDER BY VERSIONNO DESC
            ) = 1
        ),
        fast_start AS (
            SELECT DISTINCT SETTLEMENTDATE, DUID
            FROM (
                SELECT SETTLEMENTDATE, DUID, T1
                FROM $day_offers
                WHERE BIDTYPE = 'ENERGY' AND SETTLEMENTDATE BETWEEN ? AND ?
                QUALIFY row_number() OVER (
                    PARTITION BY SETTLEMENTDATE, DUID, DIRECTION ORDER BY VERSIONNO DESC
                ) = 1
            )
            WHERE T1 > 0
        )
        SELECT l.INTERVAL_DATETIME, l.DUID, l.DIRECTION, l.FIXEDLOAD
        FROM latest l
        ANTI JOIN fast_start f ON f.SETTLEMENTDATE = l.SETTLEMENTDATE AND f.DUID = l.DUID
        WHERE l.FIXEDLOAD > 0 AND l.INTERVAL_DATETIME >= ? AND l.INTERVAL_DATETIME < ?
        ORDER BY l.INTERVAL_DATETIME, l.DUID, l.DIRECTION
        """,
        [sd, ed, sd, ed, start_datetime, end_datetime],
    )
    return fixed_loads
end


"""
    read_loss_factors(db; as_of = nothing, through = nothing) -> DataFrame

Reads each unit's connection-point loss factors from `DUDETAILSUMMARY`: the row with
`START_DATE <= as_of < END_DATE` in the latest archive.

# Arguments
- `db`: the database connection.
- `as_of`: a `Date` or `DateTime` to resolve the factors as of. `nothing` keeps each unit's open row
  (earliest `START_DATE`, the row [`read_units`](@ref) keeps).
- `through`: when a `Date` or `DateTime` after `as_of`, warns if any unit's factors change
  in `(as_of, through]`, since the result holds one factor per unit.

# Returns
A `DataFrame` with `DUID`, `LOAD_LOSS_FACTOR` (`TRANSMISSIONLOSSFACTOR * DISTRIBUTIONLOSSFACTOR`,
the factor for a load or a battery's charging side) and `GEN_LOSS_FACTOR` (`SECONDARY_TLF *
DISTRIBUTIONLOSSFACTOR` for a `BIDIRECTIONAL` unit that publishes a secondary factor, else
`LOAD_LOSS_FACTOR`). Requires the cached `DUDETAILSUMMARY` to hold the loss-factor columns;
re-populate it with `force_new = true` otherwise.
"""
function read_loss_factors(
        db; as_of::Union{Nothing, Date, DateTime} = nothing,
        through::Union{Nothing, Date, DateTime} = nothing,
    )
    source = read_hive(db, :DUDETAILSUMMARY)
    window = isnothing(as_of) ? "(END_DATE IS NULL OR year(END_DATE) = 2999)" : "START_DATE <= ? AND (END_DATE IS NULL OR END_DATE > ?)"
    # Open rows keep the earliest START_DATE, as read_units does, so both readers pick the same row.
    order = isnothing(as_of) ? "ASC" : "DESC"
    sql = """
        SELECT DUID,
            TRANSMISSIONLOSSFACTOR * DISTRIBUTIONLOSSFACTOR AS LOAD_LOSS_FACTOR,
            CASE WHEN DISPATCHTYPE = 'BIDIRECTIONAL' AND SECONDARY_TLF IS NOT NULL
                 THEN SECONDARY_TLF * DISTRIBUTIONLOSSFACTOR
                 ELSE TRANSMISSIONLOSSFACTOR * DISTRIBUTIONLOSSFACTOR END AS GEN_LOSS_FACTOR
        FROM $source
        WHERE archive_month = (SELECT max(archive_month) FROM $source) AND $window
        QUALIFY row_number() OVER (PARTITION BY DUID ORDER BY START_DATE $order) = 1
    """
    factors = isnothing(as_of) ? _query(db, sql) : _query(db, sql, [as_of, as_of])
    if !isnothing(as_of) && !isnothing(through) && through > as_of
        changed_all = _query(
            db,
            """
            SELECT DISTINCT DUID FROM $source
            WHERE archive_month = (SELECT max(archive_month) FROM $source) AND START_DATE > ? AND START_DATE <= ?
            """,
            [as_of, through],
        ).DUID
        changed = intersect(changed_all, factors.DUID)
        isempty(changed) ||
            @warn "Loss factors change within the date range; the factors in force at its start are used throughout" as_of through first_changed = first(changed, 5)
    end
    return select(factors, :DUID, :GEN_LOSS_FACTOR, :LOAD_LOSS_FACTOR)
end


"""
    _refer_bids_to_reference_node!(bids, factors) -> bids

Divides every price of `bids.piecewise_step_data` by its unit's loss factor, leaving the MW
breakpoints unchanged. Referred prices are rounded to whole cents, as in NEMDE's case files.

# Arguments
- `bids`: the `DataFrame` from `_massage_bids`, modified in place.
- `factors`: the output of [`read_loss_factors`](@ref); `GEN_LOSS_FACTOR` applies to `GEN` rows and
  `LOAD_LOSS_FACTOR` to `LOAD` rows. Throws an `ArgumentError` naming any bid `DUID` it lacks.

# Returns
`bids`.
"""
function _refer_bids_to_reference_node!(bids, factors)
    lookup = Dict(r.DUID => (gen = r.GEN_LOSS_FACTOR, load = r.LOAD_LOSS_FACTOR) for r in eachrow(factors))
    unknown = setdiff(unique(bids.DUID), keys(lookup))
    isempty(unknown) ||
        throw(ArgumentError("No DUDETAILSUMMARY loss factor for bid unit(s) $(join(unknown, ", "))."))
    bids.piecewise_step_data = map(eachrow(bids)) do row
        factor = row.DIRECTION == "LOAD" ? lookup[row.DUID].load : lookup[row.DUID].gen
        psd = row.piecewise_step_data
        return PiecewiseStepData(get_x_coords(psd), round.(get_y_coords(psd) ./ factor; digits = 2))
    end
    return bids
end


"""
    read_bids(db, date_range; kwargs...)

Reads energy offers from `BIDPEROFFER_D`/`BIDDAYOFFER_D` and returns one row per
`(SETTLEMENTDATE, DUID, DIRECTION, INTERVAL_DATETIME)` with the 10-band offer curve
collapsed into a `piecewise_step_data` column of connection-point prices (not referred to the
reference node, unlike [`set_market_bids!`](@ref AustralianElectricityMarkets.set_market_bids!)), plus `MAXAVAIL` (`BIDPEROFFER_D`) and
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
    _extract_power_bids(row; keep_empty_bands = false)

Builds a `PiecewiseStepData` offer curve from a row's `PRICEBANDARRAY`/`BANDAVAILARRAY`
columns, reversing band order for `DIRECTION == "LOAD"` rows so the resulting curve stays
concave. Bands of zero availability are dropped unless `keep_empty_bands`, in which case every
band is a segment and segment `k` is always the same price band.
"""
function _extract_power_bids(row; keep_empty_bands::Bool = false)
    price_band_array = copy(row.PRICEBANDARRAY)
    bandavail_array = copy(row.BANDAVAILARRAY)
    if row.DIRECTION == "LOAD"
        # Reverse the order for loads, so the decremental curves are concave
        reverse!(price_band_array)
        reverse!(bandavail_array)
    end
    kept = keep_empty_bands ? trues(length(bandavail_array)) : bandavail_array .> 0
    a = price_band_array[kept]
    b = [zero(eltype(price_band_array)); bandavail_array[kept] |> cumsum]
    return PiecewiseStepData(b, a)
end


function _massage_bids(
        db, energy_bids_table, pricebids_table, start_date, end_date;
        resolution = nothing, bid_types::AbstractVector{BidType} = [BidType.ENERGY], keep_bid_type::Bool = false,
        keep_empty_bands::Bool = false,
    )
    sd = Date(start_date) - Day(1)
    ed = Date(end_date) + Day(1)
    bid_type_list = join(("'$(string(bt))'" for bt in bid_types), ", ")

    energy_schema = names(_query(db, "SELECT * FROM $energy_bids_table LIMIT 0"))
    energy_band_cols = join(filter(startswith("BANDAVAIL"), energy_schema), ", ")
    # Same bound as read_energy_bids: the ceil and the final range filter keep rows in
    # [start - resolution, end) only.
    lower = isnothing(resolution) ? start_date : start_date - resolution
    energy_bids = _query(
        db,
        """
        SELECT SETTLEMENTDATE, INTERVAL_DATETIME, DUID, DIRECTION, BIDTYPE, MAXAVAIL, $energy_band_cols
        FROM $energy_bids_table
        WHERE BIDTYPE IN ($bid_type_list) AND SETTLEMENTDATE BETWEEN ? AND ?
          AND INTERVAL_DATETIME >= ? AND INTERVAL_DATETIME < ?
        QUALIFY row_number() OVER (
            PARTITION BY SETTLEMENTDATE, INTERVAL_DATETIME, DUID, DIRECTION, BIDTYPE ORDER BY VERSIONNO DESC
        ) = 1
        ORDER BY SETTLEMENTDATE, INTERVAL_DATETIME
        """,
        [sd, ed, lower, end_date],
    )

    priceband_schema = names(_query(db, "SELECT * FROM $pricebids_table LIMIT 0"))
    priceband_cols = join(filter(startswith("PRICEBAND"), priceband_schema), ", ")
    pricebids = _query(
        db,
        """
        SELECT SETTLEMENTDATE, DUID, DIRECTION, BIDTYPE, MINIMUMLOAD, DAILYENERGYCONSTRAINT, $priceband_cols
        FROM $pricebids_table
        WHERE BIDTYPE IN ($bid_type_list) AND SETTLEMENTDATE BETWEEN ? AND ?
        QUALIFY row_number() OVER (
            PARTITION BY SETTLEMENTDATE, DUID, DIRECTION, BIDTYPE ORDER BY VERSIONNO DESC
        ) = 1
        ORDER BY SETTLEMENTDATE
        """,
        [sd, ed],
    )

    if !isnothing(resolution)
        energy_bids = @chain energy_bids begin
            transform(:INTERVAL_DATETIME => ByRow(x -> ceil.(x, resolution)); renamecols = false)
            groupby([:SETTLEMENTDATE, :INTERVAL_DATETIME, :DUID, :DIRECTION, :BIDTYPE])
            combine(
                _,
                :MAXAVAIL => mean ∘ skipmissing,
                Cols(r"^BANDAVAIL") .=> mean ∘ skipmissing,
                ;
                renamecols = false
            )
        end
    end

    join_keys = [:SETTLEMENTDATE, :DUID, :DIRECTION, :BIDTYPE]
    required = subset(energy_bids, :INTERVAL_DATETIME => ByRow(t -> start_date <= t < end_date))
    missing_prices = antijoin(required, pricebids; on = join_keys)
    isempty(missing_prices) || throw(
        ArgumentError(
            "missing price bids for period offers: $(join(sort!(unique(missing_prices.DUID)), ", ")); populate BIDDAYOFFER_D for the referenced trading days",
        )
    )
    all_bids = innerjoin(pricebids, energy_bids, on = join_keys)
    prep_for_psy = @chain all_bids begin
        subset!(:INTERVAL_DATETIME => ByRow(x -> start_date <= x < end_date))
        transform(
            AsTable(r"^PRICEBAND") => ByRow(collect) => :PRICEBANDARRAY,
            AsTable(r"^BANDAVAIL") => ByRow(collect) => :BANDAVAILARRAY,
        )
        select(
            :SETTLEMENTDATE, :DUID, :DIRECTION, :INTERVAL_DATETIME, :PRICEBANDARRAY, :BANDAVAILARRAY,
            :MAXAVAIL, :MINIMUMLOAD, :DAILYENERGYCONSTRAINT, (keep_bid_type ? [:BIDTYPE] : [])...,
            AsTable(:) => ByRow(r -> _extract_power_bids(r; keep_empty_bands)) => :piecewise_step_data
        )
    end
    return prep_for_psy
end
