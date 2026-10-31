# A local copy adds metered MNSP starting flows without changing the shared fixture.
const AEM_TEST_MNSP_HIVE_DIR = joinpath(mktempdir(), "hive")
cp(AEM_TEST_HIVE_DIR, AEM_TEST_MNSP_HIVE_DIR)
let db = DuckDB.DB()
    rows = DataFrame(
        SETTLEMENTDATE = repeat([DateTime(2025, 1, 1, 11, 55), DateTime(2025, 1, 1, 12)], 2),
        INTERCONNECTORID = fill("IC2", 4), METEREDMWFLOW = [125.0, -75.0, -125.0, 75.0],
        INTERVENTION = [0, 0, 1, 1], MWFLOW = fill(999.0, 4), EXPORTLIMIT = fill(500.0, 4), IMPORTLIMIT = fill(-500.0, 4),
    )
    DuckDB.register_data_frame(db, rows, "mnsp_flow")
    file = joinpath(AEM_TEST_MNSP_HIVE_DIR, "DISPATCHINTERCONNECTORRES", "archive_month=2025-01", "mnsp.parquet")
    mkpath(dirname(file))
    DuckDB.execute(db, "COPY mnsp_flow TO '$file' (FORMAT PARQUET)")
    DuckDB.close(db)
end

@testset "MNSP offers" begin
    using AustralianElectricityMarkets
    using PowerSystems
    using Dates

    config = HiveConfiguration(hive_location = AEM_TEST_MNSP_HIVE_DIR, filesystem = "file")
    db = aem_connect(config)
    sys = nem_system(db, RegionalNetworkConfiguration())
    range = DateTime(2025, 1, 1, 11, 55):Minute(5):DateTime(2025, 1, 1, 12, 5)

    @testset "offers attach to the link's interconnector with direction and TLFs" begin
        @test set_mnsp_offers!(sys, db, range) == ["IC2"]
        @test set_mnsp_offers!(sys, db, range) == ["IC2"]  # idempotent: series are replaced
        ic = get_component(AreaInterchange, sys, "IC2")
        @test get_name(get_from_area(ic)) == "NSW1"
        # Interval 11:55 carries the first offer (MAXAVAIL 594), 12:00 the rebid (400).
        avail = get_time_series_values(SingleTimeSeries, ic, "mnsp_forward_max_avail"; start_time = first(range))
        @test avail == [594.0, 400.0]
        curves = get_time_series_values(SingleTimeSeries, ic, "mnsp_forward_offer"; start_time = first(range))
        @test get_x_coords(curves[1]) == [0.0, 100.0, 200.0, 300.0, 400.0, 494.0]
        @test get_y_coords(curves[2]) == [80.0, 61.0, 75.0, 89.0]
        info = get_ext(ic)
        @test info["mnsp_forward"]["link_id"] == "BLNKTAS"
        @test info["mnsp_reverse"]["link_id"] == "BLNKVIC"
        @test info["mnsp_reverse"]["from_region_tlf"] == 0.9907
        @test get_time_series_values(SingleTimeSeries, ic, "mnsp_initial_flow") == [125.0, -75.0]
        @test get_time_series_values(SingleTimeSeries, ic, "mnsp_forward_ramp_rate") == [200.0, 200.0]
        @test get_time_series_values(SingleTimeSeries, ic, "mnsp_forward_fixed_load") == [0.0, 0.0]
        @test get_time_series_values(SingleTimeSeries, ic, "mnsp_forward_fixed_load_invoked") == [0.0, 0.0]
    end

    @testset "an MNSP without offers fails instead of changing its formulation" begin
        sys2 = nem_system(db, RegionalNetworkConfiguration())
        later = DateTime(2030, 1, 1):Minute(5):DateTime(2030, 1, 1, 0, 10)
        @test_throws r"requires exactly one offer for every interval" set_mnsp_offers!(sys2, db, later)
        @test !has_time_series(get_component(AreaInterchange, sys2, "IC2"))
    end

    @test_throws ArgumentError set_mnsp_offers!(sys, db, DateTime(2025, 1, 1):Minute(30):DateTime(2025, 1, 1, 2))
end

