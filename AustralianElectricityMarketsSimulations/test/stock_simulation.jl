# Recurrent replay of `replicate_range`; expected values are hand-derived on the toy fixture (100 MW base power).
# The toy systems are one area unless built with an `interchange`.

# Zero MIP gaps: the loss and MNSP encodings are MILPs, and a default gap can stop short of the optimum.
const STOCK_OPTIMIZER = PSI.JuMP.optimizer_with_attributes(
    HiGHS.Optimizer, "output_flag" => false, "mip_rel_gap" => 0.0, "mip_abs_gap" => 1.0e-10,
)
const STOCK_STEPS = TOY_START:TOY_RESOLUTION:(TOY_START + TOY_RESOLUTION)
# Step 1: Alta ramp-bound at 60 MW, Park City 40 MW at $80. Step 2: N_TOY_LIMIT holds Alta at 65 MW, Park City 55 MW at $60.
# `reverse_order` swaps the two steps' data.
function sentinel_system(;
        reverse_order = false, alta_availability = [100.0, 90.0],
        alta_initial = [50.0, 70.0], alta_ramp_down = [100.0, 90.0], invoked = 1.0
    )
    r(x) = reverse_order ? reverse(x) : x
    units = [
        TOY_CHEAP => toy_unit(
            100.0, r([[(100.0, 20.0)], [(100.0, 30.0)]]); initial = r(alta_initial),
            ramp_up = r([2.0, 1.0]), ramp_down = r(alta_ramp_down), availability = r(alta_availability),
        ),
        TOY_EXPENSIVE => toy_unit(
            100.0, r([[(100.0, 80.0)], [(100.0, 60.0)]]); initial = r([40.0, 30.0]),
            ramp_up = r([100.0, 90.0]), ramp_down = r([100.0, 90.0]), availability = r([100.0, 95.0]),
        ),
    ]
    return nem_toy_system(
        units, r([100.0, 120.0]); horizon = TOY_RESOLUTION,
        mutate! = (sys, stamps) -> add_toy_generic_constraint!(sys, stamps, TOY_CHEAP, r([200.0, 65.0]); invoked = invoked),
    )
end
# Step 2 binds Alta's availability (60 MW, 100 MW in step 1) and Park City's ramp-down floor (60 - 2 * 5 = 50 MW).
# Brighton ($50) is marginal in step 2, so the price is $50 there and $20 in step 1, where Alta is marginal.
const BINDING_MID = "Brighton"
function binding_sentinel_system(; reverse_order = false)
    r(x) = reverse_order ? reverse(x) : x
    units = [
        TOY_CHEAP => toy_unit(
            100.0, [(100.0, 20.0)]; initial = [50.0, 50.0],
            ramp_up = [100.0, 100.0], availability = r([100.0, 60.0]),
        ),
        BINDING_MID => toy_unit(100.0, [(100.0, 50.0)]; initial = [0.0, 0.0], ramp_up = [100.0, 100.0]),
        TOY_EXPENSIVE => toy_unit(
            100.0, [(100.0, 80.0)]; initial = r([0.0, 60.0]),
            ramp_up = [100.0, 100.0], ramp_down = r([100.0, 2.0]),
        ),
    ]
    return nem_toy_system(units, r([90.0, 130.0]); horizon = TOY_RESOLUTION)
end
# The solved tables of `_solved_tables` at interval `t`.
stock_at(tables, t) = map(df -> filter(:SETTLEMENTDATE => ==(t), df), tables)
# One standalone one-interval solve of `template` (default the replication template) at `t`.
function stock_standalone(sys, t; parts = REPLICATION_PARTS, template = replication_template(sys; parts))
    model = AEMS._replication_decision_model(template, sys, t; optimizer = STOCK_OPTIMIZER, name = "standalone")
    @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
    @test PSI.solve!(model) == PSI.RunStatus.SUCCESSFULLY_FINALIZED
    results = PSI.OptimizationProblemResults(model)
    return (;
        # The MILP dual pass re-solves the model, so the objective is read from the optimizer stats.
        model, results, objective = only(PSI.read_optimizer_stats(results).objective_value),
        solved = stock_at(AEMS._solved_tables(results, sys, parts), t),
    )
end
# The simulation, its per-step objectives and solved tables.
function stock_simulate(sys; kwargs...)
    out = AEMS._replication_simulation(sys, STOCK_STEPS; optimizer = STOCK_OPTIMIZER, kwargs...)
    tables = AEMS._solved_tables(out.results, sys, REPLICATION_PARTS)
    return (;
        out...,
        objectives = PSI.read_optimizer_stats(out.results).objective_value,
        solved = [stock_at(tables, t) for t in STOCK_STEPS],
    )
end
stock_price(solved) = only(solved.prices.ROP)
stock_mw(solved, duid) = only(filter(:DUID => ==(duid), solved.dispatch).TOTALCLEARED)
const STOCK_SIM = stock_simulate(sentinel_system())

@testset "two simulation steps equal two standalone solves, with no initial conditions" begin
    container = PSI.get_optimization_container(STOCK_SIM.model)
    @test PSI.built_for_recurrent_solves(container) && isempty(PSI.get_initial_conditions(container))
    @test length(STOCK_SIM.objectives) == 2
    for (k, t) in enumerate(STOCK_STEPS)
        ref = stock_standalone(sentinel_system(), t)
        @test STOCK_SIM.objectives[k] ≈ ref.objective atol = TOY_TOLERANCE
        @test stock_price(STOCK_SIM.solved[k]) ≈ stock_price(ref.solved) atol = TOY_TOLERANCE
        @test Set(STOCK_SIM.solved[k].dispatch.DUID) == Set(ref.solved.dispatch.DUID)
        for duid in ref.solved.dispatch.DUID
            @test stock_mw(STOCK_SIM.solved[k], duid) ≈ stock_mw(ref.solved, duid) atol = TOY_TOLERANCE
        end
    end
end

@testset "step 2 reads step-2 data, and reversing the intervals reverses the results" begin
    expected = [
        (step = 1, cheap = 60.0, expensive = 40.0, price = 80.0, objective = 4400 / 12, limit_price = 0.0),
        (step = 2, cheap = 65.0, expensive = 55.0, price = 60.0, objective = 5250 / 12, limit_price = -30.0),
    ]
    for e in expected
        k = e.step
        @test stock_mw(STOCK_SIM.solved[k], TOY_CHEAP) ≈ e.cheap atol = TOY_TOLERANCE
        @test stock_mw(STOCK_SIM.solved[k], TOY_EXPENSIVE) ≈ e.expensive atol = TOY_TOLERANCE
        @test stock_price(STOCK_SIM.solved[k]) ≈ e.price atol = TOY_TOLERANCE
        @test STOCK_SIM.objectives[k] ≈ e.objective atol = TOY_TOLERANCE
    end
    key = only(k for k in PSI.list_dual_keys(STOCK_SIM.results) if PSI.IS.Optimization.get_entry_type(k) === NEMConstraintLimit)
    duals = only(values(PSI.read_realized_duals(STOCK_SIM.results, [key])))
    gc_price = Dict(r.DateTime => r.value / (100.0 * DISPATCH_INTERVAL_HOURS) for r in eachrow(duals))
    for e in expected
        @test gc_price[STOCK_STEPS[e.step]] ≈ e.limit_price atol = TOY_TOLERANCE
    end
    rev = stock_simulate(sentinel_system(; reverse_order = true))
    for k in 1:2, d in (TOY_CHEAP, TOY_EXPENSIVE)
        @test stock_mw(rev.solved[k], d) ≈ stock_mw(STOCK_SIM.solved[3 - k], d) atol = TOY_TOLERANCE
    end
    for k in 1:2
        @test stock_price(rev.solved[k]) ≈ stock_price(STOCK_SIM.solved[3 - k]) atol = TOY_TOLERANCE
        @test rev.objectives[k] ≈ STOCK_SIM.objectives[3 - k] atol = TOY_TOLERANCE
    end
end

@testset "availability and a ramp-down floor bind in step 2 only" begin
    binding = stock_simulate(binding_sentinel_system())
    # Step 1 objective: 90 MW * $20. Step 2: 60 MW * $20 + 20 MW * $50 + 50 MW * $80 (Park City held at its floor).
    expected = [
        (step = 1, alta = 90.0, mid = 0.0, expensive = 0.0, price = 20.0, objective = 1800 / 12),
        (step = 2, alta = 60.0, mid = 20.0, expensive = 50.0, price = 50.0, objective = 6200 / 12),
    ]
    for e in expected
        k = e.step
        @test stock_mw(binding.solved[k], TOY_CHEAP) ≈ e.alta atol = TOY_TOLERANCE
        @test stock_mw(binding.solved[k], BINDING_MID) ≈ e.mid atol = TOY_TOLERANCE
        @test stock_mw(binding.solved[k], TOY_EXPENSIVE) ≈ e.expensive atol = TOY_TOLERANCE
        @test stock_price(binding.solved[k]) ≈ e.price atol = TOY_TOLERANCE
        @test binding.objectives[k] ≈ e.objective atol = TOY_TOLERANCE
    end
    rev = stock_simulate(binding_sentinel_system(; reverse_order = true))
    for k in 1:2, d in (TOY_CHEAP, BINDING_MID, TOY_EXPENSIVE)
        @test stock_mw(rev.solved[k], d) ≈ stock_mw(binding.solved[3 - k], d) atol = TOY_TOLERANCE
    end
    for k in 1:2
        @test stock_price(rev.solved[k]) ≈ stock_price(binding.solved[3 - k]) atol = TOY_TOLERANCE
        @test rev.objectives[k] ≈ binding.objectives[3 - k] atol = TOY_TOLERANCE
    end
end

@testset "availability conflicts remain feasible and are reported" begin
    sys = sentinel_system(; alta_availability = [100.0, 0.0], alta_initial = [60.0, 60.0], alta_ramp_down = [1.0, 1.0])
    template = replication_template(sys; parts = REPLICATION_PARTS)
    @test isnothing(check_dispatch_envelope(sys, template, TOY_START, 2))
    out = AEMS._replication_simulation(sys, STOCK_STEPS; optimizer = STOCK_OPTIMIZER)
    violations = AEMS._constraint_violations(out.results, sys)
    availability = filter(r -> r.family == "energy_max_avail" && r.name == TOY_CHEAP, violations)
    @test only(availability.MW) ≈ 55.0 atol = TOY_TOLERANCE
    @test only(availability.DateTime) == TOY_START + TOY_RESOLUTION
    @test !any(==("unit_ramp"), violations.family)
end


@testset "a constraint invoked at no step is left out and reported with its reason" begin
    never = sentinel_system(; invoked = [0.0, 0.0])
    @test AEMS._never_invoked_constraints(never, STOCK_STEPS) == Dict("N_TOY_LIMIT" => :never_invoked)
    @test AEMS._never_invoked_constraints(sentinel_system(; invoked = [1.0, 0.0]), STOCK_STEPS) == Dict{String, Symbol}()
    out_never = AEMS._replication_simulation(never, STOCK_STEPS; optimizer = STOCK_OPTIMIZER)
    row_never = only(filter(:constraint => ==("N_TOY_LIMIT"), out_never.skipped_constraints))
    @test (row_never.reason, row_never.n_missing) == (:never_invoked, 0)
