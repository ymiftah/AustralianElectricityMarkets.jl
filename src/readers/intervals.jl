"""
    read_published_interval(db, settlement_date; intervention = 0)
    read_published_interval(db, steps::StepRange{DateTime}; intervention = 0)

Reads AEMO's published outcome for one dispatch interval, or for every interval of `steps` in one
query per table.

# Arguments
- `db`: an `AEMDB` connection.
- `settlement_date`: the `SETTLEMENTDATE` of the interval (`DateTime`).
- `steps`: the `SETTLEMENTDATE`s of consecutive intervals, stepping by 5 minutes.
- `intervention`: 0 for the pricing run, 1 for the physical run.

# Returns
A `NamedTuple` of `DataFrame`s: `dispatch` (`DUID`, `TOTALCLEARED`), `interconnectors`
(`INTERCONNECTORID`, `MWFLOW`, `MWLOSSES`), `prices` (`REGIONID`, `RRP`, `ROP`) and `fcas_prices`
(`SETTLEMENTDATE`, `REGIONID`, `BIDTYPE`, `RRP`, `ROP`). For `steps`, every table has a leading
`SETTLEMENTDATE` column, and the rows at each interval are those of the single-interval method.
"""
function read_published_interval(db, settlement_date::DateTime; intervention::Integer = 0)
    published = read_published_interval(db, settlement_date:Minute(5):settlement_date; intervention)
    return (;
        dispatch = select(published.dispatch, Not(:SETTLEMENTDATE)),
        interconnectors = select(published.interconnectors, Not(:SETTLEMENTDATE)),
        prices = select(published.prices, Not(:SETTLEMENTDATE)),
        fcas_prices = published.fcas_prices,
    )
end

function read_published_interval(db, steps::StepRange{DateTime}; intervention::Integer = 0)
    interval = first(steps):Minute(5):(last(steps) + Minute(5))
    published(table, key, columns) = _read_dispatch_table(
        [_cast_double(c) for c in columns], db, table, key, interval; intervention,
    )
    return (;
        dispatch = published(:DISPATCHLOAD, "DUID", ("TOTALCLEARED",)),
        interconnectors = published(:DISPATCHINTERCONNECTORRES, "INTERCONNECTORID", ("MWFLOW", "MWLOSSES")),
        prices = select(read_prices(db, interval; intervention), :SETTLEMENTDATE, :REGIONID, :RRP, :ROP),
        fcas_prices = select(
            read_fcas_prices(db, interval; intervention), :SETTLEMENTDATE, :REGIONID, :BIDTYPE, :RRP, :ROP,
        ),
    )
end
