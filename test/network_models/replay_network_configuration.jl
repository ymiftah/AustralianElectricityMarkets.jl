function _replay_damaged_cache(table, query; source)
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

@testset "ReplayNetworkConfiguration" begin
    @test isdefined(AustralianElectricityMarkets, :ReplayNetworkConfiguration)
    if isdefined(AustralianElectricityMarkets, :ReplayNetworkConfiguration)
        hive = mktempdir()
        create_mock_data(hive; complete_inputs = true)
        write_mock_interconnector_results(hive)
        db = aem_connect(HiveConfiguration(hive_location = hive))
        interval = DateTime(2025, 1, 1, 0, 5):Minute(5):DateTime(2025, 1, 1, 0, 20)
        config = ReplayNetworkConfiguration()
        @test config isa NetworkConfiguration
        required = table_requirements(config)
        @test all(
            in(required), [
                :LOSSMODEL, :LOSSFACTORMODEL, :MNSP_INTERCONNECTOR,
                :MNSP_DAYOFFER, :MNSP_BIDOFFERPERIOD, :DISPATCH_MNSPBIDTRK,
            ]
        )
        @test_throws ArgumentError nem_system(db, config; date_range = first(interval):Minute(10):last(interval))
        @test_throws ArgumentError nem_system(db, config; date_range = first(interval):Minute(5):first(interval))
        sys = nem_system(db, config; date_range = interval)
        gen = get_component(RenewableDispatch, sys, "BW03")
        @test get_ext(gen)["nem_semi_scheduled"] === true
        @test get_time_series_values(SingleTimeSeries, gen, "energy_max_avail"; ignore_scaling_factors = true) .* get_base_power(sys) ≈ [101.0, 102.0, 103.0]
        @test get_time_series_values(SingleTimeSeries, gen, "uigf"; ignore_scaling_factors = true) .* get_base_power(sys) ≈ [41.0, 42.0, 43.0]
        @test !has_time_series(gen, DeterministicSingleTimeSeries, "energy_max_avail")
        @test !isempty(collect(get_components(FCASService, sys)))
        ic = get_component(AreaInterchange, sys, "IC2")
        @test has_time_series(ic, SingleTimeSeries, "mnsp_forward_max_avail")
        @test !has_time_series(ic, SingleTimeSeries, "from_to_flow_limit")
        diagnostic = nem_system(db, config; date_range = interval, interval_flow_limits = true)
        @test has_time_series(get_component(AreaInterchange, diagnostic, "IC2"), SingleTimeSeries, "from_to_flow_limit")
        directory = mktempdir()
        on_disk = nem_system(db, config; date_range = interval, time_series_in_memory = false, time_series_directory = directory)
        @test !isempty(readdir(directory))
        @test get_time_series_values(SingleTimeSeries, get_component(RenewableDispatch, on_disk, "BW03"), "uigf"; ignore_scaling_factors = true) .* get_base_power(on_disk) ≈ [41.0, 42.0, 43.0]
        physical_db = _replay_damaged_cache(
            :DISPATCHLOAD,
            "INSERT INTO input SELECT * REPLACE (1 AS INTERVENTION, INITIALMW + CASE WHEN DUID = 'BW03' THEN 10 ELSE 0 END AS INITIALMW) FROM input WHERE INTERVENTION = 0"; source = hive
        )
        physical = nem_system(physical_db, config; date_range = interval, intervention = 1)
        physical_gen = get_component(RenewableDispatch, physical, "BW03")
        @test get_time_series_values(SingleTimeSeries, physical_gen, "initial_mw"; ignore_scaling_factors = true) .- get_time_series_values(SingleTimeSeries, gen, "initial_mw"; ignore_scaling_factors = true) ≈ fill(10 / get_base_power(sys), 3)
        @testset "missing bids and demand cannot remove participants or create zero demand" begin
            interval = DateTime(2025, 1, 1, 0, 5):Minute(5):DateTime(2025, 1, 1, 0, 15)
            for (table, query, expected) in [
                    (:BIDDAYOFFER_D, "DELETE FROM input WHERE BIDTYPE = 'ENERGY' AND DUID = 'BW02'", r"price.*BW02"),
                    (:BIDPEROFFER_D, "DELETE FROM input WHERE BIDTYPE = 'ENERGY' AND DUID = 'BW01' AND DIRECTION = 'LOAD'", r"BW01 LOAD"),
                    (:BIDPEROFFER_D, "DELETE FROM input WHERE BIDTYPE = 'ENERGY' AND DUID = 'BW02'", r"BW02 GEN"),
                    (:DISPATCHREGIONSUM, "DELETE FROM input WHERE REGIONID = 'VIC1'", r"missing regional demand.*VIC1"),
                    (:DISPATCHREGIONSUM, "DELETE FROM input WHERE SETTLEMENTDATE = TIMESTAMP '2025-01-01 00:10'", r"missing regional demand"),
                ]
                db = _replay_damaged_cache(table, query; source = hive)
                @test_throws expected nem_system(db, ReplayNetworkConfiguration(); date_range = interval)
            end
        end

        @testset "zero availability does not hide a missing ramping unit's offer" begin
            missing_bids = _replay_damaged_cache(:BIDPEROFFER_D, "DELETE FROM input WHERE BIDTYPE = 'ENERGY' AND DUID = 'BW02'"; source = hive)
            db = _replay_damaged_cache(:DISPATCHLOAD, "UPDATE input SET AVAILABILITY = 0 WHERE DUID = 'BW02'"; source = missing_bids.config.hive_location)
            interval = DateTime(2025, 1, 1, 0, 5):Minute(5):DateTime(2025, 1, 1, 0, 15)
            @test_throws r"BW02 GEN" nem_system(db, ReplayNetworkConfiguration(); date_range = interval)
        end

    end
end
