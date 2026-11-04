"""
    compare_intervals(published::NamedTuple, solved::NamedTuple) -> NamedTuple

Joins the published outcome of a set of intervals onto its solved outcome, one row per published key.
Solved values a model does not produce are `missing`.

# Arguments
- `published`: the outcome from [`read_published_interval`](@ref) over the intervals.
- `solved`: the outcome from [`read_solved_interval`](@ref) over the same intervals.

# Returns
A named tuple of `DataFrame`s keyed as `solved`: `prices` (by `REGIONID`), `dispatch` (by `DUID`),
`interconnectors` (by `INTERCONNECTORID`) and `fcas_prices` (by `REGIONID` and `BIDTYPE`). Each has
the published and solved values in `<column>_published` and `<column>_solved`, sorted by
`SETTLEMENTDATE` and its key.
"""
function compare_intervals(published::NamedTuple, solved::NamedTuple)
    _compare_table(table::Symbol, key::Symbol) = sort!(
        leftjoin(
            published[table], solved[table];
            on = [:SETTLEMENTDATE, key], renamecols = "_published" => "_solved",
        ),
        [:SETTLEMENTDATE, key],
    )
    fcas_prices = leftjoin(
        select(published.fcas_prices, :SETTLEMENTDATE, :REGIONID, :BIDTYPE, :ROP),
        solved.fcas_prices; on = [:SETTLEMENTDATE, :REGIONID, :BIDTYPE], renamecols = "_published" => "_solved",
    )
    return (;
        prices = _compare_table(:prices, :REGIONID),
        dispatch = _compare_table(:dispatch, :DUID),
        interconnectors = _compare_table(:interconnectors, :INTERCONNECTORID),
        fcas_prices = sort!(fcas_prices, [:SETTLEMENTDATE, :REGIONID, :BIDTYPE]),
    )
end


"""
    comparison_summary(comparison::NamedTuple) -> DataFrame

Summarises the paired solved and published values of each table of a [`compare_intervals`](@ref)
result, one row per metric: `energy_price`, `dispatch_mw`, `interconnector_flow_mw`,
`interconnector_losses_mw` and `fcas_price`.

# Arguments
- `comparison`: the named tuple returned by [`compare_intervals`](@ref).

# Returns
A `DataFrame` with columns `metric`, `n_rows`, `n_paired`, `n_missing`, `n_nonfinite`, `mae`, `rmse`,
`max_abs_gap` and `bias`. Rows with a `missing` or non-finite side are counted and left out of the
error statistics, which are `missing` when no row pairs. `bias` is the mean solved minus published.
"""
function comparison_summary(comparison::NamedTuple)
    rows = NamedTuple[]
    for (metric, table, solved, published) in (
            ("energy_price", :prices, :ROP_solved, :ROP_published),
            ("dispatch_mw", :dispatch, :TOTALCLEARED_solved, :TOTALCLEARED_published),
            ("interconnector_flow_mw", :interconnectors, :MWFLOW_solved, :MWFLOW_published),
            ("interconnector_losses_mw", :interconnectors, :MWLOSSES_solved, :MWLOSSES_published),
            ("fcas_price", :fcas_prices, :ROP_solved, :ROP_published),
        )
        frame = comparison[table]
        gaps = Float64[]
        n_missing, n_nonfinite = 0, 0
        for (a, b) in zip(frame[!, solved], frame[!, published])
            if ismissing(a) || ismissing(b)
                n_missing += 1
            elseif !isfinite(a) || !isfinite(b)
                n_nonfinite += 1
            else
                push!(gaps, a - b)
            end
        end
        paired = length(gaps)
        push!(
            rows, (;
                metric, n_rows = nrow(frame), n_paired = paired, n_missing, n_nonfinite,
                mae = paired == 0 ? missing : sum(abs, gaps) / paired,
                rmse = paired == 0 ? missing : sqrt(sum(abs2, gaps) / paired),
                max_abs_gap = paired == 0 ? missing : maximum(abs, gaps),
                bias = paired == 0 ? missing : sum(gaps) / paired,
            )
        )
    end
    return DataFrame(rows)
end
