# Recurrent replay of `replicate_range`; expected values are hand-derived on the toy fixture (100 MW base power).
# The toy systems are one area unless built with an `interchange`.

# Zero MIP gaps: the loss and MNSP encodings are MILPs, and a default gap can stop short of the optimum.
const STOCK_OPTIMIZER = PSI.JuMP.optimizer_with_attributes(
    HiGHS.Optimizer, "output_flag" => false, "mip_rel_gap" => 0.0, "mip_abs_gap" => 1.0e-10,
)
const STOCK_STEPS = TOY_START:TOY_RESOLUTION:(TOY_START + TOY_RESOLUTION)
const STOCK_PARTS = AEMS._RECURRENT_PARTS
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
# One standalone one-interval solve of the replication template at `t`.
function stock_standalone(sys, t)
    template = replication_template(sys; parts = STOCK_PARTS)
    model = AEMS._replication_decision_model(
        template, sys, t; optimizer = STOCK_OPTIMIZER, name = "standalone", parts = STOCK_PARTS,
    )
    @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
    @test PSI.solve!(model) == PSI.RunStatus.SUCCESSFULLY_FINALIZED
    results = PSI.OptimizationProblemResults(model)
    return (;
        objective = PSI.JuMP.objective_value(PSI.get_jump_model(model)),
        solved = AEMS._solved_interval(AEMS._solved_frames(results, sys; losses = false), sys, t),
    )
