using HiGHS
import PowerSimulations as PSI
import PowerSystems as PSY

function replay_validation_system(terms; invoked = 1.0, with_off_constraint = false)
    return nem_toy_system(
        [TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = 50.0, ramp_up = 100.0)], 50.0;
        horizon = TOY_RESOLUTION,
        mutate! = function (sys, stamps)
            unit = PSY.get_component(ThermalStandard, sys, TOY_CHEAP)
            PSY.add_service!(sys, FCASService(; name = "1_RAISEREG", region = "1", bid_type = BidType.RAISEREG), [unit])
            gc = GenericConstraint(; name = "N_REVIEW", sense = ConstraintSense.LE, rhs = 1.0, terms)
            PSY.add_service!(sys, gc, [unit])
            add_toy_constraint_series!(sys, gc, stamps, fill(100.0, length(stamps)), fill(invoked, length(stamps)))
            if with_off_constraint
                off = GenericConstraint(;
                    name = "N_OFF", sense = ConstraintSense.LE, rhs = 1.0,
                    terms = ConstraintTerm[UnitTerm(TOY_CHEAP, BidType.ENERGY, 1.0)],
                )
                PSY.add_service!(sys, off, [unit])
                add_toy_constraint_series!(sys, off, stamps, fill(100.0, length(stamps)), fill(1.0, length(stamps)))
            end
            return
        end,
    )
end

# Replays two intervals of `sys` under `template` with HiGHS, returning the replay result.
function run_two_steps(sys, template)
    return run_replay(
        sys, TOY_START:TOY_RESOLUTION:(TOY_START + TOY_RESOLUTION); template,
        optimizer = PSI.optimizer_with_attributes(HiGHS.Optimizer, "output_flag" => false),
    )
end

@testset "excluded constraints bypass buildability checks and retain their reason" begin
    ghost = UnitTerm("GHOST", BidType.ENERGY, 1.0)
    sys = replay_validation_system(ConstraintTerm[ghost])
    skipped = NamedTuple[]
    result = try
        replay_template(
            sys; template = with_generic_constraints!(energy_template()), exclude_constraints = Dict("N_REVIEW" => :manual_exclusion), skipped,
        )
    catch err
        err
    end
    @test result isa PSI.ProblemTemplate
    if result isa PSI.ProblemTemplate
        @test !any(k -> first(k) == "N_REVIEW", keys(PSI.get_service_models(result)))
        @test only(skipped) == (constraint = "N_REVIEW", reason = :manual_exclusion, n_missing = 0)
    end
end

@testset "a never-invoked constraint bypasses buildability checks and is unavailable from the build" begin
    ghost = UnitTerm("GHOST", BidType.ENERGY, 1.0)
    sys = replay_validation_system(ConstraintTerm[ghost]; invoked = 0.0)
    AustralianElectricityMarkets._set_constraint_availability!(sys)
    skipped = NamedTuple[]
    result = replay_template(sys; template = with_generic_constraints!(energy_template()), skipped)
    @test result isa PSI.ProblemTemplate
    @test isempty(skipped)
    @test !PSY.get_available(PSY.get_component(GenericConstraint, sys, "N_REVIEW"))
    @test AustralianElectricityMarkets.get_unavailable_constraints(sys).reason == [:never_invoked]
end

@testset "an omitted family cannot hide a missing component in either term order" begin
    fcas = UnitTerm(TOY_CHEAP, BidType.RAISEREG, 1.0)
    ghost = UnitTerm("GHOST", BidType.ENERGY, 1.0)
    for terms in (ConstraintTerm[fcas, ghost], ConstraintTerm[ghost, fcas])
        sys = replay_validation_system(terms)
        @test_throws r"missing_component" replay_template(sys; template = with_generic_constraints!(energy_template()))
    end
    sys = replay_validation_system(ConstraintTerm[fcas])
    skipped = NamedTuple[]
    @test replay_template(sys; template = with_generic_constraints!(energy_template()), skipped) isa PSI.ProblemTemplate
    @test only(skipped) == (constraint = "N_REVIEW", reason = :unmodeled_fcas_service, n_missing = 1)
end

@testset "replay models battery FCAS contributors and passes the standalone FCAS check" begin
    sys = fcas_toy_system()
    template = with_generic_constraints!(with_fcas!(energy_template()))
    replay_template(sys; template)
    @test isnothing(check_fcas_services(template, sys))
    result = run_two_steps(sys, template)
    @test nrow(PSI.read_optimizer_stats(result.results)) == 2
    @test haskey(PSI.get_device_models(PSI.get_template(result.model)), :EnergyReservoirStorage)
end

