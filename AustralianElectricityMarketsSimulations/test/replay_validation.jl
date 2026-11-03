using HiGHS
import PowerSimulations as PSI
import PowerSystems as PSY

function replay_validation_system(terms; invoked = 1.0)
    return nem_toy_system(
        [TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = 50.0, ramp_up = 100.0)], 50.0;
        horizon = TOY_RESOLUTION,
        mutate! = function (sys, stamps)
            unit = PSY.get_component(PSY.ThermalStandard, sys, TOY_CHEAP)
            PSY.add_service!(sys, FCASService(; name = "1_RAISEREG", region = "1", bid_type = BidType.RAISEREG), [unit])
            flush_toy_fcas_curves!(sys)
            gc = GenericConstraint(; name = "N_REVIEW", sense = ConstraintSense.LE, rhs = 1.0, terms)
            PSY.add_service!(sys, gc, [unit])
            add_toy_series!(sys, gc, stamps, "rhs", fill(100.0, length(stamps)))
            add_toy_series!(sys, gc, stamps, "invoked", fill(invoked, length(stamps)); scale = 1.0)
            return
        end,
    )
end

# Replays two intervals of `sys` under `template` with HiGHS, returning the replay result.
function run_two_steps(sys, template)
    return ReplaySimulation.run_replication(
        sys, TOY_START:TOY_RESOLUTION:(TOY_START + TOY_RESOLUTION); template,
        optimizer = PSI.optimizer_with_attributes(HiGHS.Optimizer, "output_flag" => false),
    )
end

@testset "excluded constraints bypass buildability checks and retain their reason" begin
    ghost = UnitTerm("GHOST", BidType.ENERGY, 1.0)
    for reason in (:never_invoked, :manual_exclusion)
        sys = replay_validation_system(ConstraintTerm[ghost]; invoked = 0.0)
        exclusions = reason == :never_invoked ? AEMS.never_invoked_constraints(sys, [TOY_START]) : Dict("N_REVIEW" => reason)
        skipped = NamedTuple[]
        result = try
            replay_template(sys; template = with_generic_constraints!(energy_template()), exclude_constraints = exclusions, skipped)
        catch err
            err
        end
        @test result isa PSI.ProblemTemplate
        if result isa PSI.ProblemTemplate
            @test !any(k -> first(k) == "N_REVIEW", keys(PSI.get_service_models(result)))
            @test only(skipped) == (constraint = "N_REVIEW", reason = reason, n_missing = 0)
        end
    end
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
    @test isnothing(check_fcas_services(sys, template))
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
            battery = PSY.get_component(PSY.EnergyReservoirStorage, sys, TOY_BATTERY)
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

@testset "MPC overrides must be finite and positive at both configuration levels" begin
    sys = nem_toy_system([TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = 50.0, ramp_up = 100.0)], 50.0; horizon = TOY_RESOLUTION)
    model = AEMS.replication_decision_model(replay_template(sys), sys, TOY_START; optimizer = HiGHS.Optimizer)
    container = PSI.get_optimization_container(model)
    settings = PSI.get_ext(PSI.get_settings(model))
    capped(cap) = PSI.ServiceModel(
        GenericConstraint, LinearFactorLimit, "N_CAP"; attributes = Dict{String, Any}("market_price_cap" => cap),
    )
    for cap in (0.0, -1.0, Inf, -Inf, NaN)
        settings["market_price_cap"] = cap
        @test_throws ArgumentError AEMS._container_market_price_cap(container, TOY_START)
        @test_throws ArgumentError AEMS._service_market_price_cap(capped(cap), container, TOY_START)
        @test_throws ArgumentError AEMS._add_mpc_penalty!(container, PSI.SystemBalanceSlackUp, PSY.Area, String[], 155.0; rate = cap)
    end
    settings["market_price_cap"] = 12345.0
    @test AEMS._container_market_price_cap(container, TOY_START) == 12345.0
    @test AEMS._service_market_price_cap(capped(23456.0), container, TOY_START) == 23456.0
    @test AEMS._service_market_price_cap(
        PSI.ServiceModel(GenericConstraint, LinearFactorLimit, "N_CAP"), container, TOY_START,
    ) == 12345.0
end

