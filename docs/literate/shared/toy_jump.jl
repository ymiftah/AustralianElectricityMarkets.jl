# The JuMP model of `nemde_jump` as one function, so that later pages can solve the same problem
# and compare. It reads the energy data from the toy `System` and `nemde_jump` builds it step by
# step and asserts that it agrees.

using JuMP
using HiGHS

"""
    solve_toy_jump(sys, market; fcas = true) -> NamedTuple

Builds and solves the toy market's NEMDE model in one go: dispatch, flow, loss, regional
prices, FCAS requirement duals and generic constraint duals, all per MWh. The energy data comes
from the `System` `sys` and the losses, FCAS offers and generic constraints from `market`. With
`fcas = false` the FCAS variables and rows are left out.
"""
function solve_toy_jump(sys::PSY.System, market::Market; fcas::Bool = true)
    ic = market.interconnector
    segments = linearised_losses(ic)
    names = generator_names(sys)
    bands = Dict(n => offer_bids(sys, n) for n in names)
    env = Dict(n => envelope(sys, n) for n in names)
    regions = region_names(sys)
    from = PSY.get_name(PSY.get_from_area(interconnector(sys)))
    max_flow = flow_limit(sys)
    model = Model(HiGHS.Optimizer)
    set_silent(model)
    @variable(model, 0 <= cleared[n in names, j in eachindex(bands[n])] <= quantity(bands[n][j]))
    @expression(model, dispatch[n in names], sum(cleared[n, j] for j in eachindex(bands[n])))
    @constraint(model, [n in names], dispatch[n] >= env[n][1])
    @constraint(model, [n in names], dispatch[n] <= env[n][2])
    @variable(model, flow)
    @variable(model, 0 <= segment_flow[s in eachindex(segments)] <= segments[s].to_mw - segments[s].from_mw)
    @variable(model, filled[s in 1:(length(segments) - 1)], Bin)
    @expression(model, loss, loss_at(ic, ic.breakpoints[1]) - zero_flow_chord_loss(ic) + sum(segments[s].slope * segment_flow[s] for s in eachindex(segments)))
    @constraint(model, flow == ic.breakpoints[1] + sum(segment_flow))
    @constraint(model, [s in 1:(length(segments) - 1)], segment_flow[s] >= (segments[s].to_mw - segments[s].from_mw) * filled[s])
    @constraint(model, [s in 1:(length(segments) - 1)], segment_flow[s + 1] <= (segments[s + 1].to_mw - segments[s + 1].from_mw) * filled[s])
    @constraint(model, -max_flow <= flow <= max_flow)
    exported(r) = r == from ? flow : -flow
    loss_charged(r) = (r == from ? ic.from_loss_share : 1 - ic.from_loss_share) * loss
    @constraint(
        model, balance[r in regions],
        sum(dispatch[n] for n in units_in(sys, r)) - exported(r) - loss_charged(r) == region_demand(sys, r)
    )
    if fcas
        fnames = fcas_names(market)
        @variable(model, 0 <= raise[n in fnames] <= max_avail(trapezium(market, n)))
        @variable(model, 0 <= raise_cleared[n in fnames, j in eachindex(fcas_bids(market, n))] <= quantity(fcas_bids(market, n)[j]))
        @constraint(model, [n in fnames], raise[n] == sum(raise_cleared[n, j] for j in eachindex(fcas_bids(market, n))))
        @constraint(model, [n in fnames], dispatch[n] + upper_slope(trapezium(market, n)) * raise[n] <= trapezium(market, n).enablement_max)
        @constraint(model, [n in fnames], dispatch[n] - lower_slope(trapezium(market, n)) * raise[n] >= trapezium(market, n).enablement_min)
    end
    cost = sum(price(bands[n][j]) * cleared[n, j] * INTERVAL_H for n in names for j in eachindex(bands[n]))
    fcas && (cost += sum(price(b) * raise_cleared[n, j] * INTERVAL_H for n in fcas_names(market) for (j, b) in enumerate(fcas_bids(market, n))))
    generic = Dict{String, ConstraintRef}()
    for gc in market.constraints
        lhs = sum(
            t.factor * (t.kind == :energy ? dispatch[String(t.id)] : raise[String(t.id)])
                for t in gc.terms
        )
        violation = @variable(model, lower_bound = 0)
        generic[gc.name] = gc.sense == :LE ? @constraint(model, lhs - violation <= gc.rhs) : @constraint(model, lhs + violation >= gc.rhs)
        cost += gc.weight * MARKET_PRICE_CAP * INTERVAL_H * violation
    end
    @objective(model, Min, cost)
    optimize!(model)
    @assert termination_status(model) == OPTIMAL
    undo = fix_discrete_variables(model)
    optimize!(model)
    result = (;
        dispatch = Dict(Symbol(n) => value(dispatch[n]) for n in names),
        flow = value(flow), loss = value(loss),
        price = Dict(r => dual(balance[r]) / INTERVAL_H for r in regions),
        generic = Dict(n => dual(c) / INTERVAL_H for (n, c) in generic),
        objective = objective_value(model),
    )
    undo()
    return result
end
