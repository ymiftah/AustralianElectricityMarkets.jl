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
end

@testset "an MNSP cannot enter the regulated formulation without its offers" begin
    sys = nem_system(aem_connect(HiveConfiguration(hive_location = AEM_TEST_HIVE_DIR)), RegionalNetworkConfiguration())
    ic = get_component(AreaInterchange, sys, "IC2")
    @test_throws r"IC2.*MNSP" AEMS._has_mnsp_offers(ic)
    get_ext(ic)["ic_type"] = "REGULATED"
    @test !AEMS._has_mnsp_offers(ic)
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

function _replay_damaged_cache(table, query; source = AEM_TEST_REPLAY_HIVE_DIR)
    hive = joinpath(mktempdir(), "hive")
    cp(source, hive)
    path = joinpath(hive, string(table))
    conn = DuckDB.DB()
    DuckDB.execute(conn, "CREATE TABLE input AS SELECT * FROM read_parquet('$path/**/*.parquet', hive_partitioning = true)")
    DuckDB.execute(conn, query)
    rm(path; recursive = true)
    DuckDB.execute(conn, "COPY input TO '$path' (FORMAT PARQUET, PARTITION_BY (archive_month))")
    DuckDB.close(conn)
    return aem_connect(HiveConfiguration(hive_location = hive))
end

@testset "missing bids and demand cannot remove participants or create zero demand" begin
    range = DateTime(2025, 1, 1, 0, 5):Minute(5):DateTime(2025, 1, 1, 0, 15)
    for (table, query, expected) in [
            (:BIDDAYOFFER_D, "DELETE FROM input WHERE BIDTYPE = 'ENERGY' AND DUID = 'BW02'", r"price.*BW02"),
            (:BIDPEROFFER_D, "DELETE FROM input WHERE BIDTYPE = 'ENERGY' AND DUID = 'BW01' AND DIRECTION = 'LOAD'", r"BW01 LOAD"),
            (:BIDPEROFFER_D, "DELETE FROM input WHERE BIDTYPE = 'ENERGY' AND DUID = 'BW02'", r"BW02 GEN"),
            (:DISPATCHREGIONSUM, "DELETE FROM input WHERE REGIONID = 'VIC1'", r"missing regional demand.*VIC1"),
            (:DISPATCHREGIONSUM, "DELETE FROM input WHERE SETTLEMENTDATE = TIMESTAMP '2025-01-01 00:10'", r"missing regional demand"),
        ]
        db = _replay_damaged_cache(table, query)
        @test_throws expected replication_system(db, range)
    end
end

@testset "zero availability does not hide a missing ramping unit's offer" begin
    missing_bids = _replay_damaged_cache(:BIDPEROFFER_D, "DELETE FROM input WHERE BIDTYPE = 'ENERGY' AND DUID = 'BW02'")
    db = _replay_damaged_cache(:DISPATCHLOAD, "UPDATE input SET AVAILABILITY = 0 WHERE DUID = 'BW02'"; source = missing_bids.config.hive_location)
    range = DateTime(2025, 1, 1, 0, 5):Minute(5):DateTime(2025, 1, 1, 0, 15)
    @test_throws r"BW02 GEN" replication_system(db, range)
end
