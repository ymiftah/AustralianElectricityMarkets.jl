@testset "replay requires complete inputs before model construction" begin
    sys = System(100.0; time_series_in_memory = true)
    set_build_report!(
        sys,
        NEMBuildReport(;
            skipped_constraints = [
                Dict{String, Any}(
                    "constraint" => "N_MISSING@2025-01-01#1", "reason" => "no_definition", "missing" => String[],
                ),
            ],
        ),
    )
    @test_throws r"incomplete.*N_MISSING" replay_template(sys)

    set_build_report!(
        sys,
        NEMBuildReport(;
            dropped_terms = [
                Dict{String, Any}(
                    "constraint" => "N_PARTIAL@2025-01-01#1", "kind" => "UNIT", "key" => "MISSING_DUID",
                    "bid_type" => "ENERGY", "factor" => 1.0,
                ),
            ],
        ),
    )
    @test_throws r"incomplete.*MISSING_DUID" replay_template(sys)

    set_build_report!(sys, NEMBuildReport(; defaulted_constraint_weights = ["N_NULL_WEIGHT@2025-01-01#1"]))
    @test_throws r"NULL GENERICCONSTRAINTWEIGHT: N_NULL_WEIGHT.*force_new = true" replay_template(sys)
end

@testset "a dispatch device without its dispatch-limit series cannot replay" begin
    db = aem_connect(HiveConfiguration(hive_location = AEM_TEST_REPLAY_HIVE_DIR))
    interval = DateTime(2025, 1, 1, 0, 5):Minute(5):DateTime(2025, 1, 1, 0, 15)
    sys, _ = constrained_system(db; date_range = interval)
    @test_throws r"incomplete dispatch inputs for .*; build sys with nem_system" replay_template(sys)
end

@testset "an MNSP cannot enter the regulated formulation without its offers" begin
    sys = nem_system(aem_connect(HiveConfiguration(hive_location = AEM_TEST_HIVE_DIR)), RegionalNetworkConfiguration())
    ic = get_component(AreaInterchange, sys, "IC2")
    @test !AEMS._has_mnsp_offers(ic)
    @test_throws r"IC2.*MNSP" AEMS._check_mnsp_offers(ic)
    # With every dispatch device unavailable, the template reaches the MNSP check.
    foreach(d -> set_available!(d, false), AustralianElectricityMarkets.nem_dispatch_devices(sys))
    @test_throws r"IC2.*MNSP" replay_template(sys)
    PSY.remove_supplemental_attribute!(sys, ic, only(PSY.get_supplemental_attributes(AustralianElectricityMarkets.NEMInterconnectorRegistration, ic)))
    PSY.add_supplemental_attribute!(sys, ic, AustralianElectricityMarkets.NEMInterconnectorRegistration(; kind = AustralianElectricityMarkets.InterconnectorKind.REGULATED))
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
    sys, _ = constrained_system(db; date_range = later)
    @test_throws r"missing.*constraint.*2030" replay_template(sys)
end

@testset "replay forecasts need attached input series" begin
    @test_throws r"attach input time series" AEMS._prepare_replay_forecasts!(System(100.0; time_series_in_memory = true))
end

@testset "a unit registered mid-chunk passes the replay template" begin
    # BW02 is registered from 00:10 of the replay hive, so it is built for the whole chunk.
    t = "TIMESTAMP '2025-01-01 00:10:00'"
    hive = AEM_TEST_REPLAY_HIVE_DIR
    for (table, query) in [
            (:DUDETAILSUMMARY, "UPDATE input SET START_DATE = $t WHERE DUID = 'BW02'"),
            (:DUDETAIL, "UPDATE input SET EFFECTIVEDATE = $t WHERE DUID = 'BW02'"),
            (:BIDPEROFFER_D, "DELETE FROM input WHERE DUID = 'BW02' AND INTERVAL_DATETIME <= $t"),
            (:DISPATCHLOAD, "DELETE FROM input WHERE DUID = 'BW02' AND SETTLEMENTDATE <= $t"),
        ]
        hive = damaged_cache(hive, table, query).config.hive_location
    end
    db = aem_connect(HiveConfiguration(hive_location = hive))
    interval = DateTime(2025, 1, 1, 0, 5):Minute(5):DateTime(2025, 1, 1, 0, 20)
    sys = nem_system(db, NEMDEConfiguration(); date_range = interval)
    @test !isnothing(get_component(Generator, sys, "BW02"))
    set_effective_offers!(sys)
    AEMS._prepare_replay_forecasts!(sys)
    @test_nowarn replay_template(sys)
end