end

@testset "argument checks" begin
    @test_throws ArgumentError AEMS._range_steps(TOY_START, TOY_START - TOY_RESOLUTION)
    @test_throws ArgumentError AEMS._range_steps(TOY_START, TOY_START + Minute(7))
    @test AEMS._range_steps(TOY_START, TOY_START) == TOY_START:TOY_RESOLUTION:TOY_START
    @test_throws ArgumentError AEMS._replication_simulation(sentinel_system(), STOCK_STEPS; parts = (:nonsense,))
    @test_throws ArgumentError replication_template(sentinel_system(); parts = (:nonsense,))
end

# Two intervals of 100 MW load: Alta $20 (150 MW, so part-loaded and marginal at 100 MW once the
# constraint is masked), Park City $80 (100 MW). No binding ramp. One generic constraint `name` of
# `sense` on `duid` at `rhs_mw`, invoked per `invoked`; `reverse_order` reverses the mask.
function masked_system(sense, duid, rhs_mw; invoked = [1.0, 0.0], reverse_order = false)
    units = [
        TOY_CHEAP => toy_unit(150.0, [(150.0, 20.0)]; initial = 50.0, ramp_up = 100.0),
        TOY_EXPENSIVE => toy_unit(100.0, [(100.0, 80.0)]; initial = 0.0, ramp_up = 100.0),
    ]
    mask = reverse_order ? reverse(invoked) : invoked
    return nem_toy_system(
        units, 100.0; horizon = TOY_RESOLUTION,
        mutate! = (sys, stamps) -> add_toy_generic_constraint!(sys, stamps, duid, rhs_mw; invoked = mask, sense = sense),
    )
end
# `name => (DateTime => raw dual)` of every `NEMConstraintLimit` in `results`.
function stock_gc_duals(results)
    read(k) = results isa PSI.SimulationProblemResults ? only(values(PSI.read_realized_duals(results, [k]))) : PSI.read_dual(results, k)
    return Dict(
        k.meta => Dict(r.DateTime => r.value for r in eachrow(read(k)))
            for k in PSI.list_dual_keys(results) if PSI.IS.Optimization.get_entry_type(k) === NEMConstraintLimit
    )
end
stock_gc_price(raw) = raw / (100.0 * DISPATCH_INTERVAL_HOURS)
# One standalone solve at `t`, every `GenericConstraint` under `LinearFactorLimit` with `use_slacks`.
function masked_standalone(sys, t; use_slacks)
    template = replication_template(sys; parts = ())
    for gc in PSY.get_components(GenericConstraint, sys)
        name = PSY.get_name(gc)
        PSI.set_service_model!(
            template, name,
            PSI.ServiceModel(GenericConstraint, LinearFactorLimit, name; duals = [NEMConstraintLimit], use_slacks = use_slacks),
        )
    end
    model = AEMS._replication_decision_model(template, sys, t; optimizer = STOCK_OPTIMIZER, name = "masked")
    @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
    @test PSI.solve!(model) == PSI.RunStatus.SUCCESSFULLY_FINALIZED
    results = PSI.OptimizationProblemResults(model)
    return (;
        results, objective = PSI.JuMP.objective_value(PSI.get_jump_model(model)),
        solved = stock_at(AEMS._solved_tables(results, sys, REPLICATION_PARTS), t),
        gc = stock_gc_duals(results)["N_TOY_LIMIT"][t],
    )
end
const MASK_CASES = [
    (
        sense = ConstraintSense.LE, duid = TOY_CHEAP, rhs = 60.0, cheap = [60.0, 100.0], expensive = [40.0, 0.0],
        price = [80.0, 20.0], objective = [4400 / 12, 2000 / 12], gc_price = -60.0, slack = "GenericConstraintSlackUp",
    ),
    (
        sense = ConstraintSense.GE, duid = TOY_EXPENSIVE, rhs = 30.0, cheap = [70.0, 100.0], expensive = [30.0, 0.0],
        price = [20.0, 20.0], objective = [3800 / 12, 2000 / 12], gc_price = 60.0, slack = "GenericConstraintSlackDown",
    ),
    (
        sense = ConstraintSense.EQ, duid = TOY_EXPENSIVE, rhs = 30.0, cheap = [70.0, 100.0], expensive = [30.0, 0.0],
        price = [20.0, 20.0], objective = [3800 / 12, 2000 / 12], gc_price = 60.0, slack = "GenericConstraintSlackDown",
    ),
]

@testset "a constraint invoked in interval 1 only: simulation equals standalone solves, for LE, GE and EQ" begin
    for c in MASK_CASES
        sys = masked_system(c.sense, c.duid, c.rhs)
        sim = stock_simulate(sys)
        gc_sim = stock_gc_duals(sim.results)["N_TOY_LIMIT"]
        for (k, t) in enumerate(STOCK_STEPS)
            new = masked_standalone(masked_system(c.sense, c.duid, c.rhs), t; use_slacks = true)
            old = masked_standalone(masked_system(c.sense, c.duid, c.rhs), t; use_slacks = false)
            for run in (new, (; objective = sim.objectives[k], solved = sim.solved[k], gc = gc_sim[t]))
                @test run.objective ≈ c.objective[k] atol = TOY_TOLERANCE
                @test stock_mw(run.solved, TOY_CHEAP) ≈ c.cheap[k] atol = TOY_TOLERANCE
                @test stock_mw(run.solved, TOY_EXPENSIVE) ≈ c.expensive[k] atol = TOY_TOLERANCE
                @test stock_price(run.solved) ≈ c.price[k] atol = TOY_TOLERANCE
            end
            # Old (vacuous row) and new (zero-cost slack) standalone formulations agree.
            @test new.objective ≈ old.objective atol = TOY_TOLERANCE
            @test stock_price(new.solved) ≈ stock_price(old.solved) atol = TOY_TOLERANCE
            @test new.gc ≈ old.gc atol = TOY_TOLERANCE
            if k == 1
                @test stock_gc_price(new.gc) ≈ c.gc_price atol = TOY_TOLERANCE
                @test stock_gc_price(gc_sim[t]) ≈ c.gc_price atol = TOY_TOLERANCE
            else
                # The masked row's dual is zero up to simplex arithmetic.
                @test abs(new.gc) <= 1.0e-9 && abs(gc_sim[t]) <= 1.0e-9
                # The masked row is violated (vacuous), its slack takes the violation, and no violation is reported.
                slack = only(PSI.read_variable(new.results, "$(c.slack)__GenericConstraint__N_TOY_LIMIT").value)
                @test slack >= (c.sense == ConstraintSense.LE ? 40.0 : 30.0) - TOY_TOLERANCE
                v = AEMS._constraint_violations(new.results, sys)
                @test nrow(v) == 0 || !any(==("generic_constraint"), v.family)
            end
        end
    end
end

@testset "reversing the mask reverses the results" begin
    c = first(MASK_CASES)
    fwd = stock_simulate(masked_system(c.sense, c.duid, c.rhs))
    rev = stock_simulate(masked_system(c.sense, c.duid, c.rhs; reverse_order = true))
    gc_fwd, gc_rev = stock_gc_duals(fwd.results)["N_TOY_LIMIT"], stock_gc_duals(rev.results)["N_TOY_LIMIT"]
    for k in 1:2
        @test rev.objectives[k] ≈ fwd.objectives[3 - k] atol = TOY_TOLERANCE
        @test stock_mw(rev.solved[k], TOY_CHEAP) ≈ stock_mw(fwd.solved[3 - k], TOY_CHEAP) atol = TOY_TOLERANCE
        @test gc_rev[STOCK_STEPS[k]] ≈ gc_fwd[STOCK_STEPS[3 - k]] atol = TOY_TOLERANCE
    end
end

@testset "two versions invoked in different intervals are both modeled" begin
    units = [
        TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = 50.0, ramp_up = 100.0),
        TOY_EXPENSIVE => toy_unit(100.0, [(100.0, 80.0)]; initial = 0.0, ramp_up = 100.0),
    ]
    sys = nem_toy_system(
        units, 100.0; horizon = TOY_RESOLUTION,
        mutate! = function (s, stamps)
            add_toy_generic_constraint!(s, stamps, TOY_CHEAP, 60.0; invoked = [1.0, 0.0], name = "N_TOY_LIMIT@A")
            add_toy_generic_constraint!(s, stamps, TOY_CHEAP, 70.0; invoked = [0.0, 1.0], name = "N_TOY_LIMIT@B")
            return
        end,
    )
    out = stock_simulate(sys)
    @test isempty(out.skipped_constraints.constraint ∩ ["N_TOY_LIMIT@A", "N_TOY_LIMIT@B"])
    duals = stock_gc_duals(out.results)
    t1, t2 = STOCK_STEPS
    @test [stock_mw(out.solved[k], TOY_CHEAP) for k in 1:2] ≈ [60.0, 70.0] atol = TOY_TOLERANCE
    @test out.objectives ≈ [4400 / 12, 3800 / 12] atol = TOY_TOLERANCE
    @test stock_gc_price(duals["N_TOY_LIMIT@A"][t1]) ≈ -60.0 atol = TOY_TOLERANCE
    @test stock_gc_price(duals["N_TOY_LIMIT@B"][t2]) ≈ -60.0 atol = TOY_TOLERANCE
    @test abs(duals["N_TOY_LIMIT@B"][t1]) <= 1.0e-9 && abs(duals["N_TOY_LIMIT@A"][t2]) <= 1.0e-9
end

@testset "a recurrent build without slacks throws" begin
    sys = masked_system(ConstraintSense.LE, TOY_CHEAP, 60.0)
    template = replication_template(sys; parts = ())
    PSI.set_service_model!(template, "N_TOY_LIMIT", PSI.ServiceModel(GenericConstraint, LinearFactorLimit, "N_TOY_LIMIT"; duals = [NEMConstraintLimit]))
    model = AEMS._replication_decision_model(template, sys, TOY_START; optimizer = STOCK_OPTIMIZER, name = "hard")
    models = PSI.SimulationModels(; decision_models = [model])
    sim = PSI.Simulation(;
        name = "hard", steps = 2, models = models,
        sequence = PSI.SimulationSequence(; models = models, ini_cond_chronology = PSI.InterProblemChronology()),
        simulation_folder = mktempdir(), initial_time = TOY_START,
    )
    @test_throws ArgumentError PSI.build!(sim; store_systems_in_results = false)
end

