# `DISPATCHPRICE` columns `<prefix>RRP`, `<prefix>ROP` and, when cached, `<prefix>APCFLAG`.
function _price_columns(schema, prefix::AbstractString)
    rrp, rop, apc = "$(prefix)RRP", "$(prefix)ROP", "$(prefix)APCFLAG"
    cols = [_cast_double(rrp), _cast_double(rop)]
    apc in schema && push!(cols, "TRY_CAST($apc AS INTEGER) AS $apc")
    return cols
end


# One market's `SETTLEMENTDATE`, `REGIONID`, `RRP`, `ROP`, `APCFLAG` (`missing` when not cached).
function _price_block(df, prefix::AbstractString)
    apc = "$(prefix)APCFLAG"
    block = select(df, :SETTLEMENTDATE, :REGIONID, "$(prefix)RRP" => :RRP, "$(prefix)ROP" => :ROP)
    block[!, :APCFLAG] = apc in names(df) ? df[!, apc] : fill(missing, nrow(block))
    return block
end


"""
    read_prices(db, date_range; intervention = 0)

Reads per-interval, per-region **energy** spot prices from `DISPATCHPRICE`: one row per
`(SETTLEMENTDATE, REGIONID)` with `RRP`, `ROP`, `APCFLAG`. `RRP` is the settlement price and `ROP`
the price before scaling, capping or VoLL override; they differ exactly when `APCFLAG != 0` (an
administered price cap event). See [`read_fcas_prices`](@ref) for the FCAS markets.

# Arguments
- `db`: an `AEMDB` connection.
- `date_range`: the dispatch intervals to read (half-open: `start <= t < stop`).
- `intervention`: `0` for the pricing run, `1` for the physical run.

# Returns
A `DataFrame` with `SETTLEMENTDATE`, `REGIONID`, `RRP`, `ROP` and `APCFLAG` (`missing` for cached
partitions without the column).
"""
function read_prices(db, date_range; intervention::Integer = 0)
    df = _read_dispatch_table(schema -> _price_columns(schema, ""), db, :DISPATCHPRICE, "REGIONID", date_range; intervention)
    return _price_block(df, "")
end


"""
    read_fcas_prices(db, date_range; intervention = 0)

Reads per-interval, per-region FCAS clearing prices from `DISPATCHPRICE`, long-format: one row per
`(SETTLEMENTDATE, REGIONID, BIDTYPE::BidType)` with `RRP`, `ROP`, `APCFLAG`. Summing
[`read_fcas_requirements`](@ref)'s `MARGINALVALUE` per `(REGIONID, BIDTYPE)` reproduces `ROP` for
that interval (not `RRP`, which may additionally be capped).

# Arguments
- `db`: an `AEMDB` connection.
- `date_range`: the dispatch intervals to read (half-open: `start <= t < stop`).
- `intervention`: `0` for the pricing run, `1` for the physical run.

# Returns
A `DataFrame` with `SETTLEMENTDATE`, `REGIONID`, `RRP`, `ROP`, `APCFLAG` and `BIDTYPE`. Markets
without cached price columns are absent; `APCFLAG` is `missing` where its column is not cached.
"""
function read_fcas_prices(db, date_range; intervention::Integer = 0)
    markets = string.(FCAS_BID_TYPES)
    cached(schema, market) = all(in(schema), ("$(market)RRP", "$(market)ROP"))
    df = _read_dispatch_table(db, :DISPATCHPRICE, "REGIONID", date_range; intervention) do schema
        return reduce(vcat, (_price_columns(schema, m) for m in markets if cached(schema, m)); init = String[])
    end
    long = DataFrame()
    for (bid_type, market) in zip(FCAS_BID_TYPES, markets)
        "$(market)RRP" in names(df) || continue
        block = _price_block(df, market)
        block[!, :BIDTYPE] = fill(bid_type, nrow(block))
        append!(long, block; promote = true)
    end
    return long
end
