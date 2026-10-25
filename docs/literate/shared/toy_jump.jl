# The JuMP model of `nemde_jump` as one function, so that later pages can solve the same problem
# and compare. `nemde_jump` builds it step by step and asserts that it agrees with this.

using JuMP
using HiGHS

"""
    solve_toy_jump(market) -> NamedTuple

Builds and solves the toy market's NEMDE model in one go: dispatch, flow, loss, regional
prices, FCAS requirement duals and generic constraint duals, all per MWh. With `fcas = false`
the FCAS variables and rows are left out.
"""
function solve_toy_jump(market::Market; fcas::Bool = true)
    ic = market.interconnector
    segments = linearised_losses(ic)
    model = Model(HiGHS.Optimizer)
    set_silent(model)
    @variable(model, 0 <= cleared[u in market.units, j in 1:n_bids(u)] <= quantity(bid(u, j)))
    @expression(model, dispatch[u in market.units], sum(cleared[u, j] for j in 1:n_bids(u)))
    @constraint(model, [u in market.units], dispatch[u] <= availability(u))
    @constraint(model, [u in market.units], dispatch[u] - initial_mw(u) <= ramp_up(u))
    @constraint(model, [u in market.units], initial_mw(u) - dispatch[u] <= ramp_down(u))
    @variable(model, flow)
    @variable(model, 0 <= segment_flow[s in eachindex(segments)] <= segments[s].to_mw - segments[s].from_mw)
    @variable(model, filled[s in 1:(length(segments) - 1)], Bin)
    @expression(model, loss, loss_at(ic, ic.breakpoints[1]) + sum(segments[s].slope * segment_flow[s] for s in eachindex(segments)))
    @constraint(model, flow == ic.breakpoints[1] + sum(segment_flow))
    @constraint(model, [s in 1:(length(segments) - 1)], segment_flow[s] >= (segments[s].to_mw - segments[s].from_mw) * filled[s])
    @constraint(model, [s in 1:(length(segments) - 1)], segment_flow[s + 1] <= (segments[s + 1].to_mw - segments[s + 1].from_mw) * filled[s])
    @constraint(model, -ic.max_flow <= flow <= ic.max_flow)
    exported(r) = r == ic.from ? flow : -flow
    loss_charged(r) = (r == ic.from ? ic.from_loss_share : 1 - ic.from_loss_share) * loss
    @constraint(
        model, balance[r in market.regions],
        sum(dispatch[u] for u in units_in(market, r)) - exported(r) - loss_charged(r) == region_demand(market, r)
    )
    if fcas
        @variable(model, 0 <= raise[u in fcas_units(market)] <= max_avail(trapezium(u)))
        @variable(model, 0 <= raise_cleared[u in fcas_units(market), j in 1:n_fcas_bids(u)] <= quantity(fcas_bid(u, j)))
        @constraint(model, [u in fcas_units(market)], raise[u] == sum(raise_cleared[u, j] for j in 1:n_fcas_bids(u)))
        @constraint(model, [u in fcas_units(market)], dispatch[u] + upper_slope(trapezium(u)) * raise[u] <= trapezium(u).enablement_max)
        @constraint(model, [u in fcas_units(market)], dispatch[u] - lower_slope(trapezium(u)) * raise[u] >= trapezium(u).enablement_min)
    end
    cost = sum(price(bid(u, j)) * cleared[u, j] * INTERVAL_H for u in market.units for j in 1:n_bids(u))
    fcas && (cost += sum(price(fcas_bid(u, j)) * raise_cleared[u, j] * INTERVAL_H for u in fcas_units(market) for j in 1:n_fcas_bids(u)))
    generic = Dict{String, ConstraintRef}()
    for gc in market.constraints
        lhs = sum(
            t.factor * (t.kind == :energy ? dispatch[find_unit(market, t.id)] : raise[find_unit(market, t.id)])
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
        dispatch = Dict(unit_name(u) => value(dispatch[u]) for u in market.units),
        flow = value(flow), loss = value(loss),
        price = Dict(r => dual(balance[r]) / INTERVAL_H for r in market.regions),
        generic = Dict(n => dual(c) / INTERVAL_H for (n, c) in generic),
        objective = objective_value(model),
    )
    undo()
    return result
end