@testset "replicate_range on the mock cache" begin
    db = aem_connect(HiveConfiguration(hive_location = AEM_TEST_REPLAY_HIVE_DIR, filesystem = "file"))
    t1, t2 = DateTime(2025, 1, 1, 0, 5), DateTime(2025, 1, 1, 0, 10)
    result = replicate_range(db, t1, t2)
    @test nrow(result.chunks) == 1 && length(result.results) == 1
    c = result.comparison
    for table in (:prices, :dispatch, :interconnectors)
        @test first(names(c[table])) == "SETTLEMENTDATE" && Set(c[table].SETTLEMENTDATE) == Set([t1, t2])
        @test nrow(c[table]) == sum(nrow(read_published_interval(db, t)[table]) for t in (t1, t2))
    end
    @test all(isfinite, skipmissing(c.prices.ROP_solved)) && any(!ismissing, c.prices.ROP_solved)
    @test any(!ismissing, c.dispatch.TOTALCLEARED_solved)
    # Interchanges are modeled (the unavailable IC6 is not), and so is FCAS.
    @test any(!ismissing, c.interconnectors.MWFLOW_solved)
    @test all(isfinite, skipmissing(c.interconnectors.MWLOSSES_solved))
    @test all(ismissing, filter(:INTERCONNECTORID => ==("IC6"), c.interconnectors).MWFLOW_solved)
    @test any(!ismissing, c.fcas_prices.ROP_solved) && all(isfinite, skipmissing(c.fcas_prices.ROP_solved))
    # Invoked at 00:10 only over BW01-BW04: modeled now that batteries are, and masked at 00:05.
    @test !any(startswith("N_PARTIAL_COVERAGE"), result.skipped_constraints.constraint)
    duals = stock_gc_duals(result.results[1])
    partial = only(k for k in keys(duals) if startswith(k, "N_PARTIAL_COVERAGE"))
    @test duals[partial][t1] == 0.0
    @test any(!ismissing, c.dispatch.TOTALCLEARED_solved[c.dispatch.DUID .== "BW01"])
    # The MNSP IC2 is modeled with its link offers in both steps.
    links = only(values(PSI.read_realized_variables(result.results[1], ["MNSPLinkFlowVariable__AreaInterchange"])))
    @test Set(links.DateTime) == Set([t1, t2]) && all(>=(-1.0e-9), links.value)
    @test names(result.ramp_violations) == ["DUID", "DateTime", "MW", "direction"]
    @test issubset(Set(result.constraint_violations.DateTime), Set([t1, t2]))
    @test_throws ArgumentError replicate_range(db, t1, t1 - Minute(5))
end

@testset "replicate_range models every family by default" begin
    db = aem_connect(HiveConfiguration(hive_location = AEM_TEST_REPLAY_HIVE_DIR, filesystem = "file"))
    t1, t2 = DateTime(2025, 1, 1, 0, 5), DateTime(2025, 1, 1, 0, 10)
    result = replicate_range(db, t1, t2)
    @test !any(in(("unmodeled_fcas_service", "unmodeled_device_type")), string.(result.skipped_constraints.reason))
    keys = PSI.list_variable_keys(result.results[1])
    entry_and_component(k) = (PSI.IS.Optimization.get_entry_type(k), PSI.IS.Optimization.get_component_type(k))
    @test any(k -> entry_and_component(k)[1] === FCASCapacityVariable, keys)
    @test any(k -> entry_and_component(k) == (InterconnectorLossVariable, PSY.AreaInterchange), keys)
    @test any(k -> entry_and_component(k) == (ActivePowerOutVariable, PSY.EnergyReservoirStorage), keys)
end

# Whether two stacked comparison NamedTuples hold the same rows (sorted by key) and equal numbers, `missing` included.
function same_comparison(x, y; atol = 1.0e-6)
    same(u, v) = (ismissing(u) && ismissing(v)) || (!ismissing(u) && !ismissing(v) && isapprox(u, v; atol = atol))
    keyed(df) = sort(df, [n for n in names(df) if eltype(df[!, n]) <: Union{Missing, AbstractString, DateTime}])
    return keys(x) == keys(y) && all(keys(x)) do name
        a, b = keyed(getproperty(x, name)), keyed(getproperty(y, name))
        names(a) == names(b) && nrow(a) == nrow(b) && all(
            col -> eltype(a[!, col]) <: Union{Missing, Real} ? all(same.(a[!, col], b[!, col])) : isequal(a[!, col], b[!, col]),
            names(a),
        )
    end
end

@testset "replicate_range chunks" begin
    db = aem_connect(HiveConfiguration(hive_location = AEM_TEST_REPLAY_HIVE_DIR, filesystem = "file"))
    chunks = AEMS._range_chunks
    @test chunks(DateTime(2026, 1, 1, 3, 55):Minute(5):DateTime(2026, 1, 1, 4, 15), :trading_day) ==
        [DateTime(2026, 1, 1, 3, 55):Minute(5):DateTime(2026, 1, 1, 4, 0), DateTime(2026, 1, 1, 4, 5):Minute(5):DateTime(2026, 1, 1, 4, 15)]
    @test chunks(DateTime(2026, 1, 1, 4, 5):Minute(5):DateTime(2026, 1, 2, 4, 0), :trading_day) ==
        [DateTime(2026, 1, 1, 4, 5):Minute(5):DateTime(2026, 1, 2, 4, 0)]
    # Loss factors change on 1 July, so the default trading-day chunks also break at 00:05 on 1 July.
    @test chunks(DateTime(2026, 6, 30, 23, 50):Minute(5):DateTime(2026, 7, 1, 0, 15), :trading_day) ==
        [DateTime(2026, 6, 30, 23, 50):Minute(5):DateTime(2026, 7, 1, 0, 0), DateTime(2026, 7, 1, 0, 5):Minute(5):DateTime(2026, 7, 1, 0, 15)]
    @test chunks(DateTime(2025, 1, 1, 0, 5):Minute(5):DateTime(2025, 1, 1, 0, 20), Minute(10)) ==
        [DateTime(2025, 1, 1, 0, 5):Minute(5):DateTime(2025, 1, 1, 0, 10), DateTime(2025, 1, 1, 0, 15):Minute(5):DateTime(2025, 1, 1, 0, 20)]
    steps = DateTime(2025, 1, 1, 0, 5):Minute(5):DateTime(2025, 1, 1, 0, 10)
    @test_throws ArgumentError chunks(steps, Minute(7))
    @test_throws ArgumentError chunks(steps, Minute(0))
    @test_throws ArgumentError chunks(steps, :calendar_day)
    @test_throws ArgumentError chunks(steps, Month(1))

    # Chunks are a partition of the range; two chunks solve the same intervals as one.
    t1, t2 = DateTime(2025, 1, 1, 0, 5), DateTime(2025, 1, 1, 0, 20)
    one = replicate_range(db, t1, t2)
    two = replicate_range(db, t1, t2; chunk = Minute(10))
    @test nrow(two.chunks) == 2 && length(two.results) == 2
    @test two.chunks.n_steps == [2, 2]
    @test same_comparison(one.comparison, two.comparison)
    @test nrow(one.solver_stats) == nrow(two.solver_stats) == 4
    @test one.solver_stats.SETTLEMENTDATE == two.solver_stats.SETTLEMENTDATE
    @test one.solver_stats.objective_value ≈ two.solver_stats.objective_value atol = 1.0e-6
    @test two.solver_stats.chunk == [1, 1, 2, 2]
    # Each chunk's reopened results hold its own intervals only.
    t_mid = DateTime(2025, 1, 1, 0, 15)
    @test collect(PSI.get_timestamps(two.results[1])) == collect(t1:Minute(5):(t_mid - Minute(5)))
    @test collect(PSI.get_timestamps(two.results[2])) == collect(t_mid:Minute(5):t2)
    @test PSI.read_optimizer_stats(two.results[2]).objective_value ≈
        filter(:SETTLEMENTDATE => >=(t_mid), one.solver_stats).objective_value atol = 1.0e-6

    # A reopened chunk reads the same constraint violations as the live solve, and needs no system.
    sys2 = replication_system(db, DateTime(2025, 1, 1, 0, 15):Minute(5):DateTime(2025, 1, 1, 0, 25))
    reopened = AEMS._constraint_violations(two.results[2], sys2)
    at_chunk2 = filter(:DateTime => t -> t >= DateTime(2025, 1, 1, 0, 15), two.constraint_violations)
    @test sort(reopened, [:DateTime, :name]) == sort(at_chunk2, [:DateTime, :name])

    # The folders hold the stores of each chunk on disk.
    d = mktempdir()
    replicate_range(db, t1, DateTime(2025, 1, 1, 0, 10); output_dir = d)
    @test isdir(joinpath(d, "chunk_1")) && any(f -> f == "simulation_store.h5", (f for (_, _, fs) in walkdir(joinpath(d, "chunk_1")) for f in fs))
    # On-disk time series default to a directory inside each chunk folder.
    d = mktempdir()
    replicate_range(db, t1, DateTime(2025, 1, 1, 0, 20); output_dir = d, chunk = Minute(10), time_series_in_memory = false)
    @test all(k -> !isempty(readdir(joinpath(d, "chunk_$k", "time_series"))), 1:2)

    # Every replication time-series parameter is stored, as PowerSimulations stores right-hand-side parameters.
    stored = Set(PSI.IS.Optimization.get_entry_type(k) for k in PSI.list_parameter_keys(one.results[1]))
    @test NEMConstraintRHSParameter in stored
    @test_throws ArgumentError replicate_range(db, t1, DateTime(2025, 1, 1, 0, 10); parts = (:nonsense,))
end

@testset "a requirement that cannot be met in step 2 only is reported in step 2 only" begin
    sys = fcas_toy_system(; reg_req = [20.0, 80.0])
    out = AEMS._replication_simulation(sys, STOCK_STEPS; optimizer = STOCK_OPTIMIZER)
    v = AEMS._constraint_violations(out.results, sys)
    @test !isempty(v)
    @test all(==(STOCK_STEPS[2]), v.DateTime)
    @test any(v.name .== "F_REG") && all(v.MW .> 0)
    @test isempty(AEMS._ramp_violations(v)) || all(==(STOCK_STEPS[2]), AEMS._ramp_violations(v).DateTime)
end

# A battery whose net ramp-down floor exceeds raw generation availability in step 1 only.
function battery_sentinel_system(; reverse_order = false)
    r(x) = reverse_order ? reverse(x) : x
    units = [TOY_CHEAP => toy_unit(100.0, [(100.0, 50.0)]; initial = 30.0, ramp_up = 100.0)]
    batteries = [
        TOY_BATTERY => toy_battery(
            100.0, 5.0, 100.0, 1.0; initial = r([20.0, 0.0]), ramp_up = 100.0, ramp_down = 1.0, gen_avail = 10.0,
        ),
    ]
    return nem_toy_system(units, 40.0; batteries = batteries, horizon = TOY_RESOLUTION)
end

