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

# Replays two intervals of `sys` under `parts` with HiGHS, returning the replay result.
function run_two_steps(sys; parts)
    return run_replication(
        sys, TOY_START:TOY_RESOLUTION:(TOY_START + TOY_RESOLUTION); parts,
        optimizer = PSI.optimizer_with_attributes(HiGHS.Optimizer, "output_flag" => false),
    )
end

@testset "excluded constraints bypass buildability checks and retain their reason" begin
    ghost = UnitTerm("GHOST", BidType.ENERGY, 1.0)
    for reason in (:never_invoked, :manual_exclusion)
        sys = replay_validation_system(ConstraintTerm[ghost]; invoked = 0.0)
        exclusions = reason == :never_invoked ? AEMS._never_invoked_constraints(sys, [TOY_START]) : Dict("N_REVIEW" => reason)
        skipped = NamedTuple[]
        result = try
            replication_template(sys; parts = (:generic_constraints,), exclude_constraints = exclusions, skipped)
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
        @test_throws r"missing_component" replication_template(sys; parts = (:generic_constraints,))
    end
    sys = replay_validation_system(ConstraintTerm[fcas])
    skipped = NamedTuple[]
    @test replication_template(sys; parts = (:generic_constraints,), skipped) isa PSI.ProblemTemplate
    @test only(skipped) == (constraint = "N_REVIEW", reason = :unmodeled_fcas_service, n_missing = 1)
end

@testset "replay omits battery FCAS contributors while retaining strict standalone checks" begin
    sys = fcas_toy_system()
    parts = (:fcas, :generic_constraints)
    template = replication_template(sys; parts)
    @test_throws ArgumentError check_fcas_services(sys, template)
    result = run_two_steps(sys; parts)
    @test nrow(PSI.read_optimizer_stats(result.results)) == 2
    @test !haskey(PSI.get_device_models(PSI.get_template(result.model)), :EnergyReservoirStorage)
end

@testset "replay omits a battery-only FCAS market when batteries are omitted" begin
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
    parts = (:fcas, :generic_constraints)
    skipped = NamedTuple[]
    template = replication_template(sys; parts, skipped)
    @test !any(k -> first(k) == "1_RAISE6SEC", keys(PSI.get_service_models(template)))
    @test only(skipped) == (constraint = "F_BAT_ONLY", reason = :unmodeled_device_type, n_missing = 1)
    result = run_two_steps(sys; parts)
    @test nrow(PSI.read_optimizer_stats(result.results)) == 2
    for devices in ([TOY_CHEAP, TOY_BATTERY], [TOY_CHEAP])
        gc = PSY.get_component(GenericConstraint, sys, "F_BAT_ONLY")
        empty!(get_terms(gc))
        push!(get_terms(gc), RegionTerm("1", BidType.RAISE6SEC, 1.0, devices))
        result = run_two_steps(sys; parts)
        @test nrow(PSI.read_optimizer_stats(result.results)) == 2
        @test only(result.skipped_constraints.reason) == :unmodeled_device_type
    end
end

@testset "MPC overrides must be finite and positive at both configuration levels" begin
    sys = nem_toy_system([TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = 50.0, ramp_up = 100.0)], 50.0; horizon = TOY_RESOLUTION)
    model = AEMS._replication_decision_model(replication_template(sys), sys, TOY_START; optimizer = HiGHS.Optimizer)
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

@testset "left-out parts tolerate only their own device types" begin
    @test AEMS._left_out_part_types((:fcas, :losses, :tie_breaks, :generic_constraints)) == [PSY.Storage]
    @test AEMS._left_out_part_types(AEMS.REPLICATION_PARTS) == DataType[]
end

# The toy replay's balance-slack objective coefficient, one area and interval, as recorded on the
# code that priced slacks in an override: 100 MW x 150 CVP x 17,500 $/MWh x 5/60 h.
const TOY_BALANCE_SLACK_COEFFICIENT = 2.1875e7

@testset "replay balance slacks are priced through the network model's slack cost" begin
    sys = nem_toy_system(
        [TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = 50.0, ramp_up = 100.0)], 50.0; horizon = TOY_RESOLUTION,
    )
    model = AEMS._replication_decision_model(replication_template(sys), sys, TOY_START; optimizer = HiGHS.Optimizer)
    @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
    container = PSI.get_optimization_container(model)
    objective = PSI.JuMP.objective_function(PSI.get_jump_model(container))
    for var_type in (PSI.SystemBalanceSlackUp, PSI.SystemBalanceSlackDown)
        slack = PSI.get_variable(container, var_type(), PSY.Area)
        @test all(v -> isapprox(PSI.JuMP.coefficient(objective, v), TOY_BALANCE_SLACK_COEFFICIENT; rtol = 1.0e-12), slack)
    end

    # The same network model with a supplied cap, and a build dated in the next financial year.
    base_power = PSY.get_base_power(sys)
    per_mpc = base_power * AustralianElectricityMarkets.AREA_BALANCE_CVP_FACTOR * interval_hours(DISPATCH_INTERVAL)
    network_slack_cost(; kwargs...) = PSI.get_slack_cost(PSI.get_network_model(replication_template(sys; kwargs...)))
    @test network_slack_cost(initial_time = TOY_START) ≈ per_mpc * 17_500.0 rtol = 1.0e-12
    @test network_slack_cost(initial_time = DateTime(2025, 7, 1, 0, 5)) ≈ per_mpc * 20_300.0 rtol = 1.0e-12
    @test network_slack_cost(initial_time = TOY_START, market_price_cap = 12_345.0) ≈ per_mpc * 12_345.0 rtol = 1.0e-12
    @test_throws r"No published Market Price Cap" replication_template(sys; initial_time = DateTime(2020, 1, 1))
    @test_throws ArgumentError replication_template(sys; market_price_cap = 0.0)
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
