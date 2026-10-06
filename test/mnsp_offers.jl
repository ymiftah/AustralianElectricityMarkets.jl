@testset "MNSP offers" begin
    using AustralianElectricityMarkets
    using PowerSystems
    using Dates

    config = HiveConfiguration(hive_location = AEM_TEST_HIVE_DIR, filesystem = "file")
    db = aem_connect(config)
    sys = nem_system(db, RegionalNetworkConfiguration())
    range = DateTime(2025, 1, 1, 11, 55):Minute(5):DateTime(2025, 1, 1, 12, 5)

    @testset "offers attach to the link's interconnector with direction and TLFs" begin
        @test set_mnsp_offers!(sys, db, range) == ["IC2"]
        ic = get_component(AreaInterchange, sys, "IC2")
        @test get_name(get_from_area(ic)) == "NSW1"
        # Interval 11:55 carries the first offer (MAXAVAIL 594), 12:00 the rebid (400).
        avail = get_time_series_values(Deterministic, ic, "mnsp_forward_max_avail"; start_time = first(range))
        @test avail == [594.0, 400.0]
        curves = get_time_series_values(Deterministic, ic, "mnsp_forward_offer"; start_time = first(range))
        @test get_x_coords(curves[1]) == [0.0, 100.0, 200.0, 300.0, 400.0, 494.0]
        @test get_y_coords(curves[2]) == [80.0, 61.0, 75.0, 89.0]
        info = get_ext(ic)
        @test info["mnsp_forward"]["link_id"] == "BLNKTAS"
        @test info["mnsp_reverse"]["link_id"] == "BLNKVIC"
        @test info["mnsp_reverse"]["from_region_tlf"] == 0.9907
    end

    @testset "an interconnector without a complete offer pair keeps its free-flow model" begin
        sys2 = nem_system(db, RegionalNetworkConfiguration())
        later = DateTime(2030, 1, 1):Minute(5):DateTime(2030, 1, 1, 0, 10)
        @test_logs (:warn, r"free-flow") match_mode = :any @test isempty(set_mnsp_offers!(sys2, db, later))
        @test !has_time_series(get_component(AreaInterchange, sys2, "IC2"))
    end

    @test_throws ArgumentError set_mnsp_offers!(sys, db, DateTime(2025, 1, 1):Minute(30):DateTime(2025, 1, 1, 2))
end