@testset "replay models a battery-only FCAS market through the template" begin
    sys = nem_toy_system(
        [TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = 50.0, ramp_up = 100.0)], 50.0;
        batteries = [TOY_BATTERY => toy_battery(50.0, 30.0, 50.0, 0.0; initial = 0.0, ramp_up = 100.0)],
        horizon = TOY_RESOLUTION,
        mutate! = function (sys, stamps)
            battery = PSY.get_component(EnergyReservoirStorage, sys, TOY_BATTERY)
            add_toy_fcas_offer!(
                sys, battery, stamps, BidType.RAISE6SEC,
                fill((-50.0, -40.0, 40.0, 50.0, 20.0), 2), fill([(20.0, 2.0)], 2),
            )
            add_toy_fcas_market!(sys, stamps, BidType.RAISE6SEC, [TOY_BATTERY], "F_BAT_ONLY", [10.0, 10.0])
            return
        end,
    )
    template = with_generic_constraints!(with_fcas!(energy_template()))
    skipped = NamedTuple[]
    replay_template(sys; template, skipped)
    @test PSY.get_available(PSY.get_component(FCASService, sys, "1_RAISE6SEC"))
    @test isempty(skipped)
    result = run_two_steps(sys, template)
    @test nrow(PSI.read_optimizer_stats(result.results)) == 2
    for devices in ([TOY_CHEAP, TOY_BATTERY], [TOY_CHEAP])
        gc = PSY.get_component(GenericConstraint, sys, "F_BAT_ONLY")
        empty!(get_terms(gc))
        push!(get_terms(gc), RegionTerm("1", BidType.RAISE6SEC, 1.0, devices))
        result = run_two_steps(sys, template)
        @test nrow(PSI.read_optimizer_stats(result.results)) == 2
        @test isempty(result.skipped_constraints)
    end
end

@testset "MPC overrides must be finite and positive" begin
    sys = nem_toy_system([TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = 50.0, ramp_up = 100.0)], 50.0; horizon = TOY_RESOLUTION)
    model = PSI.DecisionModel(AEMS.NEMDispatchProblem, replay_template(sys), sys; optimizer = HiGHS.Optimizer, initial_time = TOY_START)
    container = PSI.get_optimization_container(model)
    settings = PSI.get_ext(PSI.get_settings(model))
    for cap in (0.0, -1.0, Inf, -Inf, NaN)
        settings["market_price_cap"] = cap
        @test_throws ArgumentError AEMS._container_market_price_cap(container, TOY_START)
        @test_throws ArgumentError AEMS._add_mpc_penalty!(container, PSI.SystemBalanceSlackUp, PSY.Area, String[], 155.0; rate = cap)
    end
    settings["market_price_cap"] = 12345.0
    @test AEMS._container_market_price_cap(container, TOY_START) == 12345.0
end

@testset "each replay call replaces the exclusions of the previous call on the same system" begin
    ghost = UnitTerm("GHOST", BidType.ENERGY, 1.0)
    sys = replay_validation_system(ConstraintTerm[ghost]; with_off_constraint = true)
    review = PSY.get_component(GenericConstraint, sys, "N_REVIEW")
    off = PSY.get_component(GenericConstraint, sys, "N_OFF")
    PSY.set_available!(off, false)  # Unavailable in the input: no replay call may re-enable it.
    first_skipped = NamedTuple[]
    replay_template(
        sys; template = with_generic_constraints!(energy_template()), exclude_constraints = Dict("N_REVIEW" => :manual_exclusion),
        skipped = first_skipped,
    )
    @test !PSY.get_available(review)
    @test !PSY.get_available(off)
    @test !any(r -> r.constraint == "N_OFF", first_skipped)
    # The second call excludes nothing, so N_REVIEW is judged afresh on its now buildable terms.
    empty!(get_terms(review))
    push!(get_terms(review), UnitTerm(TOY_CHEAP, BidType.ENERGY, 1.0))
    second_skipped = NamedTuple[]
    replay_template(sys; template = with_generic_constraints!(energy_template()), skipped = second_skipped)
    @test PSY.get_available(review)
    @test !any(r -> r.constraint == "N_REVIEW", second_skipped)
    @test !PSY.get_available(off)
    @test !any(r -> r.constraint == "N_OFF", second_skipped)
end

@testset "a never-invoked constraint stays excluded and is reported again on a reused system" begin
    ghost = UnitTerm("GHOST", BidType.ENERGY, 1.0)
    sys = replay_validation_system(ConstraintTerm[ghost]; invoked = 0.0)
    AustralianElectricityMarkets._set_constraint_availability!(sys)
    review = PSY.get_component(GenericConstraint, sys, "N_REVIEW")
    for _ in 1:2
        rows = AEMS.prepare_replay!(sys, with_generic_constraints!(energy_template()), TOY_START:TOY_RESOLUTION:(TOY_START + TOY_RESOLUTION))
        @test !PSY.get_available(review)
        @test rows == DataFrame(; constraint = ["N_REVIEW"], reason = [:never_invoked], n_missing = [0])
    end