@testset "storage availability uses raw limits without competing hard ceilings" begin
    sys = battery_sentinel_system()
    template = replication_template(sys; parts = REPLICATION_PARTS)
    model = AEMS._replication_decision_model(template, sys, TOY_START; optimizer = STOCK_OPTIMIZER)
    @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
    container = PSI.get_optimization_container(model)
    for V in (PSI.ActivePowerOutVariable, PSI.ActivePowerInVariable)
        @test !PSI.JuMP.has_upper_bound(PSI.get_variable(container, V(), PSY.EnergyReservoirStorage)[TOY_BATTERY, 1])
    end
end


@testset "a battery's ramp floor binds in step 1 only: simulation equals standalone solves" begin
    expected = [
        (battery = 15.0, alta = 25.0, price = 50.0, objective = (1325 + 5.0 * ENERGY_MAX_AVAIL_CVP_FACTOR * AEMS._financial_year_mpc(TOY_START)) / 12),
        (battery = 10.0, alta = 30.0, price = 50.0, objective = 1550 / 12),
    ]
    sim = stock_simulate(battery_sentinel_system())
    @test PSI.built_for_recurrent_solves(PSI.get_optimization_container(sim.model))
    for (k, t) in enumerate(STOCK_STEPS)
        ref = stock_standalone(battery_sentinel_system(), t)
        for (objective, solved) in ((sim.objectives[k], sim.solved[k]), (ref.objective, ref.solved))
            @test objective ≈ expected[k].objective atol = TOY_TOLERANCE
            @test stock_mw(solved, TOY_BATTERY) ≈ expected[k].battery atol = TOY_TOLERANCE
            @test stock_mw(solved, TOY_CHEAP) ≈ expected[k].alta atol = TOY_TOLERANCE
            @test stock_price(solved) ≈ expected[k].price atol = TOY_TOLERANCE
        end
    end
    ramp_slack = only(values(PSI.read_realized_variables(sim.results, ["UnitRampDownSlack__EnergyReservoirStorage"])))
    @test all(v -> abs(v) <= TOY_TOLERANCE, ramp_slack.value)
    rev = stock_simulate(battery_sentinel_system(; reverse_order = true))
    for k in 1:2
        @test rev.objectives[k] ≈ sim.objectives[3 - k] atol = TOY_TOLERANCE
        @test stock_mw(rev.solved[k], TOY_BATTERY) ≈ stock_mw(sim.solved[3 - k], TOY_BATTERY) atol = TOY_TOLERANCE
    end
end

# Two areas joined by `TOY_INTERCHANGE`: Alta ($20) and a 50 MW load in area 1, a load of
# `area2_mw` per step in area 2, and a demand coefficient of 1e-3 per MW of area 2 demand with all
# losses in area 1.
function loss_sentinel_system(; area2_mw = [50.0, 100.0], reverse_order = false)
    r(x) = reverse_order ? reverse(x) : x
    units = [TOY_CHEAP => toy_unit(300.0, [(300.0, 20.0)]; initial = 100.0, ramp_up = 100.0)]
    return nem_toy_system(
        units, 50.0; horizon = TOY_RESOLUTION,
        interchange = toy_interchange(; load_mw = r(area2_mw), demand_coefficient = 1.0e-3, share = 1.0),
    )
end
# Area 2 adds Solitude ($50) and an 80 MW load; the interchange is an MNSP whose forward link
# offers 30 MW at $10 and 100 MW at $40 (MAXAVAIL 200) in step 1, 100 MW at $5 (MAXAVAIL 60) in step 2.
function mnsp_sentinel_system(; reverse_order = false)
    r(x) = reverse_order ? reverse(x) : x
    units = [
        TOY_CHEAP => toy_unit(300.0, [(300.0, 20.0)]; initial = 100.0, ramp_up = 100.0),
        "Solitude" => toy_unit(200.0, [(200.0, 50.0)]; initial = 50.0, ramp_up = 100.0),
    ]
    forward = r([(200.0, [(30.0, 10.0), (100.0, 40.0)]), (60.0, [(100.0, 5.0)])])
    reverse_link = (100.0, [(100.0, 10.0)])
    return nem_toy_system(
        units, 50.0; horizon = TOY_RESOLUTION,
        interchange = toy_interchange(; load_mw = 80.0, breakpoints = [-1000.0, 1000.0], mnsp = (forward, reverse_link)),
    )
end
stock_area_price(solved, area) = only(filter(:REGIONID => ==(area), solved.prices).ROP)
stock_flow(solved) = only(solved.interconnectors.MWFLOW)
stock_loss(solved) = only(solved.interconnectors.MWLOSSES)
# `stock_simulate` and `stock_standalone` with the interchange's flow and losses read back.
stock_simulate_losses(sys) = stock_simulate(sys)
stock_standalone_losses(sys, t) = stock_standalone(sys, t)

@testset "area 2 demand changes the loss factor between steps: simulation equals standalone solves" begin
    expected = [
        (flow = 50.0, loss = 2.5, alta = 102.5, price1 = 20.0, price2 = 21.0, objective = 2050 / 12),
        (flow = 100.0, loss = 10.0, alta = 160.0, price1 = 20.0, price2 = 22.0, objective = 3200 / 12),
    ]
    sys = loss_sentinel_system()
    ic = PSY.get_component(PSY.AreaInterchange, sys, TOY_INTERCHANGE)
    @test PSY.get_time_series_values(PSY.SingleTimeSeries, ic, "loss_demand_coefficient") ≈ [0.05, 0.1]
    sim = stock_simulate_losses(sys)
    container = PSI.get_optimization_container(sim.model)
    @test PSI.built_for_recurrent_solves(container) && PSI.is_milp(container)
    # After step 2 the flow's coefficient in the loss definition is step 2's -k.
    definition = PSI.get_constraint(container, AEMS.InterconnectorLossDefinitionConstraint(), PSY.AreaInterchange)[TOY_INTERCHANGE, 1]
    flow_var = PSI.get_variable(container, PSI.FlowActivePowerVariable(), PSY.AreaInterchange)[TOY_INTERCHANGE, 1]
    @test PSI.JuMP.normalized_coefficient(definition, flow_var) ≈ -0.1
    stored = only(values(PSI.read_realized_parameters(sim.results, ["LossDemandCoefficientParameter__AreaInterchange"])))
    @test stored.value ≈ [0.05, 0.1]
    for (k, t) in enumerate(STOCK_STEPS)
        ref = stock_standalone_losses(loss_sentinel_system(), t)
        for (objective, solved) in ((sim.objectives[k], sim.solved[k]), (ref.objective, ref.solved))
            @test objective ≈ expected[k].objective atol = TOY_TOLERANCE
            @test stock_flow(solved) ≈ expected[k].flow atol = TOY_TOLERANCE
            @test stock_loss(solved) ≈ expected[k].loss atol = TOY_TOLERANCE
            @test stock_mw(solved, TOY_CHEAP) ≈ expected[k].alta atol = TOY_TOLERANCE
            # The MILP dual pass gives finite prices: area 2 pays for the marginal loss.
            @test stock_area_price(solved, "1") ≈ expected[k].price1 atol = TOY_TOLERANCE
            @test stock_area_price(solved, "2") ≈ expected[k].price2 atol = TOY_TOLERANCE
        end
    end
    rev = stock_simulate_losses(loss_sentinel_system(; reverse_order = true))
    for k in 1:2
        @test rev.objectives[k] ≈ sim.objectives[3 - k] atol = TOY_TOLERANCE
        @test stock_loss(rev.solved[k]) ≈ stock_loss(sim.solved[3 - k]) atol = TOY_TOLERANCE
        @test stock_area_price(rev.solved[k], "2") ≈ stock_area_price(sim.solved[3 - k], "2") atol = TOY_TOLERANCE
    end
end

@testset "MNSP band widths, prices and MAXAVAIL change between steps: simulation equals standalone solves" begin
    expected = [
        (flow = 30.0, solitude = 50.0, alta = 80.0, price2 = 50.0, objective = 4400 / 12),
        (flow = 60.0, solitude = 20.0, alta = 110.0, price2 = 50.0, objective = 3500 / 12),
    ]
    sim = stock_simulate_losses(mnsp_sentinel_system())
    @test PSI.is_milp(PSI.get_optimization_container(sim.model))
    for (k, t) in enumerate(STOCK_STEPS)
        ref = stock_standalone_losses(mnsp_sentinel_system(), t)
        for (objective, solved) in ((sim.objectives[k], sim.solved[k]), (ref.objective, ref.solved))
            @test objective ≈ expected[k].objective atol = TOY_TOLERANCE
            @test stock_flow(solved) ≈ expected[k].flow atol = TOY_TOLERANCE
            @test stock_mw(solved, "Solitude") ≈ expected[k].solitude atol = TOY_TOLERANCE
            @test stock_mw(solved, TOY_CHEAP) ≈ expected[k].alta atol = TOY_TOLERANCE
            @test stock_area_price(solved, "1") ≈ 20.0 atol = TOY_TOLERANCE
            @test stock_area_price(solved, "2") ≈ expected[k].price2 atol = TOY_TOLERANCE
        end
    end
    bands = only(values(PSI.read_realized_variables(sim.results, ["MNSPLinkBandVariable__AreaInterchange__forward"])))
    band_mw(t, label) = only(filter(r -> r.DateTime == t && r.name2 == label, bands).value)
    @test [band_mw(STOCK_STEPS[1], "1"), band_mw(STOCK_STEPS[1], "2")] ≈ [30.0, 0.0] atol = TOY_TOLERANCE
    @test [band_mw(STOCK_STEPS[2], "1"), band_mw(STOCK_STEPS[2], "2")] ≈ [60.0, 0.0] atol = TOY_TOLERANCE
    rev = stock_simulate_losses(mnsp_sentinel_system(; reverse_order = true))
    for k in 1:2
        @test rev.objectives[k] ≈ sim.objectives[3 - k] atol = TOY_TOLERANCE
        @test stock_flow(rev.solved[k]) ≈ stock_flow(sim.solved[3 - k]) atol = TOY_TOLERANCE
    end
end

# Loss constant 1.05 and flow coefficient 1e-4 per MW: the chord over [0, 1000] MW has slope
# (1.05 - 1 + K) + 500 x 1e-4 = 0.1 + K, with K = 1e-3 x area 2 load (0.05, then 0.1).
function loss_curve_sentinel_system(; area2_mw = [50.0, 100.0], reverse_order = false)
    r(x) = reverse_order ? reverse(x) : x
    units = [TOY_CHEAP => toy_unit(300.0, [(300.0, 20.0)]; initial = 100.0, ramp_up = 200.0)]
    return nem_toy_system(
        units, 50.0; horizon = TOY_RESOLUTION,
        interchange = toy_interchange(;
            load_mw = r(area2_mw), demand_coefficient = 1.0e-3, share = 1.0,
            loss_constant = 1.05, loss_flow_coefficient = 1.0e-4,
        ),
    )
end

