"""
    read_energy_bids(db, date_range; resolution = nothing)

Reads the latest energy period offers from `BIDPEROFFER_D`: one row per
`(SETTLEMENTDATE, INTERVAL_DATETIME, DUID, DIRECTION)` with `MAXAVAIL` and the `BANDAVAIL` columns.
With a `resolution`, `INTERVAL_DATETIME` is ceiled onto it and each bucket keeps the maximum of every
quantity.

# Arguments
- `db`: an `AEMDB` connection.
- `date_range`: the intervals to read (half-open: `start <= INTERVAL_DATETIME < stop`).
- `resolution`: a `Dates.Period` to aggregate onto, or `nothing` for the raw intervals.

# Returns
A `DataFrame` with `SETTLEMENTDATE`, `INTERVAL_DATETIME`, `DUID`, `DIRECTION`, `MAXAVAIL` and
`BANDAVAIL1` to `BANDAVAIL10`.
"""
function read_energy_bids(db, date_range; resolution::Union{Nothing, Dates.Period} = nothing)
    start_datetime = first(date_range)
    end_datetime = last(date_range)
    energy_bids = select!(
        _read_period_offers(db, [BidType.ENERGY], start_datetime, end_datetime, resolution), Not(:BIDTYPE),
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
    days = _offer_days(start_datetime, end_datetime)
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
        [days; days; start_datetime; end_datetime],
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
    read_bids(db, date_range; resolution = nothing)

Reads energy offers from `BIDPEROFFER_D`/`BIDDAYOFFER_D` and returns one row per
`(SETTLEMENTDATE, DUID, DIRECTION, INTERVAL_DATETIME)` with the 10-band offer as
`PRICEBANDARRAY` connection-point prices (not referred to the reference node, unlike
[`set_market_bids!`](@ref AustralianElectricityMarkets.set_market_bids!)) and `BANDAVAILARRAY`
MW, plus `MAXAVAIL` (`BIDPEROFFER_D`) and
`MINIMUMLOAD`/`DAILYENERGYCONSTRAINT` (`BIDDAYOFFER_D`) - the physical bounds a caller needs
to clip dispatch to, not just the priced curve. See [`read_fcas_bids`](@ref) for the
FCAS-market equivalent.
"""
function read_bids(db, date_range; resolution::Union{Nothing, Dates.Period} = nothing)
    return _massage_bids(db, first(date_range), last(date_range); resolution)
end


# SQL list literal of `bid_types`, e.g. `'RAISE6SEC', 'LOWER6SEC'`.
_bid_type_list(bid_types) = join(("'$(string(bt))'" for bt in bid_types), ", ")

# The trading days (`SETTLEMENTDATE`) whose offers can cover intervals from `start_date` to `end_date`.
_offer_days(start_date, end_date) = [Date(start_date) - Day(1), Date(end_date) + Day(1)]


# Latest-version `BIDPEROFFER_D` rows of `bid_types` with `start - resolution <= INTERVAL_DATETIME < end`
# (`start` when `resolution` is `nothing`): the rows a ceil onto `resolution` can bring into the range.
# `columns` defaults to `MAXAVAIL` and every cached `BANDAVAIL` column.
function _read_period_offers(db, bid_types::AbstractVector{BidType}, start_date, end_date, resolution; columns = nothing)
    source = read_hive(db, :BIDPEROFFER_D)
    selected = isnothing(columns) ? ["MAXAVAIL"; filter(startswith("BANDAVAIL"), _table_schema(db, source))] : columns
    lower = isnothing(resolution) ? start_date : start_date - resolution
    return _query(
        db,
        """
        SELECT SETTLEMENTDATE, INTERVAL_DATETIME, DUID, DIRECTION, BIDTYPE, $(join(selected, ", "))
        FROM $source
        WHERE BIDTYPE IN ($(_bid_type_list(bid_types))) AND SETTLEMENTDATE BETWEEN ? AND ?
          AND INTERVAL_DATETIME >= ? AND INTERVAL_DATETIME < ?
        QUALIFY row_number() OVER (
            PARTITION BY SETTLEMENTDATE, INTERVAL_DATETIME, DUID, DIRECTION, BIDTYPE ORDER BY VERSIONNO DESC
        ) = 1
        ORDER BY SETTLEMENTDATE, INTERVAL_DATETIME
        """,
        [_offer_days(start_date, end_date); lower; end_date],
    )
end


"""
    _massage_bids(db, start_date, end_date; resolution = nothing, bid_types = [BidType.ENERGY], keep_bid_type = false)

Joins the latest `BIDPEROFFER_D` period offers of `bid_types` to their `BIDDAYOFFER_D` price bands,
one row per `(SETTLEMENTDATE, DUID, DIRECTION, INTERVAL_DATETIME)` with
`start_date <= INTERVAL_DATETIME < end_date`. With a `resolution`, quantities are averaged within
each ceiled bucket. Throws an `ArgumentError` naming the units whose period offers have no price
bands.

# Returns
A `DataFrame` with `SETTLEMENTDATE`, `DUID`, `DIRECTION`, `INTERVAL_DATETIME`, `PRICEBANDARRAY`,
`BANDAVAILARRAY`, `MAXAVAIL`, `MINIMUMLOAD`, `DAILYENERGYCONSTRAINT`, and `BIDTYPE` when
`keep_bid_type`.
"""
function _massage_bids(
        db, start_date, end_date;
        resolution::Union{Nothing, Dates.Period} = nothing, bid_types::AbstractVector{BidType} = [BidType.ENERGY],
        keep_bid_type::Bool = false,
    )
    energy_bids = _read_period_offers(db, bid_types, start_date, end_date, resolution)

    pricebids_table = read_hive(db, :BIDDAYOFFER_D)
    priceband_cols = join(filter(startswith("PRICEBAND"), _table_schema(db, pricebids_table)), ", ")
    pricebids = _query(
        db,
        """
        SELECT SETTLEMENTDATE, DUID, DIRECTION, BIDTYPE, MINIMUMLOAD, DAILYENERGYCONSTRAINT, $priceband_cols
        FROM $pricebids_table
        WHERE BIDTYPE IN ($(_bid_type_list(bid_types))) AND SETTLEMENTDATE BETWEEN ? AND ?
        QUALIFY row_number() OVER (
            PARTITION BY SETTLEMENTDATE, DUID, DIRECTION, BIDTYPE ORDER BY VERSIONNO DESC
        ) = 1
        ORDER BY SETTLEMENTDATE
        """,
        _offer_days(start_date, end_date),
    )

    # TODO Do this in duckdb
    if !isnothing(resolution)
        energy_bids = @chain energy_bids begin
            transform(:INTERVAL_DATETIME => ByRow(x -> ceil(x, resolution)); renamecols = false)
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
        )
    end
    # do all the above in duckdb
    return prep_for_psy
end