@testset "each replay call replaces the exclusions of the previous call on the same system" begin
    ghost = UnitTerm("GHOST", BidType.ENERGY, 1.0)
    sys = replay_validation_system(ConstraintTerm[ghost])
    review = PSY.get_component(GenericConstraint, sys, "N_REVIEW")
    fcas = PSY.get_component(FCASService, sys, "1_RAISEREG")
    PSY.set_available!(fcas, false)  # Unavailable in the input: no replay call may re-enable it.
    first_skipped = NamedTuple[]
    replay_template(
        sys; template = with_generic_constraints!(energy_template()), exclude_constraints = Dict("N_REVIEW" => :manual_exclusion),
        skipped = first_skipped,
    )
    @test !PSY.get_available(review)
    # The second call excludes nothing, so N_REVIEW is judged afresh on its now buildable terms.
    empty!(get_terms(review))
    push!(get_terms(review), UnitTerm(TOY_CHEAP, BidType.ENERGY, 1.0))
    second_skipped = NamedTuple[]
    replay_template(sys; template = with_generic_constraints!(energy_template()), skipped = second_skipped)
    @test PSY.get_available(review)
    @test !any(r -> r.constraint == "N_REVIEW", second_skipped)
    @test !PSY.get_available(fcas)
end

# The toy replay's balance-slack objective coefficient, one area and interval, as recorded on the
# code that priced slacks in an override: 100 MW x 150 CVP x 17,500 $/MWh x 5/60 h.
const TOY_BALANCE_SLACK_COEFFICIENT = 2.1875e7

@testset "replay balance slacks are priced through the network model's slack cost" begin
    sys = nem_toy_system(
        [TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = 50.0, ramp_up = 100.0)], 50.0; horizon = TOY_RESOLUTION,
    )
    model = AEMS.replication_decision_model(replay_template(sys), sys, TOY_START; optimizer = HiGHS.Optimizer)
    @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
    container = PSI.get_optimization_container(model)
    objective = PSI.JuMP.objective_function(PSI.get_jump_model(container))
    for var_type in (PSI.SystemBalanceSlackUp, PSI.SystemBalanceSlackDown)
        slack = PSI.get_variable(container, var_type(), PSY.Area)
        @test all(v -> isapprox(PSI.JuMP.coefficient(objective, v), TOY_BALANCE_SLACK_COEFFICIENT; rtol = 1.0e-12), slack)
    end

    @test_throws r"No published Market Price Cap" AEMS.replication_decision_model(
        replay_template(sys), sys, DateTime(2020, 1, 1); optimizer = HiGHS.Optimizer,
    )
    @test_throws ArgumentError AEMS.replication_decision_model(
        replay_template(sys), sys, TOY_START; optimizer = HiGHS.Optimizer, market_price_cap = 0.0,
    )
end

@testset "replication_decision_model prices the balance slacks and its settings at one Market Price Cap" begin
    sys = nem_toy_system(
        [TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = 50.0, ramp_up = 100.0)], 50.0; horizon = TOY_RESOLUTION,
    )
    template = replay_template(sys)
    template_cost = PSI.get_slack_cost(PSI.get_network_model(template))
    model = AEMS.replication_decision_model(template, sys, TOY_START; optimizer = HiGHS.Optimizer, market_price_cap = 12_345.0)
    @test PSI.get_ext(PSI.get_settings(model))["market_price_cap"] == 12_345.0
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
    model = AEMS.replication_decision_model(template, sys, TOY_START; market_price_cap = cap, optimizer = HiGHS.Optimizer)
    @test PSI.get_ext(PSI.get_settings(model))["market_price_cap"] == cap
    @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
    container = PSI.get_optimization_container(model)
    objective = PSI.JuMP.objective_function(PSI.get_jump_model(container))
    base_power = PSY.get_base_power(sys)
    per_mpc = base_power * interval_hours(DISPATCH_INTERVAL) * cap

    balance = PSI.get_variable(container, PSI.SystemBalanceSlackUp(), PSY.Area)
    @test PSI.JuMP.coefficient(objective, balance[first(axes(balance)[1]), first(axes(balance)[2])]) ≈
        per_mpc * AustralianElectricityMarkets.AREA_BALANCE_CVP_FACTOR rtol = 1.0e-12
    ramp = PSI.get_variable(container, AEMS.UnitRampUpSlack(), PSY.ThermalStandard)
    @test all(v -> isapprox(PSI.JuMP.coefficient(objective, v), per_mpc * AEMS.UNIT_RAMP_CVP_FACTOR; rtol = 1.0e-12), ramp)
end