# The loss curve of `loss_curve_sentinel_system`, with an MNSP forward link (price $10, MAXAVAIL 200)
# from area 1 to area 2 whose from-area loss factor is 1.1. Area 2 has no generation, so it imports.
function mnsp_loss_sentinel_system(; reverse_order = false)
    r(x) = reverse_order ? reverse(x) : x
    units = [TOY_CHEAP => toy_unit(300.0, [(300.0, 20.0)]; initial = 100.0, ramp_up = 200.0)]
    return nem_toy_system(
        units, 50.0; horizon = TOY_RESOLUTION,
        interchange = toy_interchange(;
            load_mw = r([50.0, 100.0]), demand_coefficient = 1.0e-3, loss_constant = 1.05,
            loss_flow_coefficient = 1.0e-4, mnsp = ((200.0, [(200.0, 10.0)]), (100.0, [(100.0, 10.0)])),
            mnsp_tlfs = ((1.1, 1.0), (1.0, 1.0)),
        ),
    )
end

@testset "non-unit loss constant and flow coefficient: the demand term changes between steps, simulation equals standalone solves" begin
    # Flow equals area 2's load; loss = (0.1 + K) x flow; Alta = 50 + flow + loss; price 20 x (1 + 0.1 + K) in area 2.
    expected = [
        (flow = 50.0, loss = 7.5, alta = 107.5, price1 = 20.0, price2 = 23.0, objective = 2150 / 12),
        (flow = 100.0, loss = 20.0, alta = 170.0, price1 = 20.0, price2 = 24.0, objective = 3400 / 12),
    ]
    sys = loss_curve_sentinel_system()
    ic = PSY.get_component(PSY.AreaInterchange, sys, TOY_INTERCHANGE)
    @test PSY.get_time_series_values(PSY.SingleTimeSeries, ic, "loss_demand_coefficient") ≈ [0.05, 0.1]
    sim = stock_simulate_losses(sys)
    container = PSI.get_optimization_container(sim.model)
    @test PSI.built_for_recurrent_solves(container) && PSI.is_milp(container)
    definition = PSI.get_constraint(container, AEMS.InterconnectorLossDefinitionConstraint(), PSY.AreaInterchange)[TOY_INTERCHANGE, 1]
    flow_var = PSI.get_variable(container, PSI.FlowActivePowerVariable(), PSY.AreaInterchange)[TOY_INTERCHANGE, 1]
    @test PSI.JuMP.normalized_coefficient(definition, flow_var) ≈ -0.1
    for (k, t) in enumerate(STOCK_STEPS)
        ref = stock_standalone_losses(loss_curve_sentinel_system(), t)
        for (objective, solved) in ((sim.objectives[k], sim.solved[k]), (ref.objective, ref.solved))
            @test objective ≈ expected[k].objective atol = TOY_TOLERANCE
            @test stock_flow(solved) ≈ expected[k].flow atol = TOY_TOLERANCE
            @test stock_loss(solved) ≈ expected[k].loss atol = TOY_TOLERANCE
            @test stock_mw(solved, TOY_CHEAP) ≈ expected[k].alta atol = TOY_TOLERANCE
            @test stock_area_price(solved, "1") ≈ expected[k].price1 atol = TOY_TOLERANCE
            @test stock_area_price(solved, "2") ≈ expected[k].price2 atol = TOY_TOLERANCE
        end
    end
    rev = stock_simulate_losses(loss_curve_sentinel_system(; reverse_order = true))
    for k in 1:2
        @test rev.objectives[k] ≈ sim.objectives[3 - k] atol = TOY_TOLERANCE
        @test stock_loss(rev.solved[k]) ≈ stock_loss(sim.solved[3 - k]) atol = TOY_TOLERANCE
        @test stock_area_price(rev.solved[k], "2") ≈ stock_area_price(sim.solved[3 - k], "2") atol = TOY_TOLERANCE
    end
end

@testset "MNSP link with a loss factor and a changing demand term: simulation equals standalone solves" begin
    # Import f = area 2 load; link losses = (0.1 + K) f, sent from area 1 at 1.1 x (f + loss) of Alta.
    # Price in area 2 = $10 band price + 20 x 1.1 x (1 + 0.1 + K).
    expected = [
        (flow = 50.0, loss = 7.5, alta = 113.25, price1 = 20.0, price2 = 35.3, objective = 2765 / 12),
        (flow = 100.0, loss = 20.0, alta = 182.0, price1 = 20.0, price2 = 36.4, objective = 4640 / 12),
    ]
    sim = stock_simulate_losses(mnsp_loss_sentinel_system())
    @test PSI.is_milp(PSI.get_optimization_container(sim.model))
    for (k, t) in enumerate(STOCK_STEPS)
        ref = stock_standalone_losses(mnsp_loss_sentinel_system(), t)
        for (objective, solved) in ((sim.objectives[k], sim.solved[k]), (ref.objective, ref.solved))
            @test objective ≈ expected[k].objective atol = TOY_TOLERANCE
            @test stock_flow(solved) ≈ expected[k].flow atol = TOY_TOLERANCE
            @test stock_loss(solved) ≈ expected[k].loss atol = TOY_TOLERANCE
            @test stock_mw(solved, TOY_CHEAP) ≈ expected[k].alta atol = TOY_TOLERANCE
            @test stock_area_price(solved, "1") ≈ expected[k].price1 atol = TOY_TOLERANCE
            @test stock_area_price(solved, "2") ≈ expected[k].price2 atol = TOY_TOLERANCE
        end
    end
    rev = stock_simulate_losses(mnsp_loss_sentinel_system(; reverse_order = true))
    for k in 1:2
        @test rev.objectives[k] ≈ sim.objectives[3 - k] atol = TOY_TOLERANCE
        @test stock_loss(rev.solved[k]) ≈ stock_loss(sim.solved[3 - k]) atol = TOY_TOLERANCE
        @test stock_flow(rev.solved[k]) ≈ stock_flow(sim.solved[3 - k]) atol = TOY_TOLERANCE
    end
end

# FCAS solved values of one interval: each capacity variable cell by `"<meta> <device>"`, in MW (100 MW base).
function stock_fcas_capacities(results, t)
    out = Dict{String, Float64}()
    for key in PSI.list_variable_keys(results)
        PSI.IS.Optimization.get_entry_type(key) in (FCASCapacityVariable, FCASSideCapacityVariable) || continue
        df = results isa PSI.SimulationProblemResults ? only(values(PSI.read_realized_variables(results, [key]))) : PSI.read_variable(results, key)
        for row in eachrow(filter(:DateTime => ==(t), df))
            out["$(key.meta) $(row.name)"] = row.value * 100.0
        end
    end
    return out
end
# FCAS prices of one interval by `(REGIONID, BIDTYPE)`, in $/MWh.
stock_fcas_prices(results, sys, t) = Dict(
    (r.REGIONID, r.BIDTYPE) => r.ROP for r in eachrow(compute_fcas_prices(results, sys; resolution = DISPATCH_INTERVAL)) if r.SETTLEMENTDATE == t
)
function stock_fcas_standalone(sys, t)
    template = replication_template(sys)
    model = AEMS._replication_decision_model(template, sys, t; optimizer = STOCK_OPTIMIZER, name = "standalone")
    @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
    @test PSI.solve!(model) == PSI.RunStatus.SUCCESSFULLY_FINALIZED
    results = PSI.OptimizationProblemResults(model)
    return (;
        objective = PSI.JuMP.objective_value(PSI.get_jump_model(model)),
        solved = stock_at(AEMS._solved_tables(results, sys, REPLICATION_PARTS), t),
        capacities = stock_fcas_capacities(results, t),
        prices = stock_fcas_prices(results, sys, t),
    )
end
# Step 2 changes Alta's RAISEREG MaxAvail (15 -> 8 MW), turns its AGC off (RAISEREG disabled),
# strands Park City below its RAISE6SEC EnablementMin and moves the battery from 5 MW to -15 MW net.
const FCAS_CHANGES = (alta_reg_avail = [15.0, 8.0], alta_agc = [1, 0], park_initial = [40.0, 2.0], batt_initial = [5.0, -15.0])

@testset "FCAS trapezium, enablement and AGC status change between steps: simulation equals standalone solves" begin
    sim = stock_simulate(fcas_toy_system(; FCAS_CHANGES...))
    @test PSI.has_container_key(PSI.get_optimization_container(sim.model), FCASSideCapacityVariable, FCASService, "1_RAISEREG_gen")
    capacities = [stock_fcas_capacities(sim.results, t) for t in STOCK_STEPS]
    prices = [stock_fcas_prices(sim.results, fcas_toy_system(; FCAS_CHANGES...), t) for t in STOCK_STEPS]
    for (k, t) in enumerate(STOCK_STEPS)
        ref = stock_fcas_standalone(fcas_toy_system(; FCAS_CHANGES...), t)
        @test sim.objectives[k] ≈ ref.objective atol = TOY_TOLERANCE
        @test stock_price(sim.solved[k]) ≈ stock_price(ref.solved) atol = TOY_TOLERANCE
        for duid in ref.solved.dispatch.DUID
            @test stock_mw(sim.solved[k], duid) ≈ stock_mw(ref.solved, duid) atol = TOY_TOLERANCE
        end
        @test keys(capacities[k]) == keys(ref.capacities)
        for (cell, mw) in ref.capacities
            @test capacities[k][cell] ≈ mw atol = TOY_TOLERANCE
        end
        @test keys(prices[k]) == keys(ref.prices)
        for (market, rop) in ref.prices
            @test prices[k][market] ≈ rop atol = TOY_TOLERANCE
        end
    end
    # Step 2 reads step-2 data: Alta's RAISEREG is disabled and Park City's RAISE6SEC stranded.
    @test capacities[1]["1_RAISEREG $TOY_CHEAP"] > 1.0
    @test capacities[2]["1_RAISEREG $TOY_CHEAP"] ≈ 0.0 atol = TOY_TOLERANCE
    @test capacities[1]["1_RAISE6SEC $TOY_EXPENSIVE"] > 1.0
    @test capacities[2]["1_RAISE6SEC $TOY_EXPENSIVE"] ≈ 0.0 atol = TOY_TOLERANCE
    @test capacities[2]["1_RAISEREG_gen $TOY_BATTERY"] + capacities[2]["1_RAISEREG_load $TOY_BATTERY"] ≈ 20.0 atol = TOY_TOLERANCE

    rev = stock_simulate(fcas_toy_system(; reverse_order = true, FCAS_CHANGES...))
    for k in 1:2
        @test rev.objectives[k] ≈ sim.objectives[3 - k] atol = TOY_TOLERANCE
        reversed = stock_fcas_capacities(rev.results, STOCK_STEPS[k])
        for (cell, mw) in capacities[3 - k]
            @test reversed[cell] ≈ mw atol = TOY_TOLERANCE
        end
    end
end

