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
(zero means no fixed load).

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
    offers = read_hive(db, :BIDPEROFFER_D, (start_datetime - Day(1), end_datetime + Day(1)))
    return _query(
        db,
        """
        WITH latest AS (
            SELECT SETTLEMENTDATE, INTERVAL_DATETIME, DUID, DIRECTION, FIXEDLOAD
            FROM $offers
            WHERE BIDTYPE = 'ENERGY' AND SETTLEMENTDATE BETWEEN ? AND ?
            QUALIFY row_number() OVER (
                PARTITION BY SETTLEMENTDATE, INTERVAL_DATETIME, DUID, DIRECTION ORDER BY VERSIONNO DESC
            ) = 1
        )
        SELECT INTERVAL_DATETIME, DUID, DIRECTION, FIXEDLOAD
        FROM latest
        WHERE FIXEDLOAD > 0 AND INTERVAL_DATETIME >= ? AND INTERVAL_DATETIME < ?
        ORDER BY INTERVAL_DATETIME, DUID, DIRECTION
        """,
        [days; start_datetime; end_datetime],
    )
end


"""
    read_loss_factors(db; as_of = nothing, through = nothing) -> DataFrame

Reads each unit's connection-point loss factors from `DUDETAILSUMMARY`: the row with
`START_DATE <= as_of < END_DATE` in the latest archive.

# Arguments
- `db`: the database connection.
- `as_of`: a `Date` or `DateTime` to resolve the factors as of. `nothing` keeps each unit's open row
  (earliest `START_DATE`, the row [`read_units`](@ref) keeps).
- `through`: with `as_of`, resolves the factors over the window `[as_of, through]` instead: each
  unit's earliest row registered in it, the row [`read_units`](@ref) keeps with the same `through`.
  Warns if a unit's factors differ between its rows in the window, since the result holds one
  factor per unit.

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
    isnothing(through) || !isnothing(as_of) || throw(ArgumentError("read_loss_factors: through requires as_of"))
    source = read_hive(db, :DUDETAILSUMMARY)
    windowed = !isnothing(through)
    window = if isnothing(as_of)
        "(END_DATE IS NULL OR year(END_DATE) = 2999)"
    elseif windowed
        _registration_window_sql()
    else
        "START_DATE <= ? AND (END_DATE IS NULL OR END_DATE > ?)"
    end
    # Open rows keep the earliest START_DATE, as read_units does, so both readers pick the same row.
    order = isnothing(as_of) || windowed ? "ASC" : "DESC"
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
    factors = if isnothing(as_of)
        _query(db, sql)
    elseif windowed
        _query(db, sql, [through, as_of])
    else
        _query(db, sql, [as_of, as_of])
    end
    if windowed
        # NULL counts as a value, so a NULL to number change in SECONDARY_TLF is caught.
        changed_all = _query(
            db,
            """
            SELECT DUID
            FROM $source
            WHERE archive_month = (SELECT max(archive_month) FROM $source) AND $window
            GROUP BY DUID
            HAVING count(DISTINCT TRANSMISSIONLOSSFACTOR) > 1
                OR count(DISTINCT DISTRIBUTIONLOSSFACTOR) > 1
                OR count(DISTINCT coalesce(CAST(SECONDARY_TLF AS VARCHAR), 'NULL')) > 1
            """,
            [through, as_of],
        ).DUID
        changed = intersect(changed_all, factors.DUID)
        isempty(changed) ||
            @warn "Loss factors change within the date range; the factors of each unit's earliest registration row overlapping it are used throughout" as_of through first_changed = first(changed, 5)
    end
    return select(factors, :DUID, :GEN_LOSS_FACTOR, :LOAD_LOSS_FACTOR)
end


"""
    read_bids(db, date_range; resolution = nothing)

Reads energy offers from `BIDPEROFFER_D`/`BIDDAYOFFER_D`: one row per
`(SETTLEMENTDATE, DUID, DIRECTION, INTERVAL_DATETIME)` with `PRICEBANDARRAY` (connection-point
prices, not referred to the reference node), `BANDAVAILARRAY` (MW), `MAXAVAIL`, `MINIMUMLOAD` and
`DAILYENERGYCONSTRAINT`. See [`read_fcas_bids`](@ref) for the FCAS markets.
"""
function read_bids(db, date_range; resolution::Union{Nothing, Dates.Period} = nothing)
    return _massage_bids(db, first(date_range), last(date_range); resolution)
end


"""
    read_offers(db, date_range; markets = NEM_MARKETS) -> DataFrame

