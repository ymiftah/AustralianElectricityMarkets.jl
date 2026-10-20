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
    end

    @testset "an MNSP without offers fails instead of changing its formulation" begin
        sys2 = nem_system(db, RegionalNetworkConfiguration())
        later = DateTime(2030, 1, 1):Minute(5):DateTime(2030, 1, 1, 0, 10)
        @test_throws r"requires exactly one offer for every interval" set_mnsp_offers!(sys2, db, later)
        @test !has_time_series(get_component(AreaInterchange, sys2, "IC2"))
    end

    @test_throws ArgumentError set_mnsp_offers!(sys, db, DateTime(2025, 1, 1):Minute(30):DateTime(2025, 1, 1, 2))
end

# Each damaged cache is private to its test; the source fixture stays intact.
function _mnsp_damaged_cache(table, query)
    hive = joinpath(mktempdir(), "hive")
    cp(AEM_TEST_HIVE_DIR, hive)
    path = joinpath(hive, string(table))
    conn = DuckDB.DB()
    DuckDB.execute(conn, "CREATE TABLE input AS SELECT * FROM read_parquet('$path/**/*.parquet', hive_partitioning = true)")
    DuckDB.execute(conn, query)
    rm(path; recursive = true)
    DuckDB.execute(conn, "COPY input TO '$path' (FORMAT PARQUET, PARTITION_BY (archive_month))")
    DuckDB.close(conn)
    return aem_connect(HiveConfiguration(hive_location = hive, filesystem = "file"))
end

@testset "MNSP input completeness" begin
    range = DateTime(2025, 1, 1, 11, 55):Minute(5):DateTime(2025, 1, 1, 12, 5)
    good_db = aem_connect(HiveConfiguration(hive_location = AEM_TEST_HIVE_DIR, filesystem = "file"))

    for table in (:MNSP_DAYOFFER, :MNSP_BIDOFFERPERIOD, :DISPATCH_MNSPBIDTRK, :MNSP_INTERCONNECTOR)
        @testset "missing $table" begin
            hive = joinpath(mktempdir(), "hive")
            cp(AEM_TEST_HIVE_DIR, hive)
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
        (:MNSP_BIDOFFERPERIOD, "UPDATE input SET BANDAVAIL1 = NULL", r"invalid BANDAVAIL1"),
        (:MNSP_BIDOFFERPERIOD, "UPDATE input SET BANDAVAIL1 = -1", r"invalid BANDAVAIL1"),
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
            db = _mnsp_damaged_cache(table, query)
            sys = nem_system(good_db, RegionalNetworkConfiguration())
            @test_throws message set_mnsp_offers!(sys, db, range)
            @test !has_time_series(get_component(AreaInterchange, sys, "IC2"))
        end
    end

    @testset "a failed refresh preserves existing offers" begin
        sys = nem_system(good_db, RegionalNetworkConfiguration())
        set_mnsp_offers!(sys, good_db, range)
        db = _mnsp_damaged_cache(:DISPATCH_MNSPBIDTRK, "DELETE FROM input WHERE LINKID = 'BLNKVIC'")
        @test_throws r"requires exactly one offer for every interval" set_mnsp_offers!(sys, db, range)
        ic = get_component(AreaInterchange, sys, "IC2")
        @test get_time_series_values(SingleTimeSeries, ic, "mnsp_forward_max_avail") == [594.0, 400.0]
    end

    @testset "regulated standing data needs no MNSP bids" begin
        db = _mnsp_damaged_cache(:INTERCONNECTORCONSTRAINT, "UPDATE input SET ICTYPE = 'REGULATED'")
        sys = nem_system(db, RegionalNetworkConfiguration())
        @test isempty(set_mnsp_offers!(sys, db, range))
        @test !has_time_series(get_component(AreaInterchange, sys, "IC2"))
    end

    @testset "regulated standing data needs no MNSP tables" begin
        db = _mnsp_damaged_cache(:INTERCONNECTORCONSTRAINT, "UPDATE input SET ICTYPE = 'REGULATED'")
        rm(joinpath(db.config.hive_location, "MNSP_DAYOFFER"); recursive = true)
        sys = nem_system(good_db, RegionalNetworkConfiguration())
        @test isempty(set_mnsp_offers!(sys, db, range))
    end
end