@testset "a recurrent FCAS build updates the slope coefficients and stores the offer parameters" begin
    sim = stock_simulate(fcas_toy_system(; alta_reg_avail = [15.0, 8.0]))
    container = PSI.get_optimization_container(sim.model)
    con = PSI.get_constraint(container, FCASJointCapacityConstraint(), FCASService, "1_RAISEREG_upper")
    cap = PSI.get_variable(container, FCASCapacityVariable(), FCASService, "1_RAISEREG")
    # Alta's RAISEREG UpperSlopeCoeff after step 2: (95 - 80) / 8, not step 1's (95 - 80) / 15.
    @test PSI.JuMP.normalized_coefficient(con[TOY_CHEAP, 1], cap[TOY_CHEAP, 1]) ≈ 15.0 / 8.0
    slope = only(values(PSI.read_realized_parameters(sim.results, ["FCASUpperSlopeParameter__ThermalStandard__RAISEREG"])))
    @test sort(filter(:name => ==(TOY_CHEAP), slope), :DateTime).value ≈ [15.0 / 15.0, 15.0 / 8.0]
end

# Price-tied $10 bands of Alta (100 then 40 MW), Park City (50 MW) and Solitude (80 then 0 MW) behind
# Brighton's 60 MW at $5, for 150 then 120 MW of load. `park_price` is Park City's band price per step.
const TIE_THIRD = "Solitude"
function tie_sentinel_system(; reverse_order = false, park_price = [10.0, 10.0])
    r(x) = reverse_order ? reverse(x) : x
    units = [
        TOY_CHEAP => toy_unit(100.0, r([[(100.0, 10.0)], [(40.0, 10.0)]]); initial = 0.0, ramp_up = 100.0),
        TOY_EXPENSIVE => toy_unit(50.0, r([[(50.0, p)] for p in park_price]); initial = 0.0, ramp_up = 100.0),
        TIE_THIRD => toy_unit(80.0, r([[(80.0, 10.0)], [(0.0, 10.0)]]); initial = 0.0, ramp_up = 100.0),
        BINDING_MID => toy_unit(60.0, [(60.0, 5.0)]; initial = 0.0, ramp_up = 100.0),
    ]
    return nem_toy_system(units, r([150.0, 120.0]); horizon = TOY_RESOLUTION)
end

@testset "tie-break widths change between steps, one band empty in step 2: simulation equals standalone solves" begin
    sim = stock_simulate(tie_sentinel_system())
    expected = [
        (cheap = 90.0 * 100.0 / 230.0, park = 90.0 * 50.0 / 230.0, third = 90.0 * 80.0 / 230.0, objective = 100.0),
        (cheap = 60.0 * 40.0 / 90.0, park = 60.0 * 50.0 / 90.0, third = 0.0, objective = 75.0),
    ]
    for (k, t) in enumerate(STOCK_STEPS)
        ref = stock_standalone(tie_sentinel_system(), t)
        @test sim.objectives[k] ≈ ref.objective atol = TOY_TOLERANCE
        @test stock_price(sim.solved[k]) ≈ stock_price(ref.solved) atol = TOY_TOLERANCE
        for duid in ref.solved.dispatch.DUID
            @test stock_mw(sim.solved[k], duid) ≈ stock_mw(ref.solved, duid) atol = 1.0e-5
        end
        e = expected[k]
        @test stock_mw(sim.solved[k], TOY_CHEAP) ≈ e.cheap atol = 1.0e-5
        @test stock_mw(sim.solved[k], TOY_EXPENSIVE) ≈ e.park atol = 1.0e-5
        @test stock_mw(sim.solved[k], TIE_THIRD) ≈ e.third atol = 1.0e-5
        @test stock_mw(sim.solved[k], BINDING_MID) ≈ 60.0 atol = 1.0e-5
        @test stock_price(sim.solved[k]) ≈ 10.0 atol = TOY_TOLERANCE
        @test sim.objectives[k] ≈ e.objective atol = 1.0e-4
    end
    scales = only(values(PSI.read_realized_parameters(sim.results, ["TieBreakScaleParameter__ThermalStandard__1"])))
    scale(name) = sort(filter(:name => ==(name), scales), :DateTime).value
    @test scale(TOY_CHEAP) ≈ [1.0, 0.8]
    @test scale(TOY_EXPENSIVE) ≈ [0.5, 1.0]
    @test scale(TIE_THIRD) ≈ [0.8, 0.0]

    rev = stock_simulate(tie_sentinel_system(; reverse_order = true))
    for k in 1:2, d in (TOY_CHEAP, TOY_EXPENSIVE, TIE_THIRD)
        @test stock_mw(rev.solved[k], d) ≈ stock_mw(sim.solved[3 - k], d) atol = 1.0e-5
    end
end

@testset "the tie-break pre-flight check" begin
    moved = tie_sentinel_system(; park_price = [10.0, 12.0])
    @test_throws ArgumentError check_tie_break_pairs(moved, STOCK_STEPS)
    @test_throws ArgumentError AEMS._replication_simulation(moved, STOCK_STEPS; optimizer = STOCK_OPTIMIZER)
    @test isnothing(check_tie_break_pairs(tie_sentinel_system(), STOCK_STEPS))
    # Prices change between steps, but no band is ever tied.
    @test isnothing(check_tie_break_pairs(sentinel_system(), STOCK_STEPS))
end

# Alta ($20, 100 MW) and Park City ($80, 100 MW) offer RAISEREG on rectangles: Alta 25 MW at $5, Park City 20 MW at $10.
# Alta's AGC ramp rate is `alta_ramp` MW/h (360 MW/h is 30 MW per interval); `F_REG` requires `reg_req` MW.
function reg_ramp_system(;
        alta_initial = [60.0, 40.0], load_mw = [50.0, 60.0], alta_ramp = [360.0, 360.0], reg_req = [20.0, 20.0], weight = 1.0,
    )
    units = [
        TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = alta_initial, ramp_up = 100.0),
        TOY_EXPENSIVE => toy_unit(100.0, [(100.0, 80.0)]; initial = 0.0, ramp_up = 100.0),
    ]
    return nem_toy_system(
        units, load_mw; horizon = TOY_RESOLUTION, mutate! = (sys, stamps) -> begin
            alta = PSY.get_component(PSY.ThermalStandard, sys, TOY_CHEAP)
            park = PSY.get_component(PSY.ThermalStandard, sys, TOY_EXPENSIVE)
            add_toy_fcas_offer!(sys, alta, stamps, BidType.RAISEREG, fill((0.0, 0.0, 100.0, 100.0, 25.0), 2), fill([(25.0, 5.0)], 2))
            add_toy_fcas_offer!(sys, park, stamps, BidType.RAISEREG, fill((0.0, 0.0, 100.0, 100.0, 20.0), 2), fill([(20.0, 10.0)], 2))
            add_toy_series!(sys, alta, stamps, "fcas_agc_ramp_rate_RAISEREG", alta_ramp)
            add_toy_fcas_market!(sys, stamps, BidType.RAISEREG, [TOY_CHEAP, TOY_EXPENSIVE], "F_REG", reg_req)
            set_constraint_weight!(PSY.get_component(GenericConstraint, sys, "F_REG"), weight)
        end,
    )
end

# Alta ($20) meets a 50 MW load; the battery offers RAISEREG on both sides (10 MW at $3 generation, 10 MW at $4 load) and Park City 20 MW at $10.
# Energy offers are 50 MW at `batt_gen_price` (MAXAVAIL `gen_avail`) and 50 MW at $0 (MAXAVAIL `load_avail`); `batt_ramp` is the AGC ramp rate in MW/h.
function bdu_reg_system(;
        batt_initial = 10.0, batt_gen_price = 30.0, gen_avail = 50.0, load_avail = 50.0,
        gen_trap = fill((0.0, 0.0, 50.0, 50.0, 10.0), 2), load_trap = fill((-50.0, -50.0, 0.0, 0.0, 10.0), 2),
        batt_ramp = nothing, reg_req = [18.0, 18.0], alta_initial = 50.0,
    )
    units = [
        TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = alta_initial, ramp_up = 100.0),
        TOY_EXPENSIVE => toy_unit(100.0, [(100.0, 80.0)]; initial = 0.0, ramp_up = 100.0),
    ]
    batteries = [
        TOY_BATTERY => toy_battery(
            50.0, batt_gen_price, 50.0, 0.0; initial = batt_initial, ramp_up = 100.0, gen_avail = gen_avail, load_avail = load_avail,
        ),
    ]
    return nem_toy_system(
        units, 50.0; batteries, horizon = TOY_RESOLUTION, mutate! = (sys, stamps) -> begin
            park = PSY.get_component(PSY.ThermalStandard, sys, TOY_EXPENSIVE)
            bat = PSY.get_component(PSY.EnergyReservoirStorage, sys, TOY_BATTERY)
            add_toy_fcas_offer!(sys, park, stamps, BidType.RAISEREG, fill((0.0, 0.0, 100.0, 100.0, 20.0), 2), fill([(20.0, 10.0)], 2))
            add_toy_fcas_offer!(sys, bat, stamps, BidType.RAISEREG, gen_trap, fill([(10.0, 3.0)], 2))
            add_toy_fcas_offer!(sys, bat, stamps, BidType.RAISEREG, load_trap, fill([(10.0, 4.0)], 2); decremental = true)
            isnothing(batt_ramp) || add_toy_series!(sys, bat, stamps, "fcas_agc_ramp_rate_RAISEREG", batt_ramp)
            add_toy_fcas_market!(sys, stamps, BidType.RAISEREG, [TOY_EXPENSIVE, TOY_BATTERY], "F_REG", reg_req)
        end,
    )
end

# The battery generates its 5 MW GEN MAXAVAIL at $10; its load side is enabled in step 1 only (LOAD MAXAVAIL `load_avail`).
# Generation trapezium (0, Low, 40, 50, 10) with Low `gen_low` gives LowerSlopeCoeff `Low / 10`; the step-2 load trapezium is unreachable.
function bdu_stranded_system(; gen_low = [10.0, 6.25], load_avail = [50.0, 5.0])
    return bdu_reg_system(;
        batt_initial = 5.0, batt_gen_price = 10.0, gen_avail = 5.0, load_avail, alta_initial = 45.0, reg_req = [12.0, 12.0],
        gen_trap = [(0.0, low, 40.0, 50.0, 10.0) for low in gen_low],
        load_trap = [(-50.0, -50.0, 0.0, 0.0, 10.0), (-50.0, -50.0, -10.0, -10.0, 10.0)],
    )
end

# Realized values of a simulation parameter (`field` for a field axis) or variable for `name`, in step
# order, times `scale` (100 MW base for MW quantities).
function stock_realized(results, key, name; field = nothing, scale = 100.0, parameter = true)
    frames = parameter ? PSI.read_realized_parameters(results, [key]) : PSI.read_realized_variables(results, [key])
    df = filter(r -> r.name == name && (isnothing(field) || r.name2 == field), only(values(frames)))
    return sort(df, :DateTime).value .* scale
end