Reads the latest energy and FCAS offers of `markets` in one query: `BIDPEROFFER_D` period offers
joined to their `BIDDAYOFFER_D` price bands, at native resolution. Each row is one
`(SETTLEMENTDATE, INTERVAL_DATETIME, DUID, DIRECTION, BIDTYPE)` with
`first(date_range) <= INTERVAL_DATETIME < last(date_range)`. When `BIDDAYOFFER` is cached, the
`MINIMUMLOAD` and `T1` to `T4` of an energy row come from the daily offer version in force at the
interval: the latest `BIDDAYOFFER.OFFERDATE` at or before the period offer's `LASTCHANGED`. Rows
without such a version, and every row when `BIDDAYOFFER` is not cached, keep the `BIDDAYOFFER_D` values.

# Arguments
- `db`: an `AEMDB` connection.
- `date_range`: the intervals to read (half-open).
- `markets`: the `BidType` values to read, default `NEM_MARKETS`.

# Returns
A `DataFrame` with `SETTLEMENTDATE`, `INTERVAL_DATETIME`, `DUID`, `DIRECTION`, `BIDTYPE` (`BidType`),
`PRICEBANDARRAY`, `BANDAVAILARRAY`, `MAXAVAIL`, `MINIMUMLOAD`, `DAILYENERGYCONSTRAINT`, `T1`, `T2`,
`T3`, `T4`, `NORMALSTATUS`, `FIXEDLOAD`, `ROCUP`, `ROCDOWN`, `ENERGYLIMIT`, `ENABLEMENTMIN`,
`LOWBREAKPOINT`, `HIGHBREAKPOINT` and `ENABLEMENTMAX`.
Throws an `ArgumentError` naming any of these columns absent from the cached tables, and when a
unit's period offers have no price bands.
"""
function read_offers(db, date_range; markets = NEM_MARKETS)
    start_date = first(date_range)
    end_date = last(date_range)
    period_source = read_hive(db, :BIDPEROFFER_D, (start_date - Day(1), end_date + Day(1)))
    price_source = read_hive(db, :BIDDAYOFFER_D, (start_date - Day(1), end_date + Day(1)))
    _require_columns(
        :BIDPEROFFER_D, _table_schema(db, period_source),
        ["FIXEDLOAD", "ENABLEMENTMIN", "LOWBREAKPOINT", "HIGHBREAKPOINT", "ENABLEMENTMAX", "ROCUP", "ROCDOWN", "ENERGYLIMIT"],
    )
    _require_columns(
        :BIDDAYOFFER_D, _table_schema(db, price_source),
        ["MINIMUMLOAD", "DAILYENERGYCONSTRAINT", "T1", "T2", "T3", "T4", "NORMALSTATUS"],
    )
    in_force = BidType.ENERGY in markets && _table_is_cached(db, :BIDDAYOFFER)
    in_force && _require_columns(:BIDPEROFFER_D, _table_schema(db, period_source), ["LASTCHANGED"])
    offers = _massage_bids(
        db, start_date, end_date; bid_types = collect(BidType, markets), keep_bid_type = true,
        period_columns = ["FIXEDLOAD", "ENABLEMENTMIN", "LOWBREAKPOINT", "HIGHBREAKPOINT", "ENABLEMENTMAX", "ROCUP", "ROCDOWN", "ENERGYLIMIT"],
        extra_price_columns = ["T1", "T2", "T3", "T4", "NORMALSTATUS"], in_force,
    )
    transform!(offers, :BIDTYPE => ByRow(BidType) => :BIDTYPE)
    return offers
end


# SQL list literal of `bid_types`, e.g. `'RAISE6SEC', 'LOWER6SEC'`.
_bid_type_list(bid_types) = join(("'$(string(bt))'" for bt in bid_types), ", ")

# The trading days (`SETTLEMENTDATE`) whose offers can cover intervals from `start_date` to `end_date`.
_offer_days(start_date, end_date) = [Date(start_date) - Day(1), Date(end_date) + Day(1)]


# Latest-version `BIDPEROFFER_D` rows of `bid_types` with `start - resolution <= INTERVAL_DATETIME < end`
# (`start` when `resolution` is `nothing`): the rows a ceil onto `resolution` can bring into the range.
# `columns` defaults to `MAXAVAIL` and every cached `BANDAVAIL` column.
function _read_period_offers(db, bid_types::AbstractVector{BidType}, start_date, end_date, resolution; columns = nothing)
    sql, params = _period_offers_sql(db, bid_types, start_date, end_date, resolution; columns)
    return _query(db, sql, params)
end


# Numbered bands are ordered numerically, independent of parquet column order.
function _band_columns(schema, prefix)
    return sort(filter(c -> occursin(Regex("^$(prefix)[0-9]+\$"), c), schema); by = c -> parse(Int, c[(length(prefix) + 1):end]))
end


function _period_offers_sql(db, bid_types, start_date, end_date, resolution; columns = nothing)
    source = read_hive(db, :BIDPEROFFER_D, (start_date - Day(1), end_date + Day(1)))
    selected = isnothing(columns) ? ["MAXAVAIL"; _band_columns(_table_schema(db, source), "BANDAVAIL")] : columns
    lower = isnothing(resolution) ? start_date : start_date - resolution
    sql = """
    SELECT SETTLEMENTDATE, INTERVAL_DATETIME, DUID, DIRECTION, BIDTYPE, $(join(selected, ", "))
    FROM $source
    WHERE BIDTYPE IN ($(_bid_type_list(bid_types))) AND SETTLEMENTDATE BETWEEN ? AND ?
      AND INTERVAL_DATETIME >= ? AND INTERVAL_DATETIME < ?
    QUALIFY row_number() OVER (
        PARTITION BY SETTLEMENTDATE, INTERVAL_DATETIME, DUID, DIRECTION, BIDTYPE ORDER BY VERSIONNO DESC
    ) = 1
    ORDER BY SETTLEMENTDATE, INTERVAL_DATETIME
    """
    return sql, [_offer_days(start_date, end_date); lower; end_date]
end


"""
    _massage_bids(db, start_date, end_date; resolution = nothing, bid_types = [BidType.ENERGY], keep_bid_type = false, period_columns = String[])