end

# The toy replay's balance-slack objective coefficient, one area and interval, as recorded on the
# code that priced slacks in an override: 100 MW x 150 CVP x 17,500 $/MWh x 5/60 h.
const TOY_BALANCE_SLACK_COEFFICIENT = 2.1875e7

@testset "replay balance slacks are priced through the network model's slack cost" begin
    sys = nem_toy_system(
        [TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = 50.0, ramp_up = 100.0)], 50.0; horizon = TOY_RESOLUTION,
    )
    model = PSI.DecisionModel(AEMS.NEMDispatchProblem, replay_template(sys), sys; optimizer = HiGHS.Optimizer, initial_time = TOY_START)
    @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
    container = PSI.get_optimization_container(model)
    objective = PSI.JuMP.objective_function(PSI.get_jump_model(container))
    for var_type in (PSI.SystemBalanceSlackUp, PSI.SystemBalanceSlackDown)
        slack = PSI.get_variable(container, var_type(), PSY.Area)
        @test all(v -> isapprox(PSI.JuMP.coefficient(objective, v), TOY_BALANCE_SLACK_COEFFICIENT; rtol = 1.0e-12), slack)
    end

    undated = PSI.DecisionModel(
        AEMS.NEMDispatchProblem, replay_template(sys), sys; optimizer = HiGHS.Optimizer, initial_time = DateTime(2020, 1, 1),
    )
    @test_throws r"No published Market Price Cap" PSI.validate_template(undated)
    @test PSI.build!(undated; output_dir = mktempdir()) == PSI.ModelBuildStatus.FAILED
    @test_throws ArgumentError PSI.DecisionModel(
        AEMS.NEMDispatchProblem, replay_template(sys), sys; optimizer = HiGHS.Optimizer, initial_time = TOY_START, market_price_cap = 0.0,
    )
end

@testset "NEMDispatchProblem prices the balance slacks and its settings at one Market Price Cap" begin
    sys = nem_toy_system(
        [TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = 50.0, ramp_up = 100.0)], 50.0; horizon = TOY_RESOLUTION,
    )
    template = replay_template(sys)
    template_cost = PSI.get_slack_cost(PSI.get_network_model(template))
    model = PSI.DecisionModel(
        AEMS.NEMDispatchProblem, template, sys; optimizer = HiGHS.Optimizer, initial_time = TOY_START, market_price_cap = 12_345.0,
    )
    @test PSI.get_ext(PSI.get_settings(model))["market_price_cap_override"] == 12_345.0
    @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
    model_cost = PSI.get_slack_cost(PSI.get_network_model(PSI.get_template(model)))
    @test model_cost == AEMS._area_balance_slack_cost(sys, 12_345.0)
    @test PSI.get_slack_cost(PSI.get_network_model(template)) == template_cost
end

@testset "a plain AreaBalance model keeps PSI's slack cost when AEMSim is loaded" begin
    sys = nem_toy_system(
        [TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = 50.0, ramp_up = 100.0)], 50.0; horizon = TOY_RESOLUTION,
    )
    template = PSI.ProblemTemplate(PSI.NetworkModel(PSI.AreaBalancePowerModel; use_slacks = true))
    set_nem_dispatch_models!(template, sys)
    PSI.set_device_model!(template, PSY.PowerLoad, PSI.StaticPowerLoad)
    model = PSI.DecisionModel(
        template, sys; optimizer = HiGHS.Optimizer, horizon = TOY_RESOLUTION,
        resolution = TOY_RESOLUTION, interval = TOY_RESOLUTION, initial_time = TOY_START,
    )
    @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
    container = PSI.get_optimization_container(model)
    objective = PSI.JuMP.objective_function(PSI.get_jump_model(container))
    for var_type in (PSI.SystemBalanceSlackUp, PSI.SystemBalanceSlackDown)
        slack = PSI.get_variable(container, var_type(), PSY.Area)
        @test all(v -> PSI.JuMP.coefficient(objective, v) == PSI.BALANCE_SLACK_COST, slack)
    end
end