# Checks `build()` run as a two-step simulation and as two standalone solves against `expected[k]` in each step.
# Fields: `objective` ($ per interval), `price`, `mw` (DUID => MW), `cap` (capacity cell => MW), `fcas` (RAISEREG price).
function stock_fcas_case(build, expected)
    sys = build()
    sim = stock_simulate(sys)
    @test PSI.built_for_recurrent_solves(PSI.get_optimization_container(sim.model))
    for (k, t) in enumerate(STOCK_STEPS)
        e = expected[k]
        ref = stock_fcas_standalone(build(), t)
        run_sim = (;
            objective = sim.objectives[k], solved = sim.solved[k],
            capacities = stock_fcas_capacities(sim.results, t), prices = stock_fcas_prices(sim.results, sys, t),
        )
        for run in (run_sim, ref)
            @test run.objective ≈ e.objective atol = TOY_TOLERANCE
            @test stock_price(run.solved) ≈ e.price atol = TOY_TOLERANCE
            for (duid, mw) in e.mw
                @test stock_mw(run.solved, duid) ≈ mw atol = TOY_TOLERANCE
            end
            for (cell, mw) in e.cap
                @test run.capacities[cell] ≈ mw atol = TOY_TOLERANCE
            end
            @test run.prices[("1", BidType.RAISEREG)] ≈ e.fcas atol = TOY_TOLERANCE
        end
    end
    return sim, sys
end

@testset "FCAS joint ramping (§6.1) binds in step 2 only: simulation equals standalone solves" begin
    # Joint ramping RHS = InitialMW + 30 MW: 60 + 30 = 90 in step 1, 40 + 30 = 70 in step 2.
    expected = [
        (
            objective = 1100 / 12, price = 20.0, fcas = 5.0, mw = [TOY_CHEAP => 50.0, TOY_EXPENSIVE => 0.0],
            cap = ["1_RAISEREG $TOY_CHEAP" => 20.0, "1_RAISEREG $TOY_EXPENSIVE" => 0.0],
        ),
        (
            objective = 1350 / 12, price = 25.0, fcas = 10.0, mw = [TOY_CHEAP => 60.0, TOY_EXPENSIVE => 0.0],
            cap = ["1_RAISEREG $TOY_CHEAP" => 10.0, "1_RAISEREG $TOY_EXPENSIVE" => 10.0],
        ),
    ]
    sim, _ = stock_fcas_case(reg_ramp_system, expected)
    rhs = stock_realized(sim.results, "FCASRampingLimitParameter__ThermalStandard__RAISEREG", TOY_CHEAP; field = "joint_ramping")
    @test rhs ≈ [90.0, 70.0] atol = TOY_TOLERANCE
    # Energy + RaiseReg is 70 MW in both steps: slack in step 1, at the RHS in step 2.
    @test rhs[1] - (50.0 + 20.0) ≈ 20.0 atol = TOY_TOLERANCE
    @test rhs[2] - (60.0 + 10.0) ≈ 0.0 atol = TOY_TOLERANCE
    slack = stock_realized(sim.results, "FCASJointRampingSlack__FCASService__1_RAISEREG", TOY_CHEAP; parameter = false)
    @test all(abs.(slack) .<= TOY_TOLERANCE)
    # Step 2 with step 1's InitialMW (a stale RHS of 90 MW) gives Alta all 20 MW at $5.
    stale = stock_fcas_standalone(reg_ramp_system(; alta_initial = [60.0, 60.0]), STOCK_STEPS[2])
    @test stale.objective ≈ 1300 / 12 atol = TOY_TOLERANCE
    @test stale.prices[("1", BidType.RAISEREG)] ≈ 5.0 atol = TOY_TOLERANCE
    @test stock_price(stale.solved) ≈ 20.0 atol = TOY_TOLERANCE
end

@testset "BDU SCADA ramping (§6.4) binds in step 2 only: simulation equals standalone solves" begin
    # AGC ramp 360 then 180 MW/h: BDU RHS 30 then 15 MW; each side's MaxAvail stays 10 MW.
    expected = [
        (
            objective = 1062 / 12, price = 20.0, fcas = 4.0, mw = [TOY_CHEAP => 50.0, TOY_BATTERY => 0.0, TOY_EXPENSIVE => 0.0],
            cap = ["1_RAISEREG_gen $TOY_BATTERY" => 10.0, "1_RAISEREG_load $TOY_BATTERY" => 8.0, "1_RAISEREG $TOY_EXPENSIVE" => 0.0],
        ),
        (
            objective = 1080 / 12, price = 20.0, fcas = 10.0, mw = [TOY_CHEAP => 50.0, TOY_BATTERY => 0.0, TOY_EXPENSIVE => 0.0],
            cap = ["1_RAISEREG_gen $TOY_BATTERY" => 10.0, "1_RAISEREG_load $TOY_BATTERY" => 5.0, "1_RAISEREG $TOY_EXPENSIVE" => 3.0],
        ),
    ]
    build() = bdu_reg_system(; batt_ramp = [360.0, 180.0])
    sim, _ = stock_fcas_case(build, expected)
    key = "FCASRampingLimitParameter__EnergyReservoirStorage__RAISEREG"
    @test stock_realized(sim.results, key, TOY_BATTERY; field = "bdu_ramping") ≈ [30.0, 15.0] atol = TOY_TOLERANCE
    # §6.1 for the battery: InitialMW 10 + 30, then 10 + 15; never binding (net energy 0).
    @test stock_realized(sim.results, key, TOY_BATTERY; field = "joint_ramping") ≈ [40.0, 25.0] atol = TOY_TOLERANCE
    for name in ("FCASBDURampingSlack__FCASService__1_RAISEREG", "FCASJointRampingSlack__FCASService__1_RAISEREG")
        @test all(abs.(stock_realized(sim.results, name, TOY_BATTERY; parameter = false)) .<= TOY_TOLERANCE)
    end
    # Step 2 with step 1's 30 MW BDU RHS repeats step 1's dispatch.
    stale = stock_fcas_standalone(bdu_reg_system(; batt_ramp = [360.0, 360.0]), STOCK_STEPS[2])
    @test stale.objective ≈ 1062 / 12 atol = TOY_TOLERANCE
    @test stale.prices[("1", BidType.RAISEREG)] ≈ 4.0 atol = TOY_TOLERANCE
    @test stale.capacities["1_RAISEREG_load $TOY_BATTERY"] ≈ 8.0 atol = TOY_TOLERANCE
end

@testset "a both-sided battery loses its load side in step 2: the lower slope enters as -LowerSlopeCoeff" begin
    # Generation-side EnablementMin row: 5 - LowerSlopeCoeff x RaiseRegGen >= 0, binding in both steps.
    expected = [
        (
            objective = 993 / 12, price = 20.0, fcas = 4.0, mw = [TOY_CHEAP => 45.0, TOY_BATTERY => 5.0, TOY_EXPENSIVE => 0.0],
            cap = ["1_RAISEREG_gen $TOY_BATTERY" => 5.0, "1_RAISEREG_load $TOY_BATTERY" => 7.0, "1_RAISEREG $TOY_EXPENSIVE" => 0.0],
        ),
        (
            objective = 1014 / 12, price = 20.0, fcas = 10.0, mw = [TOY_CHEAP => 45.0, TOY_BATTERY => 5.0, TOY_EXPENSIVE => 0.0],
            cap = ["1_RAISEREG_gen $TOY_BATTERY" => 8.0, "1_RAISEREG_load $TOY_BATTERY" => 0.0, "1_RAISEREG $TOY_EXPENSIVE" => 4.0],
        ),
    ]
    sim, _ = stock_fcas_case(bdu_stranded_system, expected)
    gen_slope = stock_realized(sim.results, "FCASLowerSlopeParameter__EnergyReservoirStorage__RAISEREG", TOY_BATTERY; scale = 1.0)
    @test gen_slope ≈ [1.0, 0.625] atol = TOY_TOLERANCE
    limits = "FCASOfferLimitParameter__EnergyReservoirStorage__RAISEREG_decremental"
    @test stock_realized(sim.results, limits, TOY_BATTERY; field = "max_avail") ≈ [10.0, 0.0] atol = TOY_TOLERANCE
    @test stock_realized(sim.results, limits, TOY_BATTERY; field = "enablement_min") ≈ [-50.0, -FCAS_INACTIVE_LIMIT_MW] atol = TOY_TOLERANCE
    # After step 2: the generation side's capacity enters its EnablementMin row at -0.625, the disabled load side's at 0.
    container = PSI.get_optimization_container(sim.model)
    coefficient(side) = PSI.JuMP.normalized_coefficient(
        PSI.get_constraint(container, FCASJointCapacityConstraint(), FCASService, "1_RAISEREG_$(side)_lower")[TOY_BATTERY, 1],
        PSI.get_variable(container, FCASSideCapacityVariable(), FCASService, "1_RAISEREG_$side")[TOY_BATTERY, 1],
    )
    @test coefficient("gen") ≈ -0.625 atol = TOY_TOLERANCE
    @test coefficient("load") ≈ 0.0 atol = TOY_TOLERANCE
    for (k, cap) in enumerate((5.0, 8.0))
        @test 5.0 - gen_slope[k] * cap ≈ 0.0 atol = TOY_TOLERANCE
    end
    # Stale step-2 inputs: step 1's slope 1 caps the generation side at 5 MW; step 1's enablement
    # keeps the load side, trapped at -10 MW, so the battery charges 10 MW.
    slope_stale = stock_fcas_standalone(bdu_stranded_system(; gen_low = [10.0, 10.0]), STOCK_STEPS[2])
    @test slope_stale.objective ≈ 1035 / 12 atol = TOY_TOLERANCE
    @test slope_stale.capacities["1_RAISEREG $TOY_EXPENSIVE"] ≈ 7.0 atol = TOY_TOLERANCE
    enable_stale = stock_fcas_standalone(bdu_stranded_system(; load_avail = [50.0, 50.0]), STOCK_STEPS[2])
    @test enable_stale.objective ≈ 1190 / 12 atol = TOY_TOLERANCE
    @test enable_stale.prices[("1", BidType.RAISEREG)] ≈ 4.0 atol = TOY_TOLERANCE
    @test stock_mw(enable_stale.solved, TOY_BATTERY) ≈ -5.0 atol = TOY_TOLERANCE
end

