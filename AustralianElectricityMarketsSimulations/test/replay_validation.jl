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
            gc = GenericConstraint(; name = "N_REVIEW", sense = ConstraintSense.LE, rhs = 1.0, terms)
            PSY.add_service!(sys, gc, [unit])
            add_toy_series!(sys, gc, stamps, "rhs", fill(100.0, length(stamps)))
            add_toy_series!(sys, gc, stamps, "invoked", fill(invoked, length(stamps)); scale = 1.0)
            return
        end,
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
    result = try
        run_replication(
            sys, TOY_START:TOY_RESOLUTION:(TOY_START + TOY_RESOLUTION); parts,
            optimizer = PSI.optimizer_with_attributes(HiGHS.Optimizer, "output_flag" => false),
        )
    catch err
        err
    end
    @test !(result isa Exception)
    if !(result isa Exception)
        @test nrow(PSI.read_optimizer_stats(result.results)) == 2
        @test !haskey(PSI.get_device_models(PSI.get_template(result.model)), :EnergyReservoirStorage)
    end
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
    result = try
        run_replication(
            sys, TOY_START:TOY_RESOLUTION:(TOY_START + TOY_RESOLUTION); parts,
            optimizer = PSI.optimizer_with_attributes(HiGHS.Optimizer, "output_flag" => false),
        )
    catch err
        err
    end
    @test !(result isa Exception)
    if !(result isa Exception)
        @test nrow(PSI.read_optimizer_stats(result.results)) == 2
    end
    for devices in ([TOY_CHEAP, TOY_BATTERY], [TOY_CHEAP])
        gc = PSY.get_component(GenericConstraint, sys, "F_BAT_ONLY")
        empty!(get_terms(gc))
        push!(get_terms(gc), RegionTerm("1", BidType.RAISE6SEC, 1.0, devices))
        result = try
            run_replication(
                sys, TOY_START:TOY_RESOLUTION:(TOY_START + TOY_RESOLUTION); parts,
                optimizer = PSI.optimizer_with_attributes(HiGHS.Optimizer, "output_flag" => false),
            )
        catch err
            err
        end
        @test !(result isa Exception)
        if !(result isa Exception)
            @test nrow(PSI.read_optimizer_stats(result.results)) == 2
            @test only(result.skipped_constraints.reason) == :unmodeled_device_type
        end
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

@testset "a left-out part tolerates only its own device types in generic constraints" begin
    sys = nem_toy_system(
        [TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = 50.0, ramp_up = 100.0)], 50.0;
        batteries = [TOY_BATTERY => toy_battery(50.0, 30.0, 50.0, 0.0; initial = 0.0, ramp_up = 100.0)],
        horizon = TOY_RESOLUTION,
    )
    @test AEMS._left_out_part_types((:fcas, :losses, :tie_breaks, :generic_constraints)) == [PSY.Storage]
    @test AEMS._left_out_part_types(AEMS.REPLICATION_PARTS) == DataType[]
    gc = GenericConstraint(; name = "MIXED", sense = ConstraintSense.LE, rhs = 1.0, terms = ConstraintTerm[])
    modeled = DataType[]
    tolerated_types = [PSY.Storage]
    diagnose(terms) = (
        empty!(get_terms(gc)); append!(get_terms(gc), terms);
        AEMS._constraint_diagnosis(sys, gc, modeled, false, Set{String}(); tolerated_types)
    )
    battery_only = diagnose(ConstraintTerm[UnitTerm(TOY_BATTERY, BidType.ENERGY, 1.0)])
    @test battery_only[1] == :unmodeled_device_type && !battery_only[4]
    other = diagnose(ConstraintTerm[UnitTerm(TOY_CHEAP, BidType.ENERGY, 1.0)])
    @test other[1] == :unmodeled_device_type && other[4]
    mixed = diagnose(
        ConstraintTerm[UnitTerm(TOY_BATTERY, BidType.ENERGY, 1.0), UnitTerm(TOY_CHEAP, BidType.ENERGY, 1.0)],
    )
    @test mixed[4] && typeof(PSY.get_component(PSY.Device, sys, TOY_CHEAP)) in mixed[2]
end
