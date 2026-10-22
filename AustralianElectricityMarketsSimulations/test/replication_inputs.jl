@testset "replay requires complete inputs before model construction" begin
    sys = System(100.0; time_series_in_memory = true)
    get_ext(sys)["skipped_constraints"] = [
        Dict{String, Any}(
            "constraint" => "N_MISSING@2025-01-01#1", "reason" => "no_definition", "missing" => String[],
        ),
    ]
    @test_throws r"incomplete.*N_MISSING" replication_template(sys)

    delete!(get_ext(sys), "skipped_constraints")
    get_ext(sys)["dropped_terms"] = [
        Dict{String, Any}(
            "constraint" => "N_PARTIAL@2025-01-01#1", "kind" => "UNIT", "key" => "MISSING_DUID",
            "bid_type" => "ENERGY", "factor" => 1.0,
        ),
    ]
    @test_throws r"incomplete.*MISSING_DUID" replication_template(sys)

    delete!(get_ext(sys), "dropped_terms")
    get_ext(sys)["defaulted_constraint_weights"] = ["N_NULL_WEIGHT@2025-01-01#1"]
    @test_throws r"NULL GENERICCONSTRAINTWEIGHT: N_NULL_WEIGHT.*force_new = true" replication_template(sys)
end

@testset "a dispatch device without its dispatch-limit series cannot replay" begin
    db = aem_connect(HiveConfiguration(hive_location = AEM_TEST_REPLAY_HIVE_DIR))
    interval = DateTime(2025, 1, 1, 0, 5):Minute(5):DateTime(2025, 1, 1, 0, 15)
    sys = nem_system(db, ConstrainedNetworkConfiguration(); date_range = interval)
    @test_throws r"incomplete dispatch inputs for .*; call set_market_bids!, set_nem_dispatch_limits! and set_nem_energy_limits!" replication_template(sys)
end

@testset "an MNSP cannot enter the regulated formulation without its offers" begin
    sys = nem_system(aem_connect(HiveConfiguration(hive_location = AEM_TEST_HIVE_DIR)), RegionalNetworkConfiguration())
    ic = get_component(AreaInterchange, sys, "IC2")
    @test !AEMS._has_mnsp_offers(ic)
    @test_throws r"IC2.*MNSP" AEMS._check_mnsp_offers(ic)
    # With every dispatch device unavailable, the template reaches the MNSP check.
    foreach(d -> set_available!(d, false), AustralianElectricityMarkets.nem_dispatch_devices(sys))
    @test_throws r"IC2.*MNSP" replication_template(sys)
    get_ext(ic)["ic_type"] = "REGULATED"
    @test isnothing(AEMS._check_mnsp_offers(ic))
end

@testset "fixed loads retain the dispatch variable's direction" begin
    db = aem_connect(HiveConfiguration(hive_location = AEM_TEST_HIVE_DIR))
    sys = nem_system(db, RegionalNetworkConfiguration())
    t = DateTime(2025, 1, 1, 0, 5)
    rows = DataFrame(INTERVAL_DATETIME = [t, t], DUID = ["PUMP1", "BW01"], DIRECTION = ["LOAD", "LOAD"], FIXEDLOAD = [30.0, 5.0])
    targets = AustralianElectricityMarkets._fixed_load_series(sys, rows)
    @test targets["PUMP1"][t] == 30.0
    @test targets["BW01"][t] == -5.0
    @test AustralianElectricityMarkets._is_modelled_fixed_load("\$PUMP1", targets, t)
    @test !AustralianElectricityMarkets._is_modelled_fixed_load("\$PUMP1", targets, t + Minute(5))
end

@testset "a cached table without the requested constraint intervals cannot replay" begin
    db = aem_connect(HiveConfiguration(hive_location = AEM_TEST_HIVE_DIR))
    later = DateTime(2030, 1, 1):Minute(5):DateTime(2030, 1, 1, 0, 10)
    sys = nem_system(db, ConstrainedNetworkConfiguration(); date_range = later)
    @test_throws r"missing.*constraint.*2030" replication_template(sys)
end
