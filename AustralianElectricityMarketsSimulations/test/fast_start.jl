# NEMDE's two-run fast-start dispatch on the toy system (100 MW base). Alta is the fast-start unit, with
# `T1 = 7`, `T2 = 3`, `T3 = 10`, `T4 = 10` minutes and a 230 MW minimum loading; Park City is a $50 unit
# with room to cover the 250 MW load alone.

const FS_OPTIMIZER = PSI.JuMP.optimizer_with_attributes(
    HiGHS.Optimizer, "output_flag" => false, "mip_rel_gap" => 0.0, "mip_abs_gap" => 1.0e-10,
)
const FS_PROFILE = AustralianElectricityMarkets.FastStartProfile((7.0, 3.0, 10.0, 10.0))
const FS_MINIMUM_LOAD = 230.0

# Alta at `alta_price` from `alta_initial` MW in starting `mode` with `mode_time` minutes in it, ramping
# `ramp_up` MW/min, beside Park City; `profile = nothing` gives Alta no fast-start profile.
function fast_start_system(;
        alta_price = 10.0, alta_initial = 0.0, mode = 0, mode_time = 0.0, ramp_up = 100.0, load_mw = 250.0,
        profile = FS_PROFILE,
    )
    units = [
        TOY_CHEAP => toy_unit(400.0, [(400.0, alta_price)]; initial = alta_initial, ramp_up, ramp_down = 100.0),
        TOY_EXPENSIVE => toy_unit(500.0, [(500.0, 50.0)]; initial = 200.0, ramp_up = 100.0, ramp_down = 100.0),
    ]
    mutate! = (sys, stamps) -> begin
        isnothing(profile) && return
        alta = PSY.get_component(ThermalStandard, sys, TOY_CHEAP)
        _toy_energy_bid!(
            sys, alta, AustralianElectricityMarkets.BidDirection.GEN, stamps,
            _toy_offers([(400.0, alta_price)], 2), _toy_values(400.0, 2);
            fast_start_profile = profile, minimum_load = FS_MINIMUM_LOAD,
        )
        set_toy_unit_field!(sys, alta, stamps, :dispatch_mode, _toy_values(mode, 2))
        set_toy_unit_field!(sys, alta, stamps, :dispatch_mode_time, _toy_values(mode_time, 2))
        return
    end
    return nem_toy_system(units, load_mw; horizon = TOY_RESOLUTION, mutate!)
end

# The realized table `key` of `results` as `name => value` at the first interval.
function fs_values(results, key)
    frame = PSI.read_realized_variable(results, key)
    return Dict(r.name => r.value for r in eachrow(frame) if r.DateTime == TOY_START)
end

# The area price of `results` at the first interval, from the balance dual, in $/MWh.
function fs_price(results)
    frame = PSI.read_realized_dual(results, "CopperPlateBalanceConstraint__Area")
    return only(frame[frame.DateTime .== TOY_START, :value]) / (100.0 * interval_hours(DISPATCH_INTERVAL))
end

# Runs `steps` of the replay sequence of `sys`; returns the sequence and the results of both runs.
function fs_replay(sys; steps = 1, problem = NEMDispatchProblem, fast_start = true)
    built = nem_dispatch_sequence(problem, replay_template(sys), sys; optimizer = FS_OPTIMIZER, initial_time = TOY_START, fast_start)
    simulation = PSI.Simulation(;
        name = "fast_start", steps, models = built.models, sequence = built.sequence,
        simulation_folder = mktempdir(), initial_time = TOY_START,
    )
    @test PSI.build!(simulation; store_systems_in_results = false) == PSI.SimulationBuildStatus.BUILT
    @test PSI.execute!(simulation) == PSI.RunStatus.SUCCESSFULLY_FINALIZED
    results = PSI.SimulationResults(simulation)
    dispatch = PSI.get_decision_problem_results(results, "dispatch")
    commitment = isnothing(built.commitment) ? nothing : PSI.get_decision_problem_results(results, FAST_START_COMMITMENT_NAME)
    return (; built..., dispatch_results = dispatch, commitment_results = commitment)
