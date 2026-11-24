# Probes the range of optimal prices of benchmark intervals whose solved price differs from AEMO's.
#
# Each interval is re-solved as the batch runner solves it (two-run fast start, `nemde_optimizer`). The binaries of
# the dispatch run are then fixed at their optimum, as in the dual pass, and the right-hand side of each target
# price's rows is moved by +h and -h MW for each h in `H_MW`. The dual of each perturbed LP is the price there; the
# value function is convex in the right-hand side, so the price is non-decreasing in the move, and at the smallest h
# the closed range between the two sides is every price the fixed LP admits at its optimum.
#
#     julia -O1 --project=AustralianElectricityMarketsSimulations/test scripts/dual_range_probe.jl \
#         <targets.csv> <out.csv> [hive_location]
#
# `targets.csv` has columns `interval,market,region,published,solved`; `market` is `ENERGY` or an FCAS `BIDTYPE`.

using AustralianElectricityMarkets
using AustralianElectricityMarketsSimulations
using DataFrames
using Dates
using HiGHS
import PowerSimulations as PSI
import PowerSystems as PSY

const JuMP = PSI.JuMP
const MOI = JuMP.MOI
const DECISION = "dispatch"
# Right-hand-side moves, in MW, at which the one-sided price is read.
const H_MW = (1.0e-3, 1.0e-2, 1.0e-1, 1.0, 10.0)

price_columns() = ["p_$(side)_$(h)" for h in H_MW for side in ("up", "down")]

function read_targets(path)
    lines = readlines(path)
    header = split(first(lines), ',')
    rows = [Dict(zip(header, split(l, ','))) for l in lines[2:end] if !isempty(l)]
    return DataFrame(;
        interval = [DateTime(r["interval"]) for r in rows], market = [r["market"] for r in rows],
        region = [r["region"] for r in rows], published = [parse(Float64, r["published"]) for r in rows],
        solved = [parse(Float64, r["solved"]) for r in rows],
    )
end

# Moves the right-hand side of row `c` by `delta` (in the row's own units).
function shift!(jm, c, delta)
    set = MOI.get(jm, MOI.ConstraintSet(), c)
    if set isa MOI.Interval
        MOI.set(jm, MOI.ConstraintSet(), c, MOI.Interval(set.lower + delta, set.upper + delta))
    else
        JuMP.set_normalized_rhs(c, JuMP.normalized_rhs(c) + delta)
    end
    return
end

function solve_lp!(jm)
    JuMP.optimize!(jm)
    status = JuMP.termination_status(jm)
    status == MOI.OPTIMAL || error("LP probe ended with $status")
    return JuMP.objective_value(jm)
end

# Fixes every binary or integer variable at its rounded optimum and drops integrality, as PSI's dual pass does.
function fix_integers!(jm)
    ints = [v for v in JuMP.all_variables(jm) if JuMP.is_binary(v) || JuMP.is_integer(v)]
    vals = round.(JuMP.value.(ints))
    for (v, val) in zip(ints, vals)
        JuMP.is_binary(v) ? JuMP.unset_binary(v) : JuMP.unset_integer(v)
        JuMP.fix(v, val; force = true)
    end
    return
end

# The rows whose summed dual is the price of `market` in `region`: the area balance for energy, or every built
# generic constraint carrying that FCAS requirement.
function price_rows(container, sys, market, region)
    if market == "ENERGY"
        return [PSI.get_constraint(container, PSI.CopperPlateBalanceConstraint(), PSY.Area)[region, 1]]
    end
    con = PSI.get_constraint(container, NEMConstraintLimit(), GenericConstraint)
    built = Set(axes(con)[1])
    rows = JuMP.ConstraintRef[]
    for gc in PSY.get_components(GenericConstraint, sys)
        name = PSY.get_name(gc)
        name in built || continue
        any(r -> get_region(r) == region && string(get_service(r)) == market, get_fcas_requirements(gc)) &&
            push!(rows, con[name, 1])
    end
    return rows
end