end
# The simulation, its per-step objectives and solved tables.
function stock_simulate(sys)
    out = AEMS._replication_simulation(sys, STOCK_STEPS; optimizer = STOCK_OPTIMIZER)
    frames = AEMS._solved_frames(out.results, sys; losses = false)
    return (;
        out...,
        objectives = PSI.read_optimizer_stats(out.results).objective_value,
        solved = [AEMS._solved_interval(frames, sys, t) for t in STOCK_STEPS],
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

@testset "the envelope pre-flight check" begin
    # Interval 2: Alta floor 55 MW above availability 0 MW.
    bad = sentinel_system(; alta_availability = [100.0, 0.0], alta_initial = [60.0, 60.0], alta_ramp_down = [1.0, 1.0])
    template = replication_template(bad; parts = STOCK_PARTS)
    @test isnothing(check_dispatch_envelope(bad, template, TOY_START, 1))
    err = @test_throws ArgumentError check_dispatch_envelope(bad, template, TOY_START, 2)
    @test occursin("$(TOY_CHEAP) at interval 2", err.value.msg)
    @test !occursin(TOY_EXPENSIVE, err.value.msg)
    failure = try
        AEMS._replication_simulation(bad, STOCK_STEPS; optimizer = STOCK_OPTIMIZER)
    catch e
        e
    end
    @test failure isa ArgumentError && occursin("at interval 2", sprint(showerror, failure))
    # A standalone build keeps the build-time check.
    model = AEMS._replication_decision_model(
        template, bad, TOY_START + TOY_RESOLUTION; optimizer = STOCK_OPTIMIZER, name = "bad", parts = STOCK_PARTS,
    )
    @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.FAILED
    @test AEMS._first_envelope_violation([1.0, 1.0], [0.0, 0.0], [2.0, 0.5], 5) == (2, 1.0, 0.5) &&
        isnothing(AEMS._first_envelope_violation([1.0], [0.1], [0.5], 5))
end

@testset "a constraint invoked at no step is left out and reported with its reason" begin
    never = sentinel_system(; invoked = [0.0, 0.0])
    @test AEMS._never_invoked_constraints(never, STOCK_STEPS) == Dict("N_TOY_LIMIT" => :never_invoked)
    @test AEMS._never_invoked_constraints(sentinel_system(; invoked = [1.0, 0.0]), STOCK_STEPS) == Dict{String, Symbol}()
    out_never = AEMS._replication_simulation(never, STOCK_STEPS; optimizer = STOCK_OPTIMIZER)
    row_never = only(filter(:constraint => ==("N_TOY_LIMIT"), out_never.skipped_constraints))
    @test (row_never.reason, row_never.stage) == (:never_invoked, :template)
end

@testset "argument checks" begin
    # The 2024-25 and 2025-26 Market Price Caps are 17,500 and 20,300.
    @test_throws ArgumentError AEMS._range_steps(TOY_START, TOY_START - TOY_RESOLUTION)
    @test_throws ArgumentError AEMS._range_steps(TOY_START, TOY_START + Minute(7))
    @test AEMS._range_steps(TOY_START, TOY_START) == TOY_START:TOY_RESOLUTION:TOY_START
    # The interval ending 00:00 on 1 July is the previous financial year's.
    @test isnothing(AEMS._check_single_market_price_cap(DateTime(2025, 6, 30, 23, 55):TOY_RESOLUTION:DateTime(2025, 7, 1)))
    @test_throws ArgumentError AEMS._check_single_market_price_cap(DateTime(2025, 7, 1):TOY_RESOLUTION:DateTime(2025, 7, 1, 0, 5))
    @test_throws ArgumentError AEMS._replication_simulation(sentinel_system(), STOCK_STEPS; parts = (:fcas,))
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
    model = AEMS._replication_decision_model(template, sys, t; optimizer = STOCK_OPTIMIZER, name = "masked", parts = STOCK_PARTS)
    @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
    @test PSI.solve!(model) == PSI.RunStatus.SUCCESSFULLY_FINALIZED
    results = PSI.OptimizationProblemResults(model)
    return (;
        results, objective = PSI.JuMP.objective_value(PSI.get_jump_model(model)),
        solved = AEMS._solved_interval(AEMS._solved_frames(results, sys; losses = false), sys, t),
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
    model = AEMS._replication_decision_model(template, sys, TOY_START; optimizer = STOCK_OPTIMIZER, name = "hard", parts = STOCK_PARTS)
    models = PSI.SimulationModels(; decision_models = [model])
    sim = PSI.Simulation(;
        name = "hard", steps = 2, models = models,
        sequence = PSI.SimulationSequence(; models = models, ini_cond_chronology = PSI.InterProblemChronology()),
        simulation_folder = mktempdir(), initial_time = TOY_START,
    )
    @test_throws ArgumentError PSI.build!(sim; store_systems_in_results = false)
end

@testset "replicate_range on the mock cache" begin
    db = aem_connect(HiveConfiguration(hive_location = AEM_TEST_HIVE_DIR, filesystem = "file"))
    t1, t2 = DateTime(2025, 1, 1, 0, 5), DateTime(2025, 1, 1, 0, 10)
    result = replicate_range(db, t1, t2)
    @test result.simulation isa PSI.Simulation
    c = result.comparison
    for table in (:prices, :dispatch, :interconnectors)
        @test first(names(c[table])) == "SETTLEMENTDATE" && Set(c[table].SETTLEMENTDATE) == Set([t1, t2])
        @test nrow(c[table]) == sum(nrow(read_published_interval(db, t)[table]) for t in (t1, t2))
    end
    @test all(isfinite, skipmissing(c.prices.ROP_solved)) && any(!ismissing, c.prices.ROP_solved)
    @test any(!ismissing, c.dispatch.TOTALCLEARED_solved)
    # Interchanges are modeled (the unavailable IC6 is not); FCAS is not.
    @test any(!ismissing, c.interconnectors.MWFLOW_solved)
    @test all(isfinite, skipmissing(c.interconnectors.MWLOSSES_solved))
    @test all(ismissing, filter(:INTERCONNECTORID => ==("IC6"), c.interconnectors).MWFLOW_solved)
    @test all(ismissing, c.fcas_prices.ROP_solved)
    # Invoked at 00:10 only over BW01-BW04: modeled now that batteries are, and masked at 00:05.
    @test !any(startswith("N_PARTIAL_COVERAGE"), result.skipped_constraints.constraint)
    duals = stock_gc_duals(result.results)
    partial = only(k for k in keys(duals) if startswith(k, "N_PARTIAL_COVERAGE"))
    @test duals[partial][t1] == 0.0
    @test any(!ismissing, c.dispatch.TOTALCLEARED_solved[c.dispatch.DUID .== "BW01"])
    # The MNSP IC2 is modeled with its link offers in both steps.
    links = only(values(PSI.read_realized_variables(result.results, ["MNSPLinkFlowVariable__AreaInterchange"])))
    @test Set(links.DateTime) == Set([t1, t2]) && all(>=(-1.0e-9), links.value)
    @test_throws ArgumentError replicate_range(db, t1, t1 - Minute(5))
end

# A battery whose net ramp-down floor raises its generation ceiling in step 1 only.
function battery_sentinel_system(; reverse_order = false, ceilings = true)
    r(x) = reverse_order ? reverse(x) : x
    units = [TOY_CHEAP => toy_unit(100.0, [(100.0, 50.0)]; initial = 30.0, ramp_up = 100.0)]
    batteries = [
        TOY_BATTERY => toy_battery(
            100.0, 5.0, 100.0, 1.0; initial = r([20.0, 0.0]), ramp_up = 100.0, ramp_down = 1.0, gen_avail = 10.0,
        ),
    ]
    return nem_toy_system(units, 40.0; batteries = batteries, horizon = TOY_RESOLUTION, ceilings = ceilings)
end

@testset "a replay battery's rows read its ceiling series and its bound is the chunk maximum" begin
    sys = battery_sentinel_system()
    battery = PSY.get_component(PSY.EnergyReservoirStorage, sys, TOY_BATTERY)
    @test PSY.get_time_series_values(PSY.SingleTimeSeries, battery, "storage_gen_ceiling") ≈ [0.15, 0.1] atol = TOY_TOLERANCE
    for (t, gen_mw) in zip(STOCK_STEPS, (15.0, 10.0))
        template = replication_template(sys; parts = STOCK_PARTS)
        model = AEMS._replication_decision_model(template, sys, t; optimizer = STOCK_OPTIMIZER, name = "ceilings", parts = STOCK_PARTS)
        @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
        container = PSI.get_optimization_container(model)
        row_mw(C) = PSI.JuMP.normalized_rhs(PSI.get_constraint(container, C(), PSY.EnergyReservoirStorage, "ub")[TOY_BATTERY, 1]) * 100.0
        bound_mw(V) = PSI.JuMP.upper_bound(PSI.get_variable(container, V(), PSY.EnergyReservoirStorage)[TOY_BATTERY, 1]) * 100.0
        @test row_mw(PSI.ActivePowerOutVariableTimeSeriesLimitsConstraint) ≈ gen_mw atol = TOY_TOLERANCE
        @test row_mw(PSI.ActivePowerInVariableTimeSeriesLimitsConstraint) ≈ 100.0 atol = TOY_TOLERANCE
        @test bound_mw(PSI.ActivePowerOutVariable) ≈ 15.0 atol = TOY_TOLERANCE
        @test bound_mw(PSI.ActivePowerInVariable) ≈ 100.0 atol = TOY_TOLERANCE
        @test !PSI.has_container_key(container, PSI.ActivePowerVariableLimitsConstraint, PSY.EnergyReservoirStorage, "out")
    end
    # Without the ceiling series a replay build fails, and the logged error names set_storage_dispatch_ceilings!.
    bare = battery_sentinel_system(; ceilings = false)
    model = AEMS._replication_decision_model(
        replication_template(bare; parts = STOCK_PARTS), bare, TOY_START; optimizer = STOCK_OPTIMIZER, name = "bare", parts = STOCK_PARTS,
    )
    folder = mktempdir()
    @test PSI.build!(model; output_dir = folder) == PSI.ModelBuildStatus.FAILED
    @test any(f -> occursin("set_storage_dispatch_ceilings!", read(f, String)), readdir(folder; join = true))
end

@testset "a battery's ramp floor binds in step 1 only: simulation equals standalone solves" begin
    expected = [
        (battery = 15.0, alta = 25.0, price = 50.0, objective = 1325 / 12),
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
function stock_simulate_losses(sys)
    out = AEMS._replication_simulation(sys, STOCK_STEPS; optimizer = STOCK_OPTIMIZER)
    frames = AEMS._solved_frames(out.results, sys; losses = true)
    return (;
        out..., objectives = PSI.read_optimizer_stats(out.results).objective_value,
        solved = [AEMS._solved_interval(frames, sys, t) for t in STOCK_STEPS],
    )
end
function stock_standalone_losses(sys, t)
    template = replication_template(sys; parts = STOCK_PARTS)
    model = AEMS._replication_decision_model(template, sys, t; optimizer = STOCK_OPTIMIZER, name = "standalone", parts = STOCK_PARTS)
    @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
    @test PSI.solve!(model) == PSI.RunStatus.SUCCESSFULLY_FINALIZED
    results = PSI.OptimizationProblemResults(model)
    return (;
        model, objective = only(PSI.read_optimizer_stats(results).objective_value),
        solved = AEMS._solved_interval(AEMS._solved_frames(results, sys; losses = true), sys, t),
    )
end

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