end

const FS_POWER = "ActivePowerVariable__ThermalStandard"

@testset "a mode-0 unit dispatched in the commitment run is held at 0 MW in the dispatch run" begin
    # The commitment run dispatches Alta at $10 without ramp rows; it enters mode 1 with T1 = 7 > 5 minutes left.
    out = fs_replay(fast_start_system())
    @test PSI.get_name(out.commitment) == Symbol(FAST_START_COMMITMENT_NAME)
    @test PSI.get_name(out.dispatch) == :dispatch
    run1 = fs_values(out.commitment_results, FS_POWER)
    @test run1[TOY_CHEAP] ≈ 250.0 atol = TOY_TOLERANCE
    @test fs_price(out.commitment_results) ≈ 10.0 atol = TOY_TOLERANCE
    run2 = fs_values(out.dispatch_results, FS_POWER)
    @test run2[TOY_CHEAP] ≈ 0.0 atol = TOY_TOLERANCE
    @test run2[TOY_EXPENSIVE] ≈ 250.0 atol = TOY_TOLERANCE
    # The dispatch run carries the commitment run's target, in system-base per-unit, and prices the interval.
    carried = PSI.read_realized_parameter(out.dispatch_results, "FixValueParameter__ThermalStandard__ActivePowerVariable")
    @test only(carried[(carried.name .== TOY_CHEAP) .& (carried.DateTime .== TOY_START), :value]) ≈ 2.5 atol = TOY_TOLERANCE
    @test fs_price(out.dispatch_results) ≈ 50.0 atol = TOY_TOLERANCE
    solved = read_solved_interval(out.dispatch_results, PSI.get_system(out.dispatch))
    @test only(solved.prices.ROP) ≈ 50.0 atol = TOY_TOLERANCE
    @test isempty(subset(read_constraint_violations(out.dispatch_results, PSI.get_system(out.dispatch)), :family => ByRow(==("fast_start_profile"))))
end

@testset "fast_start = false replays one model without inflexibility profiles" begin
    out = fs_replay(fast_start_system(); fast_start = false)
    @test isnothing(out.commitment)
    @test length(PSI.get_decision_models(out.models)) == 1
    @test fs_values(out.dispatch_results, FS_POWER)[TOY_CHEAP] ≈ 250.0 atol = TOY_TOLERANCE
    @test fs_price(out.dispatch_results) ≈ 10.0 atol = TOY_TOLERANCE
end

@testset "a unit ending in mode 2 is fixed at M t / T2" begin
    # From mode 1 with 4 of 7 minutes: 3 minutes to mode 2, then 2 of its 3 minutes, so 230 x 2 / 3 MW.
    out = fs_replay(fast_start_system(; alta_price = 100.0, mode = 1, mode_time = 4.0))
    @test fs_values(out.commitment_results, FS_POWER)[TOY_CHEAP] ≈ 0.0 atol = TOY_TOLERANCE
    run2 = fs_values(out.dispatch_results, FS_POWER)
    @test run2[TOY_CHEAP] ≈ FS_MINIMUM_LOAD * 2 / 3 atol = 1.0e-6
    @test run2[TOY_EXPENSIVE] ≈ 250.0 - FS_MINIMUM_LOAD * 2 / 3 atol = 1.0e-6
    @test fs_price(out.dispatch_results) ≈ 50.0 atol = TOY_TOLERANCE
end

@testset "a unit ending in mode 3 holds at least its minimum loading" begin
    # From mode 2 with 1 of 3 minutes: 2 minutes to mode 3, where it spends the other 3.
    out = fs_replay(fast_start_system(; alta_price = 100.0, alta_initial = FS_MINIMUM_LOAD / 3, mode = 2, mode_time = 1.0))
    run2 = fs_values(out.dispatch_results, FS_POWER)
    @test run2[TOY_CHEAP] ≈ FS_MINIMUM_LOAD atol = 1.0e-6
    @test fs_price(out.dispatch_results) ≈ 50.0 atol = TOY_TOLERANCE
