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
    read_loss_factors(db, date_range) -> DataFrame

Reads each unit's connection-point loss factors from the earliest `DUDETAILSUMMARY` row (latest
archive) registered at some dispatch interval of `date_range`, the row [`read_units`](@ref) keeps.
Warns when a unit's factors differ between its rows in the range, since the result holds one
factor per unit.

# Arguments
- `db`: the database connection.
- `date_range`: the half-open range of interval-ending stamps; the last interval is
  `last(date_range) - Minute(5)`.

# Returns
A `DataFrame` with `DUID`, `GEN_LOSS_FACTOR` (`SECONDARY_TLF * DISTRIBUTIONLOSSFACTOR` for a
`BIDIRECTIONAL` unit that publishes a secondary factor, else `LOAD_LOSS_FACTOR`) and
`LOAD_LOSS_FACTOR` (`TRANSMISSIONLOSSFACTOR * DISTRIBUTIONLOSSFACTOR`, the factor for a load or a
battery's charging side).
"""
function read_loss_factors(db, date_range)
    as_of, through = DateTime(first(date_range)), DateTime(last(date_range)) - Minute(5)
    source = read_hive(db, :DUDETAILSUMMARY)
    factors = _query(
        db,
        """
        WITH registered AS (
            SELECT * FROM $source
            WHERE archive_month = (SELECT max(archive_month) FROM $source)
              AND START_DATE < ? AND (END_DATE IS NULL OR END_DATE >= ?)
        ),
        -- NULL counts as a value, so a NULL to number change in SECONDARY_TLF is caught.
        changed AS (
            SELECT DUID,
                   count(DISTINCT TRANSMISSIONLOSSFACTOR) > 1
                       OR count(DISTINCT DISTRIBUTIONLOSSFACTOR) > 1
                       OR count(DISTINCT coalesce(CAST(SECONDARY_TLF AS VARCHAR), 'NULL')) > 1 AS FACTORS_CHANGE
            FROM registered
            GROUP BY DUID
        )
        SELECT DUID,
               CASE WHEN DISPATCHTYPE = 'BIDIRECTIONAL' AND SECONDARY_TLF IS NOT NULL
                    THEN SECONDARY_TLF * DISTRIBUTIONLOSSFACTOR
                    ELSE TRANSMISSIONLOSSFACTOR * DISTRIBUTIONLOSSFACTOR END AS GEN_LOSS_FACTOR,
               TRANSMISSIONLOSSFACTOR * DISTRIBUTIONLOSSFACTOR AS LOAD_LOSS_FACTOR,
               FACTORS_CHANGE
        FROM registered
        JOIN changed USING (DUID)
        QUALIFY row_number() OVER (PARTITION BY DUID ORDER BY START_DATE ASC) = 1
        """,
        [through, as_of],
    )
    changed = subset(factors, :FACTORS_CHANGE).DUID
    isempty(changed) ||
        @warn "Loss factors change within the date range; the factors of each unit's earliest registration row overlapping it are used throughout" as_of through first_changed = first(changed, 5)
    return select!(factors, Not(:FACTORS_CHANGE))
end


"""
    read_bids(db, date_range; resolution = nothing)

Reads energy offers from `BIDPEROFFER_D`/`BIDDAYOFFER_D`: one row per
`(SETTLEMENTDATE, DUID, DIRECTION, INTERVAL_DATETIME)` with `PRICEBANDARRAY` (connection-point
prices, not referred to the reference node), `BANDAVAILARRAY` (MW), `MAXAVAIL`, `MINIMUMLOAD` and
`DAILYENERGYCONSTRAINT`. With a `resolution`, the offers of each bucket are averaged
(`INTERVAL_DATETIME` ceiled onto it). See [`read_fcas_bids`](@ref) for the FCAS markets.
"""
function read_bids(db, date_range; resolution::Union{Nothing, Dates.Period} = nothing)
    resolution = something(resolution, Minute(5))
    start, stop = DateTime(first(date_range)), DateTime(last(date_range))
    return @chain read_offers(db, (start - (resolution - Minute(5)), stop); markets = (BidType.ENERGY,)) begin
        _aggregate_offers(resolution, (start, stop))
        select(
            :SETTLEMENTDATE, :DUID, :DIRECTION, :INTERVAL_DATETIME, :PRICEBANDARRAY, :BANDAVAILARRAY,
            :MAXAVAIL, :MINIMUMLOAD, :DAILYENERGYCONSTRAINT,
        )
    end
end


# An empty `BIDDAYOFFER` relation, read in place of the table when no energy offer is read.
const _NO_OFFER_VERSIONS = """(
    SELECT NULL::TIMESTAMP AS SETTLEMENTDATE, NULL::VARCHAR AS DUID, NULL::VARCHAR AS DIRECTION,
           NULL::VARCHAR AS BIDTYPE, NULL::TIMESTAMP AS OFFERDATE, NULL::DOUBLE AS MINIMUMLOAD,
           NULL::DOUBLE AS T1, NULL::DOUBLE AS T2, NULL::DOUBLE AS T3, NULL::DOUBLE AS T4,
           NULL::BIGINT AS VERSIONNO
    WHERE false
)"""


"""
    read_offers(db, date_range; markets = NEM_MARKETS) -> DataFrame

Reads the latest energy and FCAS offers of `markets` in one query: `BIDPEROFFER_D` period offers
joined to their `BIDDAYOFFER_D` price bands, at native resolution. Each row is one
`(SETTLEMENTDATE, INTERVAL_DATETIME, DUID, DIRECTION, BIDTYPE)` with
`first(date_range) <= INTERVAL_DATETIME < last(date_range)`. The `MINIMUMLOAD` and `T1` to `T4` of an
energy row come from the `BIDDAYOFFER` version in force at the interval: the latest
`BIDDAYOFFER.OFFERDATE` at or before the period offer's `LASTCHANGED`, NULL fields included. Rows
without such a version keep the `BIDDAYOFFER_D` values. `BIDDAYOFFER` is read only when `markets`
includes `BidType.ENERGY`.

# Arguments
- `db`: an `AEMDB` connection.
- `date_range`: the intervals to read (half-open).
- `markets`: the `BidType` values to read, default `NEM_MARKETS`.

# Returns
A `DataFrame` sorted by `SETTLEMENTDATE`, `INTERVAL_DATETIME`, `DUID`, `DIRECTION` and `BIDTYPE`, with
those columns, `BIDTYPE` (`BidType`), `PRICEBANDARRAY`, `BANDAVAILARRAY`, `MAXAVAIL`, `MINIMUMLOAD`,
`DAILYENERGYCONSTRAINT`, `T1`, `T2`, `T3`, `T4`, `NORMALSTATUS`, `FIXEDLOAD`, `ROCUP`, `ROCDOWN`,
`ENERGYLIMIT`, `ENABLEMENTMIN`, `LOWBREAKPOINT`, `HIGHBREAKPOINT` and `ENABLEMENTMAX`.
Throws an `ArgumentError` when a unit's period offers have no price bands.
"""
function read_offers(db, date_range; markets = NEM_MARKETS)
    start_date, end_date = first(date_range), last(date_range)
    window = (start_date - Day(1), end_date + Day(1))
    period_source = read_hive(db, :BIDPEROFFER_D, window)
    price_source = read_hive(db, :BIDDAYOFFER_D, window)
    # Only energy rows read the in-force version, so an FCAS-only read needs no BIDDAYOFFER.
    version_source = BidType.ENERGY in markets ? read_hive(db, :BIDDAYOFFER, window) : _NO_OFFER_VERSIONS
    band_avail = join(("BANDAVAIL$i" for i in 1:10), ", ")
    price_bands = join(("PRICEBAND$i" for i in 1:10), ", ")
    offers = _query(
        db,
        """
        WITH period AS (
            SELECT SETTLEMENTDATE, INTERVAL_DATETIME, DUID, DIRECTION, BIDTYPE, LASTCHANGED, MAXAVAIL,
                   $band_avail, FIXEDLOAD, ROCUP, ROCDOWN, ENERGYLIMIT,
                   ENABLEMENTMIN, LOWBREAKPOINT, HIGHBREAKPOINT, ENABLEMENTMAX
            FROM $period_source
            WHERE BIDTYPE IN ($(_bid_type_list(markets))) AND SETTLEMENTDATE BETWEEN ? AND ?
              AND INTERVAL_DATETIME >= ? AND INTERVAL_DATETIME < ?
            QUALIFY row_number() OVER (
                PARTITION BY SETTLEMENTDATE, INTERVAL_DATETIME, DUID, DIRECTION, BIDTYPE ORDER BY VERSIONNO DESC
            ) = 1
        ),
        prices AS (
            SELECT SETTLEMENTDATE, DUID, DIRECTION, BIDTYPE, MINIMUMLOAD, DAILYENERGYCONSTRAINT,
                   T1, T2, T3, T4, NORMALSTATUS, list_value($price_bands) AS PRICEBANDARRAY
            FROM $price_source
            WHERE BIDTYPE IN ($(_bid_type_list(markets))) AND SETTLEMENTDATE BETWEEN ? AND ?
            QUALIFY row_number() OVER (
                PARTITION BY SETTLEMENTDATE, DUID, DIRECTION, BIDTYPE ORDER BY VERSIONNO DESC
            ) = 1
        ),
        versions AS (
            SELECT SETTLEMENTDATE, DUID, DIRECTION, BIDTYPE, OFFERDATE, MINIMUMLOAD, T1, T2, T3, T4
            FROM $version_source
            WHERE BIDTYPE = 'ENERGY' AND SETTLEMENTDATE BETWEEN ? AND ?
            QUALIFY row_number() OVER (
                PARTITION BY SETTLEMENTDATE, DUID, DIRECTION, OFFERDATE ORDER BY VERSIONNO DESC
            ) = 1
        )
        SELECT p.SETTLEMENTDATE, p.INTERVAL_DATETIME, p.DUID, p.DIRECTION, p.BIDTYPE,
               d.PRICEBANDARRAY, list_value($band_avail) AS BANDAVAILARRAY, p.MAXAVAIL,
               CASE WHEN v.DUID IS NULL THEN d.MINIMUMLOAD ELSE v.MINIMUMLOAD END AS MINIMUMLOAD,
               d.DAILYENERGYCONSTRAINT,
               CASE WHEN v.DUID IS NULL THEN d.T1 ELSE v.T1 END AS T1,
               CASE WHEN v.DUID IS NULL THEN d.T2 ELSE v.T2 END AS T2,
               CASE WHEN v.DUID IS NULL THEN d.T3 ELSE v.T3 END AS T3,
               CASE WHEN v.DUID IS NULL THEN d.T4 ELSE v.T4 END AS T4, d.NORMALSTATUS,
               p.FIXEDLOAD, p.ROCUP, p.ROCDOWN, p.ENERGYLIMIT,
               p.ENABLEMENTMIN, p.LOWBREAKPOINT, p.HIGHBREAKPOINT, p.ENABLEMENTMAX,
               d.DUID IS NULL AS MISSING_PRICE
        FROM period p
        LEFT JOIN prices d
            ON d.SETTLEMENTDATE = p.SETTLEMENTDATE AND d.DUID = p.DUID
           AND d.DIRECTION = p.DIRECTION AND d.BIDTYPE = p.BIDTYPE
        ASOF LEFT JOIN versions v
            ON v.SETTLEMENTDATE = p.SETTLEMENTDATE AND v.DUID = p.DUID
           AND v.DIRECTION = p.DIRECTION AND v.BIDTYPE = p.BIDTYPE AND p.LASTCHANGED >= v.OFFERDATE
        ORDER BY p.SETTLEMENTDATE, p.INTERVAL_DATETIME, p.DUID, p.DIRECTION, p.BIDTYPE
        """,
        [_offer_days(start_date, end_date); start_date; end_date; _offer_days(start_date, end_date); _offer_days(start_date, end_date)],
    )
    missing_duids = sort(unique(subset(offers, :MISSING_PRICE).DUID))
    isempty(missing_duids) || throw(
        ArgumentError(
            "missing price bids for period offers: $(join(missing_duids, ", ")); populate BIDDAYOFFER_D for the referenced trading days",
        ),
    )
    return @chain offers begin
        select(Not(:MISSING_PRICE))
        transform!(:BIDTYPE => ByRow(BidType) => :BIDTYPE)
    end
end


# SQL list literal of `bid_types`, e.g. `'RAISE6SEC', 'LOWER6SEC'`.
_bid_type_list(bid_types) = join(("'$(string(bt))'" for bt in bid_types), ", ")

# The trading days (`SETTLEMENTDATE`) whose offers can cover intervals from `start_date` to `end_date`.
_offer_days(start_date, end_date) = [Date(start_date) - Day(1), Date(end_date) + Day(1)]


# Averages the five-minute `offers` onto `resolution`, one row per ceiled `INTERVAL_DATETIME`, and keeps the
# buckets inside `date_range`. Quantities are averaged over the bucket's present values, the band
# availabilities element-wise; the price bands and `NORMALSTATUS` come from the bucket's first row
# and the FCAS trapezium from its last.
function _aggregate_offers(offers::DataFrame, resolution::Dates.Period, date_range)
    resolution == Minute(5) && return offers
    keys = [:SETTLEMENTDATE, :INTERVAL_DATETIME, :DUID, :DIRECTION, :BIDTYPE]
    averaged = [:MAXAVAIL, :MINIMUMLOAD, :DAILYENERGYCONSTRAINT, :T1, :T2, :T3, :T4, :FIXEDLOAD, :ROCUP, :ROCDOWN, :ENERGYLIMIT]
    last_of = [:ENABLEMENTMIN, :LOWBREAKPOINT, :HIGHBREAKPOINT, :ENABLEMENTMAX]
    mean_present(x) = all(ismissing, x) ? missing : mean(skipmissing(x))
    # `Ref` keeps an array value in one row of `combine`.
    mean_bands(bands) = Ref([mean_present(getindex.(bands, i)) for i in eachindex(first(bands))])
    return @chain offers begin
        transform(:INTERVAL_DATETIME => ByRow(t -> ceil(t, resolution)) => :INTERVAL_DATETIME)
        groupby(keys)
        combine(
            averaged .=> mean_present .=> averaged,
            :PRICEBANDARRAY => (prices -> Ref(first(prices))) => :PRICEBANDARRAY,
            :NORMALSTATUS => first => :NORMALSTATUS,
            last_of .=> last .=> last_of,
            :BANDAVAILARRAY => mean_bands => :BANDAVAILARRAY,
        )
        subset(:INTERVAL_DATETIME => ByRow(t -> first(date_range) <= t < last(date_range)))
    end
end