function probe_interval(db, t, targets)
    sys = nem_system(
        db, NEMDEConfiguration(); date_range = t:DISPATCH_INTERVAL:(t + 2DISPATCH_INTERVAL), intervention = 0,
        interval_flow_limits = false,
    )
    optimizer = nemde_optimizer(; output_flag = false, threads = 1)
    (; models, sequence, dispatch) = nem_dispatch_sequence(
        NEMDispatchProblem, template_nemde(), sys; optimizer, initial_time = t, name = DECISION,
    )
    folder = mktempdir()
    simulation = PSI.Simulation(; name = "probe", steps = 1, models, sequence, simulation_folder = folder, initial_time = t)
    PSI.build!(simulation; store_systems_in_results = false) == PSI.SimulationBuildStatus.BUILT || error("build failed")
    PSI.execute!(simulation; enable_progress_bar = false) == PSI.RunStatus.SUCCESSFULLY_FINALIZED ||
        error("execute failed")
    results = PSI.get_decision_problem_results(PSI.SimulationResults(simulation), DECISION)
    solved = read_solved_interval(results, sys)

    container = PSI.get_optimization_container(dispatch)
    jm = PSI.get_jump_model(container)
    JuMP.optimize!(jm)
    JuMP.termination_status(jm) == MOI.OPTIMAL || error("MILP re-solve ended with $(JuMP.termination_status(jm))")
    fix_integers!(jm)
    z0 = solve_lp!(jm)
    base = PSY.get_base_power(sys)
    scale = base * interval_hours(DISPATCH_INTERVAL)

    out = DataFrame()
    for r in eachrow(targets)
        rows = price_rows(container, sys, r.market, r.region)
        rerun = if r.market == "ENERGY"
            only(solved.prices.ROP[solved.prices.REGIONID .== r.region])
        else
            sel = (solved.fcas_prices.REGIONID .== r.region) .& (string.(solved.fcas_prices.BIDTYPE) .== r.market)
            any(sel) ? only(solved.fcas_prices.ROP[sel]) : NaN
        end
        fixed_lp = isempty(rows) ? NaN : sum(JuMP.dual, rows) / scale
        prices = Dict{String, Float64}()
        for h in H_MW, (side, sgn) in (("up", 1), ("down", -1))
            key = "p_$(side)_$(h)"
            isempty(rows) && (prices[key] = NaN; continue)
            d = sgn * h / base
            foreach(c -> shift!(jm, c, d), rows)
            solve_lp!(jm)
            prices[key] = sum(JuMP.dual, rows) / scale
            foreach(c -> shift!(jm, c, -d), rows)
        end
        # Re-solve the restored LP so that the next target reads the duals at the operating point.
        isempty(rows) || (z_back = solve_lp!(jm))
        isempty(rows) || isapprox(z_back, z0; rtol = 1.0e-9, atol = 1.0e-6) ||
            @warn "Restored LP objective $z_back differs from $z0"
        row = (;
            interval = r.interval, market = r.market, region = r.region, n_rows = length(rows),
            published = r.published, solved_benchmark = r.solved, solved_rerun = rerun, fixed_lp_dual = fixed_lp,
        )
        push!(out, merge(row, NamedTuple(Symbol(k) => prices[k] for k in price_columns())))
    end
    rm(folder; recursive = true, force = true)
    return out
end

function main(args = ARGS)
    targets = read_targets(args[1])
    out_path = args[2]
    hive = length(args) >= 3 ? args[3] : joinpath(homedir(), ".nemdb_cache")
    db = aem_connect(HiveConfiguration(hive_location = hive))
    for (i, g) in enumerate(groupby(targets, :interval; sort = true))
        t = first(g.interval)
        done = isfile(out_path) && any(startswith(l, string(t)) for l in readlines(out_path))
        done && continue
        t0 = time()
        frame = try
            probe_interval(db, t, g)
        catch err
            @error "Probe of $t failed" exception = (err, catch_backtrace())
            frame = DataFrame(;
                interval = g.interval, market = g.market, region = g.region, n_rows = -1, published = g.published,
                solved_benchmark = g.solved, solved_rerun = NaN, fixed_lp_dual = NaN,
            )
            foreach(c -> frame[!, c] .= NaN, price_columns())
            frame
        end
        new = !isfile(out_path)
        open(out_path, "a") do io
            new && println(io, join(names(frame), ','))
            for r in eachrow(frame)
                println(io, join((string(x) for x in r), ','))
            end
        end
        @info "Probed $t ($i of $(length(unique(targets.interval)))) in $(round(time() - t0; digits = 1)) s"
    end
    return
end

main()