end

@testset "a unit leaving mode 2 ramps up from its minimum loading" begin
    # The standard row would hold Alta to 76.7 + 5 x 10 MW; the profile row ramps it from 230 MW for 3 minutes.
    out = fs_replay(fast_start_system(; alta_initial = FS_MINIMUM_LOAD / 3, mode = 2, mode_time = 1.0, ramp_up = 10.0, load_mw = 400.0))
    run2 = fs_values(out.dispatch_results, FS_POWER)
    @test run2[TOY_CHEAP] ≈ FS_MINIMUM_LOAD + 10.0 * 3 atol = 1.0e-6
    @test run2[TOY_EXPENSIVE] ≈ 400.0 - FS_MINIMUM_LOAD - 30.0 atol = 1.0e-6
    @test fs_price(out.dispatch_results) ≈ 50.0 atol = TOY_TOLERANCE
    # Starting in mode 2, the commitment run has no ramp rows for Alta: it takes the whole load at $10.
    @test fs_values(out.commitment_results, FS_POWER)[TOY_CHEAP] ≈ 400.0 atol = 1.0e-6
end

@testset "a unit ending in mode 4 has a lower bound on its declining profile" begin
    # From mode 4 with 2 of 10 minutes: 7 minutes at the end, so at least 230 x (1 - 7 / 10) = 69 MW.
    out = fs_replay(fast_start_system(; alta_price = 100.0, alta_initial = 120.0, mode = 4, mode_time = 2.0))
    @test fs_values(out.dispatch_results, FS_POWER)[TOY_CHEAP] ≈ 69.0 atol = 1.0e-6
    # The bound is a floor only: a cheap unit ramps above it, from its initial output.
    cheap = fs_replay(fast_start_system(; alta_initial = 120.0, mode = 4, mode_time = 2.0, ramp_up = 10.0))
    @test fs_values(cheap.dispatch_results, FS_POWER)[TOY_CHEAP] ≈ 170.0 atol = 1.0e-6
end

@testset "a standalone dispatch run builds, exports and solves from zero commitment targets" begin
    # Without the feedforward Alta's commitment target is 0 MW, so it stays in mode 0 and is held at 0 MW.
    sys = fast_start_system()
    model = PSI.DecisionModel(
        NEMDispatchProblem, replay_template(sys), sys; optimizer = FS_OPTIMIZER, initial_time = TOY_START,
        fast_start_run = :dispatch,
    )
    @test PSI.get_ext(PSI.get_settings(model))["fast_start_run"] == "dispatch"
    @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
    @test PSI.solve!(model) == PSI.RunStatus.SUCCESSFULLY_FINALIZED
    power = PSI.read_variable(PSI.OptimizationProblemResults(model), FS_POWER)
    @test only(power[power.name .== TOY_CHEAP, :value]) ≈ 0.0 atol = TOY_TOLERANCE
end