@testset "an FCAS requirement short in step 2 only is priced at its CVP and reported in step 2 only" begin
    # F_REG weight 10 (RREG requirement CVP factor) x MPC $17,500 = $175,000/MW; 60 MW asked, 45 MW offered.
    build() = reg_ramp_system(; alta_initial = [50.0, 50.0], load_mw = [50.0, 50.0], reg_req = [20.0, 60.0], weight = 10.0)
    expected = [
        (
            objective = 1100 / 12, price = 20.0, fcas = 5.0, mw = [TOY_CHEAP => 50.0, TOY_EXPENSIVE => 0.0],
            cap = ["1_RAISEREG $TOY_CHEAP" => 20.0, "1_RAISEREG $TOY_EXPENSIVE" => 0.0],
        ),
        (
            objective = 2_626_325 / 12, price = 20.0, fcas = 175_000.0, mw = [TOY_CHEAP => 50.0, TOY_EXPENSIVE => 0.0],
            cap = ["1_RAISEREG $TOY_CHEAP" => 25.0, "1_RAISEREG $TOY_EXPENSIVE" => 20.0],
        ),
    ]
    sim, sys = stock_fcas_case(build, expected)
    # The stored generic constraint slack is already in MW.
    slack = stock_realized(sim.results, "GenericConstraintSlackDown__GenericConstraint__F_REG", "F_REG"; parameter = false, scale = 1.0)
    @test slack ≈ [0.0, 15.0] atol = TOY_TOLERANCE
    v = AEMS._constraint_violations(sim.results, sys)
    @test nrow(v) == 1
    row = only(eachrow(v))
    @test (row.family, row.name, row.DateTime, row.direction) == ("generic_constraint", "F_REG", STOCK_STEPS[2], "down")
    @test row.MW ≈ 15.0 atol = TOY_TOLERANCE
    # The unit FCAS slacks (CVP 70 to 155) stay at zero.
    @test !any(startswith("fcas_"), v.family)
    # Step 2 with step 1's 20 MW requirement has no violation and repeats step 1.
    stale = stock_fcas_standalone(reg_ramp_system(; alta_initial = [50.0, 50.0], load_mw = [50.0, 50.0], weight = 10.0), STOCK_STEPS[2])
    @test stale.objective ≈ 1100 / 12 atol = TOY_TOLERANCE
    @test stale.prices[("1", BidType.RAISEREG)] ≈ 5.0 atol = TOY_TOLERANCE
end

# Thirty generic constraints on one unit: even ones are slack-free; odd ones require 150 MW of a 100 MW
# unit (GE), so their down slack carries the violation in both steps.
@testset "the batched slack read equals the per-key read on a result with many slack keys" begin
    n = 30
    add_constraint!(sys, stamps, i) = isodd(i) ?
        add_toy_generic_constraint!(sys, stamps, TOY_CHEAP, 150.0; sense = ConstraintSense.GE, name = "N_MANY_$i") :
        add_toy_generic_constraint!(sys, stamps, TOY_CHEAP, 200.0; name = "N_MANY_$i")
    sys = nem_toy_system(
        [
            TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = 50.0, ramp_up = 100.0),
            TOY_EXPENSIVE => toy_unit(100.0, [(100.0, 80.0)]; initial = 0.0, ramp_up = 100.0),
        ],
        [100.0, 120.0]; horizon = TOY_RESOLUTION,
        mutate! = (sys, stamps) -> foreach(i -> add_constraint!(sys, stamps, i), 1:n),
    )
    out = AEMS._replication_simulation(sys, STOCK_STEPS; optimizer = STOCK_OPTIMIZER)
    slack_families = Dict(AEMS._VIOLATION_FAMILIES)
    keys = [k for k in PSI.list_variable_keys(out.results) if haskey(slack_families, PSI.IS.Optimization.get_entry_type(k))]
    @test length(keys) >= n
    batched = AEMS._read_variable_frames(out.results, keys)
    @test Set(Base.keys(batched)) == Set(keys)
    # The old per-key read: one `read_variable` per encoded name, each reopening the store.
    per_key(key) = reduce(vcat, values(PSI.read_variable(out.results, PSI.IS.Optimization.encode_key_as_string(key))))
    for key in keys[[1, cld(length(keys), 2), length(keys)]]
        @test batched[key] == per_key(key)
    end
    violated = [k for k in keys if any(>(AEMS._VIOLATION_TOLERANCE_MW), batched[k].value)]
    @test length(violated) == n ÷ 2
    @test isempty(AEMS._read_variable_frames(out.results, PSI.OptimizationContainerKey[]))
end

@testset "the batched dual read equals the per-key read for the FCAS requirement duals" begin
    sys = fcas_toy_system(; FCAS_CHANGES...)
    sim = stock_simulate(sys)
    keys = [k for k in PSI.list_dual_keys(sim.results) if PSI.IS.Optimization.get_entry_type(k) === AEMS.NEMConstraintLimit]
    @test length(keys) >= 3
    batched = AEMS._read_dual_frames(sim.results, keys)
    @test Set(Base.keys(batched)) == Set(keys)
    # The per-key read: one `read_realized_duals` per key, each reopening the store.
    for key in keys
        @test batched[key] == only(values(PSI.read_realized_duals(sim.results, [key])))
    end
    @test isempty(AEMS._read_dual_frames(sim.results, PSI.OptimizationContainerKey[]))
end

@testset "replication_template follows parts and exclude_constraints" begin
    sys = fcas_toy_system()
    full = replication_template(sys)
    @test haskey(PSI.get_device_models(full), :EnergyReservoirStorage)
    # Without :fcas the FCAS requirements need an unmodeled market and are reported, not built.
    skipped = @NamedTuple{constraint::String, reason::Symbol, n_missing::Int}[]
    no_fcas = replication_template(sys; parts = (:batteries, :generic_constraints), skipped = skipped)
    @test isempty(AEMS._modeled_fcas_services(no_fcas))
    @test Set(r.constraint for r in skipped) == Set(["F_REG", "F_R6", "F_L6"])
    @test all(r -> r.reason == :unmodeled_fcas_service, skipped)
    @test !any(((name, _),) -> name == TIE_BREAK_SERVICE_NAME, keys(PSI.get_service_models(no_fcas)))
    # Without :batteries no storage model is set.
    no_batteries = replication_template(sentinel_system(); parts = (:generic_constraints,))
    @test !haskey(PSI.get_device_models(no_batteries), :EnergyReservoirStorage)
    # exclude_constraints leaves a constraint out with its reason, and rejects an unknown name.
    skipped = @NamedTuple{constraint::String, reason::Symbol, n_missing::Int}[]
    excluded = replication_template(sentinel_system(); skipped, exclude_constraints = Dict("N_TOY_LIMIT" => :never_invoked))
    @test only(skipped) == (constraint = "N_TOY_LIMIT", reason = :never_invoked, n_missing = 0)
    @test !any(((name, _),) -> name == "N_TOY_LIMIT", keys(PSI.get_service_models(excluded)))
    @test_throws r"exclude_constraints names N_ABSENT" replication_template(sentinel_system(); exclude_constraints = Dict("N_ABSENT" => :x))
    @test_throws r"unknown parts" replication_template(sentinel_system(); parts = (:batteries, :nonsense))
end

@testset "tie-breaks without batteries fail when a battery carries tie-break scales" begin
    # Alta and the battery offer generation at the same $30, so their bands are tied.
    units = [TOY_CHEAP => toy_unit(100.0, [(100.0, 30.0)]; initial = 30.0, ramp_up = 100.0)]
    batteries = [TOY_BATTERY => toy_battery(50.0, 30.0, 50.0, 1.0; initial = 0.0, ramp_up = 100.0)]
    sys = nem_toy_system(units, 60.0; batteries, horizon = TOY_RESOLUTION)
    @test_throws r"carry tie-break scales; add :batteries" replication_template(sys; parts = (:tie_breaks,))
    @test !any(((name, _),) -> name == TIE_BREAK_SERVICE_NAME, keys(PSI.get_service_models(replication_template(sys; parts = ()))))
    @test any(((name, _),) -> name == TIE_BREAK_SERVICE_NAME, keys(PSI.get_service_models(replication_template(sys; parts = (:batteries, :tie_breaks)))))
end

@testset "replicate_range respects parts on the mock cache" begin
    db = aem_connect(HiveConfiguration(hive_location = AEM_TEST_REPLAY_HIVE_DIR, filesystem = "file"))
    t1, t2 = DateTime(2025, 1, 1, 0, 5), DateTime(2025, 1, 1, 0, 10)
    result = replicate_range(db, t1, t2; parts = (:generic_constraints,))
    types = Set(PSI.IS.Optimization.get_component_type(k) for k in PSI.list_variable_keys(only(result.results)))
    @test !(PSY.EnergyReservoirStorage in types) && !(PSY.AreaInterchange in types)
    @test !any(k -> PSI.IS.Optimization.get_entry_type(k) === FCASCapacityVariable, PSI.list_variable_keys(only(result.results)))
    @test all(ismissing, result.comparison.interconnectors.MWFLOW_solved)
    @test all(ismissing, result.comparison.fcas_prices.ROP_solved)
    @test any(in((:unmodeled_fcas_service, :unmodeled_device_type)), result.skipped_constraints.reason)
    @test any(!ismissing, result.comparison.dispatch.TOTALCLEARED_solved)
end

@testset "named errors of the replay core" begin
    # A constraint on a unit absent from the system blocks a partial template; a left-out family does not.
    ghost = nem_toy_system(
        [TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = 50.0, ramp_up = 100.0)], 50.0;
        horizon = TOY_RESOLUTION, mutate! = (sys, stamps) -> begin
            gc = GenericConstraint(;
                name = "N_GHOST", sense = ConstraintSense.LE, rhs = 1.0, terms = ConstraintTerm[UnitTerm("GHOST", BidType.ENERGY, 1.0)],
            )
            PSY.add_service!(sys, gc, [PSY.get_component(PSY.ThermalStandard, sys, TOY_CHEAP)])
            add_toy_series!(sys, gc, stamps, "rhs", [100.0, 100.0])
            add_toy_series!(sys, gc, stamps, "invoked", [1.0, 1.0]; scale = 1.0)
        end,
    )
    @test_throws r"cannot model: N_GHOST \(missing_component\)" replication_template(ghost; parts = (:generic_constraints,))
    # Losses modeled but no interchange variable in the results.
    sys = loss_sentinel_system()
    uncoupled = stock_standalone(sys, TOY_START; parts = ())
    @test_throws r"Losses are modeled" AEMS._solved_tables(uncoupled.results, sys, REPLICATION_PARTS)
    @test nrow(AEMS._solved_tables(uncoupled.results, sys, ()).interconnectors) == 0
    @test_throws r"non-finite regional price" AEMS._check_prices_finite(
        DataFrame(SETTLEMENTDATE = [TOY_START], REGIONID = ["1"], ROP = [NaN]),
    )
    db = aem_connect(HiveConfiguration(hive_location = AEM_TEST_REPLAY_HIVE_DIR, filesystem = "file"))
    @test_throws r"at least two stamps" replication_system(db, TOY_START:Minute(5):TOY_START)
    @test_throws r"must step by" replication_system(db, TOY_START:Minute(10):(TOY_START + Minute(20)))
    # A write cache size reaches the simulation store.
    small = replicate_range(db, DateTime(2025, 1, 1, 0, 5), DateTime(2025, 1, 1, 0, 5); cache_size_mib = 16)
    @test small.chunks.n_steps == [1] && nrow(small.solver_stats) == 1
end
