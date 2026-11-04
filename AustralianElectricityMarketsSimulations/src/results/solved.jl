import AustralianElectricityMarkets: read_prices, read_fcas_prices

# PSI ignores a failed dual LP and leaves the duals NaN, so check them before reporting prices.
function _check_prices_finite(prices::DataFrame)
    bad = prices[.!isfinite.(prices.ROP), :]
    isempty(bad) || error(
        "Interval $(minimum(bad.SETTLEMENTDATE)) has non-finite regional price duals; the dual pass failed.",
    )
    return
end


"""
    read_prices(results, sys::PSY.System) -> DataFrame

Reads the solved regional prices of a PSI model from the duals of its `CopperPlateBalanceConstraint`
rows, one row per region and interval. The dual is per unit of interval energy, so it is divided by the
base power and the interval length to give `\$/MWh`. Throws when a price is not finite.

# Arguments
- `results`: `PSI.OptimizationProblemResults` of a model, or `PSI.SimulationProblemResults` of a
  simulation (its realized duals).
- `sys`: the `System` the model was built from.

# Returns
A `DataFrame` with `SETTLEMENTDATE`, `REGIONID` and `ROP`, the same columns as the `prices` of
[`read_published_interval`](@ref).
"""
function read_prices(
        results::Union{PSI.OptimizationProblemResults, PSI.SimulationProblemResults}, sys::PSY.System,
    )
    scale = PSY.get_base_power(sys) * interval_hours(DISPATCH_INTERVAL)
    prices = @chain _read_balance_duals(results) begin
        select(:DateTime => :SETTLEMENTDATE, :name => :REGIONID, :value => ByRow(v -> v / scale) => :ROP)
    end
    _check_prices_finite(prices)
    return prices
end


"""
    read_fcas_prices(results, sys::PSY.System; resolution = nothing) -> DataFrame

Maps solved [`NEMConstraintLimit`](@ref) duals onto regional FCAS prices: each `(region, service)`
`ROP` is the sum of the duals of every built [`GenericConstraint`](@ref) whose
[`get_fcas_requirements`](@ref) names that pair, in `\$/MWh`. This mirrors the sum of
`DISPATCH_FCAS_REQ`'s `MARGINALVALUE` in the published FCAS prices. Duals keep the solver's
sign (change in cost per unit increase of the right-hand side): non-negative for a binding `>=`
constraint, non-positive for `<=`. Warns when a constraint with requirements has no recorded dual.

# Arguments
- `results`: `PSI.OptimizationProblemResults` of a model, or `PSI.SimulationProblemResults` of a
  simulation (its realized duals), that recorded `NEMConstraintLimit` duals.
- `sys`: the `System` the model was built from.
- `resolution`: interval length converting per-interval duals to `\$/MWh`. Defaults to the
  resolution the results record, which a single-interval solve does not; required then.

# Returns
A `DataFrame` with `SETTLEMENTDATE`, `REGIONID`, `BIDTYPE` and `ROP`, the same columns as
[`read_published_interval`](@ref) reports for FCAS prices.
"""
function read_fcas_prices(
        results::Union{PSI.OptimizationProblemResults, PSI.SimulationProblemResults}, sys::PSY.System;
        resolution::Union{Nothing, Dates.Period} = nothing,
    )
    resolution = something(resolution, PSI.get_resolution(results), Some(nothing))
    isnothing(resolution) && throw(
        ArgumentError(
            "read_fcas_prices: `results` do not record a resolution (a single-interval model), so pass `resolution` explicitly.",
        ),
    )
    dual_keys = Dict(
        k.meta => k for k in PSI.list_dual_keys(results) if PSI.IS.Optimization.get_entry_type(k) === NEMConstraintLimit
    )
    scale = PSY.get_base_power(sys) * interval_hours(resolution)
    prices = Dict{Tuple{String, BidType}, DataFrame}()
    constrained = [gc for gc in PSY.get_components(GenericConstraint, sys) if !isempty(get_fcas_requirements(gc))]
    unrecorded = [PSY.get_name(gc) for gc in constrained if !haskey(dual_keys, PSY.get_name(gc))]
    recorded = [gc for gc in constrained if haskey(dual_keys, PSY.get_name(gc))]
    duals = _read_dual_frames(results, [dual_keys[PSY.get_name(gc)] for gc in recorded])
    for gc in recorded
        dual = duals[dual_keys[PSY.get_name(gc)]]
        for req in get_fcas_requirements(gc)
            id = (get_region(req), get_service(req))
            term = DataFrame(; SETTLEMENTDATE = dual.DateTime, ROP = dual.value ./ scale)
            haskey(prices, id) ? (prices[id].ROP .+= term.ROP) : (prices[id] = term)
        end
    end
    isempty(unrecorded) || @warn(
        "read_fcas_prices: $(length(unrecorded)) GenericConstraint(s) with FCAS requirements " *
            "have no NEMConstraintLimit dual and are left out: $(join(first(sort!(unrecorded), 5), ", "))" *
            (length(unrecorded) > 5 ? ", ..." : ".")
    )
    out = DataFrame(; SETTLEMENTDATE = DateTime[], REGIONID = String[], BIDTYPE = BidType[], ROP = Float64[])
    for ((region, service), df) in sort!(collect(prices); by = p -> (p[1][1], string(p[1][2])))
        append!(out, DataFrame(; SETTLEMENTDATE = df.SETTLEMENTDATE, REGIONID = region, BIDTYPE = service, ROP = df.ROP))
    end
    return out
