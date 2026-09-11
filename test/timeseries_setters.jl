@testset "Time Series Setter Tests" begin
    using AustralianElectricityMarkets
    using PowerSystems
    using Dates
    using DataFrames
    using Statistics
    import TimeSeries

    hive_dir = AEM_TEST_HIVE_DIR
    @test isdir(hive_dir)

    config = HiveConfiguration(hive_location = hive_dir, filesystem = "file")
    db = aem_connect(config)

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

    @testset "Absolute value correctness (regression: 100x demand/hydro scaling bug)" begin
        sys = deepcopy(sys_base)
        set_units_base_system!(sys, "NATURAL_UNITS")

        resolution = Minute(5)
        start_date = DateTime(2025, 1, 1, 0, 0)
        horizon = Hour(2)
        date_range = start_date:resolution:(start_date + horizon)

        set_demand!(sys, db, date_range; resolution = resolution)
        set_hydro_limits!(sys, db, date_range; resolution = resolution)

        demand_df = read_demand(db; resolution = resolution)
        subset!(demand_df, :SETTLEMENTDATE => ByRow(x -> first(date_range) <= x < last(date_range)))

        @testset "set_demand! matches true TOTALDEMAND (NATURAL_UNITS)" begin
            for load in get_components(PowerLoad, sys)
                region_id = replace(get_name(load), " Load" => "")
                region_demand = @chain demand_df begin
                    subset(:REGIONID => ByRow(==(region_id)))
                    sort(:SETTLEMENTDATE)
                end
                isempty(region_demand) && continue
                reconstructed = get_time_series_values(SingleTimeSeries, load, "max_active_power")
                @test isapprox(reconstructed, region_demand.TOTALDEMAND; atol = 1.0e-6)
            end
        end

        @testset "set_demand! matches true TOTALDEMAND / base_power (SYSTEM_BASE, pu)" begin
            set_units_base_system!(sys, "SYSTEM_BASE")
            base_power = get_base_power(sys)
            for load in get_components(PowerLoad, sys)
                region_id = replace(get_name(load), " Load" => "")
                region_demand = @chain demand_df begin
                    subset(:REGIONID => ByRow(==(region_id)))
                    sort(:SETTLEMENTDATE)
                end
                isempty(region_demand) && continue
                reconstructed = get_time_series_values(SingleTimeSeries, load, "max_active_power")
                @test isapprox(reconstructed, region_demand.TOTALDEMAND ./ base_power; atol = 1.0e-6)
            end
            set_units_base_system!(sys, "NATURAL_UNITS")
        end

        @testset "set_hydro_limits! matches true MAXAVAIL (NATURAL_UNITS)" begin
            energy_bids = read_energy_bids(db, date_range; resolution = resolution)
            hydro_true = @chain energy_bids begin
                subset(:DIRECTION => ByRow(==("GEN")))
                select(:INTERVAL_DATETIME, :DUID, :MAXAVAIL)
                unstack(:INTERVAL_DATETIME, :DUID, :MAXAVAIL; combine = maximum)
                sort(:INTERVAL_DATETIME)
            end
            for gen in get_components(HydroDispatch, sys)
                duid = get_name(gen)
                duid in names(hydro_true) || continue
                reconstructed = get_time_series_values(SingleTimeSeries, gen, "max_active_power")
                true_vals = collect(skipmissing(hydro_true[!, duid]))
                @test isapprox(reconstructed, true_vals; atol = 1.0e-6)
            end
        end
    end

    @testset "Renewable ceilings come from per-unit UIGF" begin
        resolution = Minute(5)
        start_date = DateTime(2025, 1, 1, 0, 0)
        date_range = start_date:resolution:(start_date + Hour(2))

        sys = deepcopy(sys_base)
        set_units_base_system!(sys, "NATURAL_UNITS")
        set_renewable_pv!(sys, db, date_range; resolution = resolution)
        set_renewable_wind!(sys, db, date_range; resolution = resolution)

        uigf = read_uigf(db, date_range; resolution = resolution)

        @testset "read_uigf returns only semi-scheduled units" begin
            @test !isempty(uigf)
            @test Set(names(uigf)) == Set(["SETTLEMENTDATE", "DUID", "UIGF"])
            # BW03 (Solar) and BW04 (Wind) are the fixture's only semi-scheduled DUIDs.
            @test Set(unique(uigf.DUID)) == Set(["BW03", "BW04"])
        end

        @testset "single-interval method agrees with the range method" begin
            # `read_uigf_as_dict` in AustralianElectricityMarketsSimulations reads one interval at a
            # time through this method rather than carrying its own copy of the query, so it
            # must return exactly the range method's rows for that stamp.
            t = start_date + resolution
            one = sort(read_uigf(db, t), :DUID)
            from_range = sort(subset(uigf, :SETTLEMENTDATE => ByRow(==(t))), :DUID)
            @test Set(names(one)) == Set(["SETTLEMENTDATE", "DUID", "UIGF"])
            @test all(==(t), one.SETTLEMENTDATE)
            @test one.DUID == from_range.DUID
            @test isapprox(one.UIGF, from_range.UIGF; atol = 1.0e-6)
        end

        @testset "reconstructed ceiling equals that unit's own UIGF in MW" begin
            n_checked = 0
            for gen in get_components(RenewableDispatch, sys)
                duid = get_name(gen)
                rows = sort(subset(uigf, :DUID => ByRow(==(duid))), :SETTLEMENTDATE)
                isempty(rows) && continue
                reconstructed = get_time_series_values(SingleTimeSeries, gen, "max_active_power")
                @test isapprox(reconstructed, rows.UIGF; atol = 1.0e-6)
                # The fixture's UIGF is strictly below REGISTEREDCAPACITY, so a ceiling pinned
                # to nameplate (the old window-max normalisation) fails here.
                @test all(<(get_max_active_power(gen)), reconstructed)
                n_checked += 1
            end
            @test n_checked == 2
        end

        @testset "ceiling does not depend on the requested window" begin
            # The old regional-aggregate setter normalised by the in-window maximum, so the
            # last interval of any window was pinned to the unit's full nameplate. Seeding one
            # interval at a time (as solve_interval does) must give the same MW as seeding a
            # long range.
            short_range = start_date:resolution:(start_date + Minute(10))
            sys_short = deepcopy(sys_base)
            set_units_base_system!(sys_short, "NATURAL_UNITS")
            set_renewable_pv!(sys_short, db, short_range; resolution = resolution)

            for gen in get_components(x -> get_prime_mover_type(x) == PrimeMovers.PVe, RenewableDispatch, sys_short)
                short_vals = get_time_series_values(SingleTimeSeries, gen, "max_active_power")
                long_gen = get_component(RenewableDispatch, sys, get_name(gen))
                long_vals = get_time_series_values(SingleTimeSeries, long_gen, "max_active_power")
                @test isapprox(short_vals, long_vals[1:length(short_vals)]; atol = 1.0e-6)
            end
        end

        @testset "read_uigf throws when DISPATCHLOAD is not cached" begin
            empty_db = aem_connect(HiveConfiguration(hive_location = mktempdir(), filesystem = "file"))
            err = try
                read_uigf(empty_db, date_range; resolution = resolution)
                nothing
            catch e
                e
            end
            @test err isa ArgumentError
            @test occursin("DISPATCHLOAD", err.msg)
        end

        @testset "read_uigf warns and returns empty when cached DISPATCHLOAD predates the UIGF column" begin
            # Legitimate schema evolution (read_hive's union_by_name exists to tolerate it),
            # not a missing download - must not throw, unlike the "not cached at all" case above.
            no_uigf_hive = mktempdir()
            ddb = DuckDB.DB()
            conn = DuckDB.connect(ddb)
            DuckDB.execute(conn, "SET preserve_identifier_case=true")
            df = DataFrame(
                SETTLEMENTDATE = [start_date], DUID = ["BW01"], INTERVENTION = [0],
                TOTALCLEARED = [100.0], archive_month = ["2025-01"],
            )
            DuckDB.register_data_frame(conn, df, "tmp_table")
            table_dir = joinpath(no_uigf_hive, "DISPATCHLOAD")
            mkpath(table_dir)
            DuckDB.execute(conn, "COPY (SELECT * FROM tmp_table) TO '$table_dir' (FORMAT 'PARQUET', PARTITION_BY (archive_month))")
            DuckDB.unregister_table(conn, "tmp_table")

            no_uigf_db = aem_connect(HiveConfiguration(hive_location = no_uigf_hive, filesystem = "file"))
            result = nothing
            @test_logs (:warn, r"UIGF column") match_mode = :any begin
                result = read_uigf(no_uigf_db, date_range; resolution = resolution)
            end
            @test result isa DataFrame
            @test isempty(result)
            @test Set(names(result)) == Set(["SETTLEMENTDATE", "DUID", "UIGF"])
        end
    end

    @testset "read_bids resolution aggregation uses per-bucket mean (regression: scale-then-sum bug)" begin
        # Fixture: every DUID gets a GEN energy bid with MAXAVAIL = 100.0 + i and ten
        # BANDAVAIL bands of 10.0 each, for i in 0:48 at 5-minute intervals from 00:00.
        start_date = DateTime(2025, 1, 1, 0, 0)
        duid = "BW02"

        for (resolution, buckets) in (
                Minute(5) => [0:0, 6:6],
                Minute(30) => [0:0, 1:6],
                Hour(1) => [0:0, 1:12],
            )
            @testset "Resolution: $resolution" begin
                date_range = start_date:resolution:(start_date + Hour(2))
                bids = read_bids(db, date_range; resolution = resolution)
                gen_bids = @chain bids begin
                    subset(:DUID => ByRow(==(duid)), :DIRECTION => ByRow(==("GEN")))
                    sort(:INTERVAL_DATETIME)
                end
                @test !isempty(gen_bids)

                for is in buckets
                    # `ceil` on INTERVAL_DATETIME buckets by the bucket's own end stamp, so the
                    # first (partial) bucket is the singleton i=0, not a full-width bucket.
                    bucket_end = start_date + Minute(5 * last(is))
                    row = only(subset(gen_bids, :INTERVAL_DATETIME => ByRow(==(bucket_end))))

                    expected_maxavail = mean(100.0 .+ is)
                    @test isapprox(row.MAXAVAIL, expected_maxavail; atol = 1.0e-8)
                    # 10 bands of 10.0 each, constant across i, so the bucket mean per band is
                    # still 10.0 and the row's summed BANDAVAILARRAY is 100.0 regardless of
                    # bucket width - including the partial first bucket.
                    @test isapprox(sum(row.BANDAVAILARRAY), 100.0; atol = 1.0e-8)
                end
            end
        end
    end

    @testset "Setters are independent of the units base at write time" begin
        # nem_system leaves the System in SYSTEM_BASE (what every docs page uses);
        # solve_interval switches to NATURAL_UNITS first. Both must store the same series.
        resolution = Minute(5)
        start_date = DateTime(2025, 1, 1, 0, 0)
        date_range = start_date:resolution:(start_date + Hour(2))

        demand_df = read_demand(db; resolution = resolution)
        subset!(demand_df, :SETTLEMENTDATE => ByRow(x -> first(date_range) <= x < last(date_range)))
        uigf = read_uigf(db, date_range; resolution = resolution)

        function seed(write_mode)
            s = deepcopy(sys_base)
            set_units_base_system!(s, write_mode)
            set_demand!(s, db, date_range; resolution = resolution)
            set_renewable_pv!(s, db, date_range; resolution = resolution)
            set_renewable_wind!(s, db, date_range; resolution = resolution)
            set_units_base_system!(s, "NATURAL_UNITS")
            return s
        end

        for write_mode in ("SYSTEM_BASE", "NATURAL_UNITS")
            @testset "written in $write_mode, read in NATURAL_UNITS" begin
                s = seed(write_mode)
                for load in get_components(PowerLoad, s)
                    region_id = replace(get_name(load), " Load" => "")
                    truth = @chain demand_df begin
                        subset(:REGIONID => ByRow(==(region_id)))
                        sort(:SETTLEMENTDATE)
                    end
                    isempty(truth) && continue
                    got = get_time_series_values(SingleTimeSeries, load, "max_active_power")
                    @test isapprox(got, truth.TOTALDEMAND; atol = 1.0e-6)
                end
                for gen in get_components(RenewableDispatch, s)
                    rows = sort(subset(uigf, :DUID => ByRow(==(get_name(gen)))), :SETTLEMENTDATE)
                    isempty(rows) && continue
                    got = get_time_series_values(SingleTimeSeries, gen, "max_active_power")
                    @test isapprox(got, rows.UIGF; atol = 1.0e-6)
                end
            end
        end
    end
end