Joins the latest `BIDPEROFFER_D` period offers of `bid_types` to their `BIDDAYOFFER_D` price bands,
one row per `(SETTLEMENTDATE, DUID, DIRECTION, INTERVAL_DATETIME)` with
`start_date <= INTERVAL_DATETIME < end_date`. With a `resolution`, quantities are averaged within
each ceiled bucket. Throws an `ArgumentError` naming the units whose period offers have no price
bands.

# Returns
A `DataFrame` with `SETTLEMENTDATE`, `DUID`, `DIRECTION`, `INTERVAL_DATETIME`, `PRICEBANDARRAY`,
`BANDAVAILARRAY`, `MAXAVAIL`, `MINIMUMLOAD`, `DAILYENERGYCONSTRAINT`, and `BIDTYPE` when
`keep_bid_type`. Native-resolution requests can also project `period_columns` from the same
latest period rows. With `in_force`, at native resolution only, the `MINIMUMLOAD` and `T1` to `T4`
of energy rows come from the `BIDDAYOFFER` version in force at the period offer's `LASTCHANGED`
([`read_offers`](@ref)).
"""
function _massage_bids(
        db, start_date, end_date;
        resolution::Union{Nothing, Dates.Period} = nothing, bid_types::AbstractVector{BidType} = [BidType.ENERGY],
        keep_bid_type::Bool = false, period_columns::AbstractVector{<:AbstractString} = String[],
        extra_price_columns::AbstractVector{<:AbstractString} = String[], in_force::Bool = false,
    )
    (isempty(period_columns) && !in_force) || isnothing(resolution) ||
        throw(ArgumentError("additional period columns require native resolution"))
    window = (start_date - Day(1), end_date + Day(1))
    period_source = read_hive(db, :BIDPEROFFER_D, window)
    price_source = read_hive(db, :BIDDAYOFFER_D, window)
    bid_types_sql = _bid_type_list(bid_types)
    # Explicit band lists, since `COLUMNS(regex)` follows file column order rather than band number.
    band_avail = join(_band_columns(_table_schema(db, period_source), "BANDAVAIL"), ", ")
    price_bands = join(_band_columns(_table_schema(db, price_source), "PRICEBAND"), ", ")
    bucket = isnothing(resolution) ? "INTERVAL_DATETIME" : _ceil_timestamp_sql("INTERVAL_DATETIME", resolution)
    missing_value = isnothing(resolution) ? "NULL" : "'NaN'::DOUBLE"
    period_extra = join((", $c" for c in [period_columns; in_force ? ["LASTCHANGED"] : String[]]))
    price_extra = join((", $c" for c in extra_price_columns))
    days = _offer_days(start_date, end_date)
    lower = isnothing(resolution) ? start_date : start_date - resolution

    bids = _query(
        db,
        """
        WITH latest_period AS (
            SELECT SETTLEMENTDATE, INTERVAL_DATETIME, DUID, DIRECTION, BIDTYPE,
                   MAXAVAIL, $band_avail $period_extra
            FROM $period_source
            WHERE BIDTYPE IN ($bid_types_sql) AND SETTLEMENTDATE BETWEEN ? AND ?
              AND INTERVAL_DATETIME >= ? AND INTERVAL_DATETIME < ?
            QUALIFY row_number() OVER (
                PARTITION BY SETTLEMENTDATE, INTERVAL_DATETIME, DUID, DIRECTION, BIDTYPE ORDER BY VERSIONNO DESC
            ) = 1
        ),
        period AS (
            SELECT SETTLEMENTDATE, $bucket AS INTERVAL_DATETIME, DUID, DIRECTION, BIDTYPE $period_extra,
                   COALESCE(avg(COLUMNS('^(MAXAVAIL|BANDAVAIL\\d+)\$')), $missing_value)
            FROM latest_period
            GROUP BY ALL
        ),
        prices AS (
            SELECT SETTLEMENTDATE, DUID, DIRECTION, BIDTYPE, MINIMUMLOAD, DAILYENERGYCONSTRAINT $price_extra,
                   list_value($price_bands) AS PRICEBANDARRAY
            FROM $price_source
            WHERE BIDTYPE IN ($bid_types_sql) AND SETTLEMENTDATE BETWEEN ? AND ?
            QUALIFY row_number() OVER (
                PARTITION BY SETTLEMENTDATE, DUID, DIRECTION, BIDTYPE ORDER BY VERSIONNO DESC
            ) = 1
        )
        SELECT SETTLEMENTDATE, DUID, DIRECTION, INTERVAL_DATETIME, PRICEBANDARRAY,
               list_value($band_avail) AS BANDAVAILARRAY,
               MAXAVAIL, MINIMUMLOAD, DAILYENERGYCONSTRAINT $price_extra, BIDTYPE $period_extra,
               d.DUID IS NULL AS MISSING_PRICE
        FROM period p
        LEFT JOIN prices d USING (SETTLEMENTDATE, DUID, DIRECTION, BIDTYPE)
        WHERE INTERVAL_DATETIME >= ? AND INTERVAL_DATETIME < ?
        ORDER BY SETTLEMENTDATE, INTERVAL_DATETIME, DUID, DIRECTION, BIDTYPE
        """,
        [days; lower; end_date; days; start_date; end_date],
    )

    missing_duids = @chain bids begin
        subset(:MISSING_PRICE)
        unique(_.DUID)
        sort
    end
    isempty(missing_duids) || throw(
        ArgumentError(
            "missing price bids for period offers: $(join(missing_duids, ", ")); populate BIDDAYOFFER_D for the referenced trading days",
        ),
    )
    in_force && _apply_in_force!(db, bids, start_date, end_date)
    keep_bid_type || select!(bids, Not(:BIDTYPE))
    return select!(bids, Not(:MISSING_PRICE))
end


const _OFFER_KEYS = [:SETTLEMENTDATE, :DUID, :DIRECTION, :BIDTYPE]
const _IN_FORCE_COLUMNS = ["MINIMUMLOAD", "T1", "T2", "T3", "T4"]

# Replaces `MINIMUMLOAD` and `T1` to `T4` of energy rows with the `BIDDAYOFFER` version in force at each
# row's `LASTCHANGED`, then drops `LASTCHANGED`.
function _apply_in_force!(db, bids, start_date, end_date)
    source = read_hive(db, :BIDDAYOFFER, (start_date - Day(1), end_date + Day(1)))
    offer_keys = unique(select(bids, [_OFFER_KEYS; :LASTCHANGED]))
    versions = _with_registered(db, offer_keys, "offer_keys") do
        _query(
            db,
            """
            WITH versions AS (
                SELECT SETTLEMENTDATE, DUID, DIRECTION, BIDTYPE, OFFERDATE, MINIMUMLOAD, T1, T2, T3, T4
                FROM $source
                WHERE BIDTYPE = 'ENERGY' AND SETTLEMENTDATE BETWEEN ? AND ?
                QUALIFY row_number() OVER (
                    PARTITION BY SETTLEMENTDATE, DUID, DIRECTION, OFFERDATE ORDER BY VERSIONNO DESC
                ) = 1
            )
            SELECT k.*, f.MINIMUMLOAD AS MINIMUMLOAD_in_force, f.T1 AS T1_in_force, f.T2 AS T2_in_force,
                   f.T3 AS T3_in_force, f.T4 AS T4_in_force, true AS IN_FORCE
            FROM offer_keys k
            ASOF JOIN versions f
                ON f.SETTLEMENTDATE = k.SETTLEMENTDATE AND f.DUID = k.DUID AND f.DIRECTION = k.DIRECTION
               AND f.BIDTYPE = k.BIDTYPE AND k.LASTCHANGED >= f.OFFERDATE
            """,
            _offer_days(start_date, end_date),
        )
    end
    replaced = filter(c -> hasproperty(bids, c), _IN_FORCE_COLUMNS)
    @chain bids begin
        leftjoin!(versions; on = [_OFFER_KEYS; :LASTCHANGED])
        transform!(
            [
                [c, "$(c)_in_force", "IN_FORCE"] =>
                    ByRow((day, version, found) -> coalesce(found, false) ? version : day) => c
                    for c in replaced
            ]...,
        )
        select!(Not(["LASTCHANGED"; "IN_FORCE"; _IN_FORCE_COLUMNS .* "_in_force"]))
    end
    return bids
end