end


"""
    read_solved_interval(results, sys::PSY.System) -> NamedTuple

Reads the solved outcome of a PSI model over every interval of `results`, in the keys and columns of
[`read_published_interval`](@ref) so that solved and published outcomes compare by a join. Solved
prices carry `ROP` only, with no `RRP`.

# Arguments
- `results`: `PSI.OptimizationProblemResults` of a model, or `PSI.SimulationProblemResults` of a
  simulation, whose realized values are read.
- `sys`: the `System` the model was built from.

# Returns
A named tuple of `DataFrame`s:
- `prices`: `SETTLEMENTDATE`, `REGIONID`, `ROP`, from [`read_prices`](@ref).
- `dispatch`: `SETTLEMENTDATE`, `DUID`, `TOTALCLEARED`, the net MW of each unit.
- `interconnectors`: `SETTLEMENTDATE`, `INTERCONNECTORID`, `MWFLOW`, `MWLOSSES`; empty when the
  results hold no `FlowActivePowerVariable` for `PSY.AreaInterchange`.
- `fcas_prices`: `SETTLEMENTDATE`, `REGIONID`, `BIDTYPE`, `ROP`, from [`read_fcas_prices`](@ref).

Throws when a regional price is not finite, or when the results hold interchange flows but no
`InterconnectorLossVariable`.
"""
function read_solved_interval(results, sys::PSY.System)
    keys_of(T, C) = [
        k for k in PSI.list_variable_keys(results)
            if PSI.IS.Optimization.get_entry_type(k) === T && (isnothing(C) || PSI.IS.Optimization.get_component_type(k) === C)
    ]
    flow_keys = keys_of(PSI.FlowActivePowerVariable, PSY.AreaInterchange)
    loss_keys = keys_of(InterconnectorLossVariable, PSY.AreaInterchange)
    isempty(flow_keys) || !isempty(loss_keys) || throw(
        ArgumentError("read_solved_interval: the results hold AreaInterchange flows but no InterconnectorLossVariable."),
    )
    interchange_keys = isempty(flow_keys) ? PSI.VariableKey[] : [only(flow_keys); only(loss_keys)]
    dispatch_keys = PSI.VariableKey[k for T in keys(_DISPATCH_SIGNS) for k in keys_of(T, nothing)]
    frames = _read_variable_frames(results, [dispatch_keys; interchange_keys])

    prices = read_prices(results, sys)
    signed = [transform(frames[k], :value => (v -> _DISPATCH_SIGNS[PSI.IS.Optimization.get_entry_type(k)] .* v) => :value) for k in dispatch_keys]
    dispatch = @chain reduce(vcat, signed; init = DataFrame(DateTime = DateTime[], name = String[], value = Float64[])) begin
        groupby([:DateTime, :name])
        combine(:value => sum => :TOTALCLEARED)
        rename(:DateTime => :SETTLEMENTDATE, :name => :DUID)
    end
    interconnectors = if isempty(interchange_keys)
        DataFrame(SETTLEMENTDATE = DateTime[], INTERCONNECTORID = String[], MWFLOW = Float64[], MWLOSSES = Union{Missing, Float64}[])
    else
        flow, loss = (rename(frames[k], :value => c) for (k, c) in zip(interchange_keys, (:MWFLOW, :MWLOSSES)))
        @chain flow begin
            leftjoin(loss; on = [:DateTime, :name])
            rename(:DateTime => :SETTLEMENTDATE, :name => :INTERCONNECTORID)
        end
    end
    fcas_prices = read_fcas_prices(results, sys; resolution = DISPATCH_INTERVAL)
    return (; prices, dispatch, interconnectors, fcas_prices)
end
