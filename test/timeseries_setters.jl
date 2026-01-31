@testset "Time Series Setter Tests" begin
    using AustralianElectricityMarkets
    using PowerSystems
    using Dates
    using DataFrames
    using TidierDB
    import TimeSeries

    hive_dir = AEM_TEST_HIVE_DIR
    @test isdir(hive_dir)

    config = HiveConfiguration(hive_location = hive_dir, filesystem = "file")
    db = aem_connect(duckdb(), config)

    # Base system for testing
    sys_base = nem_system(db, RegionalNetworkConfiguration())

    # Test with different resolutions
    for resolution in [Minute(5), Minute(30)]
        @testset "Resolution: $resolution" begin
            # Create a fresh system for each resolution
            sys = deepcopy(sys_base)

            # 2 hour range starting from base_datetime
            # We use 2 hours to ensure at least 4 points for 30min resolution
            start_date = DateTime(2025, 1, 1, 0, 0)
            horizon = Hour(2)
            date_range = start_date:resolution:(start_date + horizon)

            @testset "set_demand!" begin
                set_demand!(sys, db, date_range; resolution = resolution)
                for load in get_components(PowerLoad, sys)
                    ta = get_time_series_array(SingleTimeSeries, load, "max_active_power")
                    # subset! logic in parser.jl: first(date_range) <= x < last(date_range)
                    @test length(ta) == length(date_range) - 1
                    if length(ta) > 1
                        @test TimeSeries.timestamp(ta)[2] - TimeSeries.timestamp(ta)[1] == resolution
                    end
                end
            end

            @testset "set_renewable_pv!" begin
                set_renewable_pv!(sys, db, date_range; resolution = resolution)
                pv_gens = get_components(x -> get_prime_mover_type(x) == PrimeMovers.PVe, RenewableDispatch, sys)
                @test !isempty(pv_gens)
                for gen in pv_gens
                    ta = get_time_series_array(SingleTimeSeries, gen, "max_active_power")
                    @test length(ta) == length(date_range) - 1
                end
            end

            @testset "set_renewable_wind!" begin
                set_renewable_wind!(sys, db, date_range; resolution = resolution)
                wind_gens = get_components(x -> get_prime_mover_type(x) == PrimeMovers.WT, RenewableDispatch, sys)
                @test !isempty(wind_gens)
                for gen in wind_gens
                    ta = get_time_series_array(SingleTimeSeries, gen, "max_active_power")
                    @test length(ta) == length(date_range) - 1
                end
            end

            @testset "set_hydro_limits!" begin
                set_hydro_limits!(sys, db, date_range; resolution = resolution)
                hydro_gens = get_components(HydroDispatch, sys)
                @test !isempty(hydro_gens)
                for gen in hydro_gens
                    ta = get_time_series_array(SingleTimeSeries, gen, "max_active_power")
                    @test length(ta) == length(date_range) - 1
                end
            end

            @testset "set_market_bids!" begin
                set_market_bids!(sys, db, date_range; resolution = resolution)
                for gen in get_components(ThermalStandard, sys)
                    # Verify time series exists
                    ta = get_time_series_array(Deterministic, gen, "variable_cost")
                    # In set_market_bids!, Deterministic TS is created with one forecast
                    # at first(date_range). ta contains the values of that forecast.
                    @test length(ta) == length(date_range) - 1
                end

                @testset "Batteries" begin
                    for bat in get_components(EnergyReservoirStorage, sys)
                        # GEN bids
                        ta_gen = get_time_series_array(Deterministic, bat, "variable_cost")
                        @test length(ta_gen) == length(date_range) - 1

                        # LOAD bids (decremental)
                        ta_load = get_time_series_array(Deterministic, bat, "decremental_variable_cost")
                        @test length(ta_load) == length(date_range) - 1

                        # Initial inputs
                        @test !isempty(get_time_series_array(Deterministic, bat, "incremental_initial_input"))
                        @test !isempty(get_time_series_array(Deterministic, bat, "decremental_initial_input"))
                    end
                end
            end
        end
    end
end