@testset "an override build prices the balance slack and the unit ramp slack at one Market Price Cap" begin
    sys = nem_toy_system(
        [TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = 50.0, ramp_up = 1.0)], 50.0; horizon = TOY_RESOLUTION,
    )
    cap = 12_345.0
    template = replay_template(sys)
    model = PSI.DecisionModel(
        AEMS.NEMDispatchProblem, template, sys; market_price_cap = cap, optimizer = HiGHS.Optimizer, initial_time = TOY_START,
    )
    @test PSI.get_ext(PSI.get_settings(model))["market_price_cap_override"] == cap
    @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
    container = PSI.get_optimization_container(model)
    objective = PSI.JuMP.objective_function(PSI.get_jump_model(container))
    base_power = PSY.get_base_power(sys)
    per_mpc = base_power * interval_hours(DISPATCH_INTERVAL) * cap

    balance = PSI.get_variable(container, PSI.SystemBalanceSlackUp(), PSY.Area)
    @test PSI.JuMP.coefficient(objective, balance[first(axes(balance)[1]), first(axes(balance)[2])]) ≈
        per_mpc * AustralianElectricityMarkets.AREA_BALANCE_CVP_FACTOR rtol = 1.0e-12
    ramp = PSI.get_variable(container, AEMS.NEMUnitSlack(), ThermalStandard, "unit_ramp|up")
    @test all(v -> isapprox(PSI.JuMP.coefficient(objective, v), per_mpc * AEMS.UNIT_RAMP_CVP_FACTOR; rtol = 1.0e-12), ramp)
end

@testset "NEMDispatchProblem dates the Market Price Cap at each validation" begin
    sys = nem_toy_system(
        [TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = 50.0, ramp_up = 100.0)], 50.0; horizon = TOY_RESOLUTION,
    )
    template = replay_template(sys)
    @test_throws ArgumentError PSI.DecisionModel(
        AEMS.NEMDispatchProblem, template, sys; optimizer = HiGHS.Optimizer, initial_time = TOY_START, ext = Dict{String, Any}(),
    )
    model = PSI.DecisionModel(AEMS.NEMDispatchProblem, template, sys; optimizer = HiGHS.Optimizer, initial_time = TOY_START)
    ext = PSI.get_ext(PSI.get_settings(model))
    PSI.validate_template(model)
    @test ext["market_price_cap"] == AEMS._financial_year_mpc(TOY_START)
    @test !haskey(ext, "market_price_cap_override")
    # 1 August 2025 falls in the 2025-26 financial year, which has a different cap.
    next_year = DateTime(2025, 8, 1)
    PSI.set_initial_time!(model, next_year)
    PSI.validate_template(model)
    @test ext["market_price_cap"] == AEMS._financial_year_mpc(next_year)
    @test ext["market_price_cap"] != AEMS._financial_year_mpc(TOY_START)
end

@testset "NEMDispatchProblem in a Simulation" begin
    sys = nem_toy_system(
        [TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = 50.0, ramp_up = 100.0)], 50.0; horizon = TOY_RESOLUTION,
    )
    template = replay_template(sys)
    template_cost = PSI.get_slack_cost(PSI.get_network_model(template))
    model = PSI.DecisionModel(AEMS.NEMDispatchProblem, template, sys; optimizer = HiGHS.Optimizer)
    models = PSI.SimulationModels(; decision_models = [model])
    sequence = PSI.SimulationSequence(; models = models, ini_cond_chronology = PSI.InterProblemChronology())
    second_interval = TOY_START + TOY_RESOLUTION
    sim = PSI.Simulation(;
        name = "nem_problem", steps = 1, models = models, sequence = sequence,
        simulation_folder = mktempdir(), initial_time = second_interval,
    )
    @test PSI.build!(sim) == PSI.SimulationBuildStatus.BUILT
    @test PSI.get_initial_time(model) == second_interval
    @test PSI.execute!(sim) == PSI.RunStatus.SUCCESSFULLY_FINALIZED
    cap = AEMS._resolved_market_price_cap(second_interval)
    @test PSI.get_ext(PSI.get_settings(model))["market_price_cap"] == cap
    @test PSI.get_slack_cost(PSI.get_network_model(PSI.get_template(model))) == AEMS._area_balance_slack_cost(sys, cap)
    @test PSI.get_slack_cost(PSI.get_network_model(template)) == template_cost
end

@testset "prepare_replay! returns the skipped table and is repeatable" begin
    sys = nem_toy_system(
        [TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = 50.0, ramp_up = 100.0)], 50.0; horizon = TOY_RESOLUTION,
    )
    steps = TOY_START:TOY_RESOLUTION:TOY_START
    # The fixture attaches its own forecast windows, so the call keeps them and only runs the checks.
    forecasts = PSY.get_time_series_counts(sys).forecast_count
    skipped = prepare_replay!(sys, replay_template(sys), steps)
    @test skipped isa DataFrame
    @test names(skipped) == ["constraint", "reason", "n_missing"]
    @test PSY.get_time_series_counts(sys).forecast_count == forecasts > 0
    @test prepare_replay!(sys, replay_template(sys), steps) == skipped
end