@testset "MNSP input completeness" begin
    range = DateTime(2025, 1, 1, 11, 55):Minute(5):DateTime(2025, 1, 1, 12, 5)
    good_db = aem_connect(HiveConfiguration(hive_location = AEM_TEST_MNSP_HIVE_DIR, filesystem = "file"))

    for table in (:MNSP_DAYOFFER, :MNSP_BIDOFFERPERIOD, :DISPATCH_MNSPBIDTRK, :MNSP_INTERCONNECTOR, :DISPATCHINTERCONNECTORRES)
        @testset "missing $table" begin
            hive = joinpath(mktempdir(), "hive")
            cp(AEM_TEST_MNSP_HIVE_DIR, hive)
            rm(joinpath(hive, string(table)); recursive = true)
            db = aem_connect(HiveConfiguration(hive_location = hive, filesystem = "file"))
            sys = nem_system(good_db, RegionalNetworkConfiguration())
            @test_throws r"not cached" set_mnsp_offers!(sys, db, range)
            @test !has_time_series(get_component(AreaInterchange, sys, "IC2"))
        end
    end

    cases = [
        (:DISPATCH_MNSPBIDTRK, "DELETE FROM input WHERE LINKID = 'BLNKVIC'", r"requires exactly one offer for every interval"),
        (:DISPATCH_MNSPBIDTRK, "DELETE FROM input WHERE SETTLEMENTDATE = TIMESTAMP '2025-01-01 12:00'", r"requires exactly one offer for every interval"),
        (:DISPATCH_MNSPBIDTRK, "DELETE FROM input", r"DISPATCH_MNSPBIDTRK"),
        (:MNSP_DAYOFFER, "UPDATE input SET PRICEBAND1 = NULL", r"invalid PRICEBAND1"),
        (:MNSP_BIDOFFERPERIOD, "UPDATE input SET MAXAVAIL = NULL", r"invalid MAXAVAIL"),
        (:MNSP_BIDOFFERPERIOD, "UPDATE input SET RAMPUPRATE = NULL", r"invalid RAMPUPRATE"),
        (:MNSP_BIDOFFERPERIOD, "UPDATE input SET RAMPUPRATE = -1", r"invalid RAMPUPRATE"),
        (:MNSP_BIDOFFERPERIOD, "UPDATE input SET FIXEDLOAD = -1", r"invalid FIXEDLOAD"),
        (:DISPATCHINTERCONNECTORRES, "UPDATE input SET METEREDMWFLOW = NULL", r"metered flow"),
        (:MNSP_BIDOFFERPERIOD, "UPDATE input SET BANDAVAIL1 = NULL", r"invalid BANDAVAIL1"),
        (:MNSP_INTERCONNECTOR, "UPDATE input SET FROM_REGION_TLF = NULL", r"invalid FROM_REGION_TLF"),
        (:MNSP_INTERCONNECTOR, "UPDATE input SET TO_REGION_TLF = 0", r"invalid TO_REGION_TLF"),
        (:MNSP_INTERCONNECTOR, "DELETE FROM input WHERE LINKID = 'BLNKVIC'", r"requires two registered directional links"),
        (:INTERCONNECTORCONSTRAINT, "UPDATE input SET ICTYPE = NULL WHERE INTERCONNECTORID = 'IC2'", r"IC2 has no valid ICTYPE"),
        (:INTERCONNECTORCONSTRAINT, "UPDATE input SET ICTYPE = 'OTHER' WHERE INTERCONNECTORID = 'IC2'", r"IC2 has no valid ICTYPE"),
        (
            :INTERCONNECTORCONSTRAINT,
            "INSERT INTO input SELECT * REPLACE (TIMESTAMP '2025-01-01 12:00:00' AS EFFECTIVEDATE, 2 AS VERSIONNO, 'REGULATED' AS ICTYPE) " *
                "FROM input WHERE INTERCONNECTORID = 'IC2'",
            r"ICTYPE differs between the first and last interval",
        ),
    ]
    for (table, query, message) in cases
        @testset "$query" begin
            db = damaged_cache(AEM_TEST_MNSP_HIVE_DIR, table, query)
            sys = nem_system(good_db, RegionalNetworkConfiguration())
            @test_throws message set_mnsp_offers!(sys, db, range)
            @test !has_time_series(get_component(AreaInterchange, sys, "IC2"))
        end
    end

    @testset "a failed refresh preserves existing offers" begin
        sys = nem_system(good_db, RegionalNetworkConfiguration())
        set_mnsp_offers!(sys, good_db, range)
        db = damaged_cache(AEM_TEST_MNSP_HIVE_DIR, :DISPATCH_MNSPBIDTRK, "DELETE FROM input WHERE LINKID = 'BLNKVIC'")
        @test_throws r"requires exactly one offer for every interval" set_mnsp_offers!(sys, db, range)
        ic = get_component(AreaInterchange, sys, "IC2")
        @test get_time_series_values(SingleTimeSeries, ic, "mnsp_forward_max_avail") == [594.0, 400.0]
    end

    @testset "regulated standing data needs no MNSP bids or tables" begin
        db = damaged_cache(AEM_TEST_MNSP_HIVE_DIR, :INTERCONNECTORCONSTRAINT, "UPDATE input SET ICTYPE = 'REGULATED'")
        sys = nem_system(db, RegionalNetworkConfiguration())
        @test isempty(set_mnsp_offers!(sys, db, range))
        @test !has_time_series(get_component(AreaInterchange, sys, "IC2"))
        rm(joinpath(db.config.hive_location, "MNSP_DAYOFFER"); recursive = true)
        @test isempty(set_mnsp_offers!(nem_system(good_db, RegionalNetworkConfiguration()), db, range))
    end

end

@testset "MNSP fixed load zero is an active instruction" begin
    db = damaged_cache(AEM_TEST_MNSP_HIVE_DIR, :MNSP_BIDOFFERPERIOD, "UPDATE input SET FIXEDLOAD = 0")
    sys = nem_system(db, RegionalNetworkConfiguration())
    window = DateTime(2025, 1, 1, 11, 55):Minute(5):DateTime(2025, 1, 1, 12, 5)
    set_mnsp_offers!(sys, db, window)
    ic = get_component(AreaInterchange, sys, "IC2")
    @test get_time_series_values(SingleTimeSeries, ic, "mnsp_forward_fixed_load_invoked") == [1.0, 1.0]
end

@testset "MNSP starting flow follows the selected dispatch run" begin
    db = aem_connect(HiveConfiguration(hive_location = AEM_TEST_MNSP_HIVE_DIR, filesystem = "file"))
    sys = nem_system(db, RegionalNetworkConfiguration())
    window = DateTime(2025, 1, 1, 11, 55):Minute(5):DateTime(2025, 1, 1, 12, 5)
    set_mnsp_offers!(sys, db, window; intervention = 1)
    ic = get_component(AreaInterchange, sys, "IC2")
    @test get_time_series_values(SingleTimeSeries, ic, "mnsp_initial_flow") == [-125.0, 75.0]
end