@testset "a system without fast-start units replays one model, as a single DecisionModel does" begin
    sys = fast_start_system(; profile = nothing)
    @test isempty(AEMS._fast_start_device_types(replay_template(sys), sys))
    out = fs_replay(sys)
    @test isnothing(out.commitment) && isnothing(out.commitment_results)
    @test length(PSI.get_decision_models(out.models)) == 1
    @test !haskey(PSI.get_ext(PSI.get_settings(out.dispatch)), "fast_start_run")
    single = PSI.DecisionModel(NEMDispatchProblem, replay_template(sys), sys; optimizer = FS_OPTIMIZER, initial_time = TOY_START, name = "single")
    @test PSI.build!(single; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
    @test PSI.solve!(single) == PSI.RunStatus.SUCCESSFULLY_FINALIZED
    reference = PSI.OptimizationProblemResults(single)
    @test only(PSI.read_optimizer_stats(out.dispatch_results).objective_value) ≈
        only(PSI.read_optimizer_stats(reference).objective_value) atol = TOY_TOLERANCE
    power = PSI.read_variable(reference, FS_POWER)
    for r in eachrow(power)
        @test fs_values(out.dispatch_results, FS_POWER)[r.name] ≈ r.value atol = TOY_TOLERANCE
    end
end

@testset "both runs build and replay closed loop over two steps" begin
    out = fs_replay(fast_start_system(); steps = 2, problem = NEMClosedLoopDispatchProblem)
    @test out.dispatch isa PSI.DecisionModel{NEMClosedLoopDispatchProblem}
    @test fs_values(out.dispatch_results, FS_POWER)[TOY_CHEAP] ≈ 0.0 atol = TOY_TOLERANCE
end

@testset "the sequence rejects a fast_start_run and a shared name" begin
    sys = fast_start_system()
    err = _caught(() -> nem_dispatch_sequence(NEMDispatchProblem, replay_template(sys), sys; fast_start_run = :dispatch))
    @test err isa ArgumentError
    err = _caught(() -> nem_dispatch_sequence(NEMDispatchProblem, replay_template(sys), sys; name = "x", commitment_name = "x"))
    @test err isa ArgumentError
    err = _caught(() -> PSI.DecisionModel(NEMDispatchProblem, replay_template(sys), sys; fast_start_run = :other))
    @test err isa ArgumentError
end

# The FCAS offer limits (`max_avail`, `enablement_min`, `enablement_max`) of `name` in the first interval of `out`'s dispatch run.
function fs_fcas_limits(out, name)
    key = PSI.ParameterKey(AEMS.FCASOfferLimitParameter, ThermalStandard, AEMS._fcas_offer_meta(BidType.RAISEREG, false))
    param = PSI.get_parameter(PSI.get_optimization_container(out.dispatch), key)
    uuid = PSI.get_attributes(param).component_name_to_ts_uuid[name]
    array = PSI.get_parameter_array(param)
    return [PSI.JuMP.fix_value(array[uuid, field, 1]) for field in AEMS._FCAS_LIMIT_FIELDS]
end

@testset "closed-loop fast-start dispatch: the first interval's FCAS offers are the observed ones" begin
    # Alta is in fast-start mode 0 with 15 MW of raise regulation observed at the start of the interval.
    sys = fcas_toy_system(; alta_fast_start = FS_PROFILE, alta_mode = 0)
    observed = fs_fcas_limits(fs_replay(sys), TOY_CHEAP)
    closed = fs_fcas_limits(fs_replay(sys; problem = NEMClosedLoopDispatchProblem), TOY_CHEAP)
    @test closed ≈ observed atol = 1.0e-9
    @test closed[1] ≈ 0.15 atol = 1.0e-9
end

@testset "a sequence's dispatch run without the commitment-target feedforward does not build" begin
    sys = fast_start_system()
    built = nem_dispatch_sequence(NEMDispatchProblem, replay_template(sys), sys; optimizer = FS_OPTIMIZER, initial_time = TOY_START)
    @test PSI.get_ext(PSI.get_settings(built.dispatch))["fast_start_feedforward"] === true
    # The sequence's dispatch run without the feedforward the sequence adds: it has no commitment target for Alta.
    bare = PSI.DecisionModel(
        NEMDispatchProblem, replay_template(sys), sys; optimizer = FS_OPTIMIZER, initial_time = TOY_START, fast_start_run = :dispatch,
    )
    PSI.get_ext(PSI.get_settings(bare))["fast_start_feedforward"] = true
    PSI.set_output_dir!(bare, mktempdir())
    err = _caught(() -> PSI.build_impl!(bare))
    @test err isa ArgumentError
    message = err isa ArgumentError ? err.msg : ""
    @test occursin("ThermalStandard", message)
    @test occursin("ActivePowerVariable", message)
end
