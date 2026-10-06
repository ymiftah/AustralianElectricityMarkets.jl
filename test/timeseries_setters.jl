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
                    # subset! logic in setters/timeseries.jl: first(date_range) <= x < last(date_range)
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
                # PUMP2 has no bid and WDR1 bids GEN: unavailable, one aggregated warning each.
                @test_logs (:warn, r"WDR1") (:warn, r"PUMP2") match_mode = :any set_market_bids!(
                    sys, db, date_range; resolution = resolution,
                )
                for gen in get_components(ThermalStandard, sys)
                    # Verify time series exists
                    ta = get_time_series_array(Deterministic, gen, "variable_cost")
                    # In set_market_bids!, Deterministic TS is created with one forecast
                    # at first(date_range). ta contains the values of that forecast.
                    @test length(ta) == length(date_range) - 1
                end

                @testset "Scheduled loads" begin
                    @test !get_available(get_component(InterruptiblePowerLoad, sys, "PUMP2"))
                    @test !get_available(get_component(InterruptiblePowerLoad, sys, "WDR1"))
                    pump = get_component(InterruptiblePowerLoad, sys, "PUMP1")
                    @test get_available(pump)
                    ta = get_time_series_array(Deterministic, pump, "decremental_variable_cost")
                    @test length(ta) == length(date_range) - 1
                    @test !isempty(get_time_series_array(Deterministic, pump, "decremental_initial_input"))
                    # A load has no incremental offer
                    @test !has_time_series(pump, Deterministic, "variable_cost")
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

                        # Energy MAXAVAIL per direction; the mock bids 100 + i MW on both sides,
                        # rising with the interval index i.
                        horizon = length(date_range) - 1
                        avail = with_units_base(sys, "NATURAL_UNITS") do
                            get_storage_energy_max_avail(bat, first(date_range), horizon)
                        end
                        @test !isnothing(avail)
                        @test length(avail.gen) == horizon
                        @test avail.gen ≈ avail.load
                        @test all(x -> 100.0 <= x <= 149.0, avail.gen)
                        @test avail.gen[end] > avail.gen[1]
                    end
                    @test isnothing(get_storage_energy_max_avail(first(get_components(ThermalStandard, sys)), first(date_range), 1))
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

        @testset "set_demand! attaches loss_demand = INITIALSUPPLY + DEMANDFORECAST (NATURAL_UNITS)" begin
            for load in get_components(PowerLoad, sys)
                region_id = replace(get_name(load), " Load" => "")
                region_demand = @chain demand_df begin
                    subset(:REGIONID => ByRow(==(region_id)))
                    sort(:SETTLEMENTDATE)
                end
                isempty(region_demand) && continue
                reconstructed = get_time_series_values(SingleTimeSeries, load, "loss_demand")
                @test isapprox(reconstructed, region_demand.LOSSDEMAND; atol = 1.0e-6)
                @test !isapprox(reconstructed, region_demand.TOTALDEMAND; atol = 1.0e-6)
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

        @testset "read_uigf throws without DUDETAILSUMMARY's SCHEDULE_TYPE" begin
            function save_table(hive, df, table)
                conn = DuckDB.connect(DuckDB.DB())
                DuckDB.execute(conn, "SET preserve_identifier_case=true")
                DuckDB.register_data_frame(conn, df, "tmp_table")
                table_dir = joinpath(hive, table)
                mkpath(table_dir)
                DuckDB.execute(conn, "COPY (SELECT * FROM tmp_table) TO '$table_dir' (FORMAT 'PARQUET', PARTITION_BY (archive_month))")
                return
            end
            hive = mktempdir()
            save_table(
                hive, DataFrame(
                    SETTLEMENTDATE = [start_date], DUID = ["BW03"], INTERVENTION = [0],
                    UIGF = [40.0], archive_month = ["2025-01"],
                ), "DISPATCHLOAD",
            )
            hive_db = aem_connect(HiveConfiguration(hive_location = hive, filesystem = "file"))
            err = try
                read_uigf(hive_db, date_range; resolution = resolution)
                nothing
            catch e
                e
            end
            @test err isa ArgumentError
            @test occursin("DUDETAILSUMMARY is not cached", err.msg)

            save_table(
                hive, DataFrame(
                    DUID = ["BW03"], START_DATE = [DateTime(2020, 1, 1)], archive_month = ["2025-01"],
                ), "DUDETAILSUMMARY",
            )
            err = try
                read_uigf(hive_db, date_range; resolution = resolution)
                nothing
            catch e
                e
            end
            @test err isa ArgumentError
            @test occursin("SCHEDULE_TYPE", err.msg)
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

    @testset "set_nem_dispatch_limits!" begin
        resolution = Minute(5)
        start_date = DateTime(2025, 1, 1, 0, 0)
        date_range = start_date:resolution:(start_date + Hour(2))
        base_power = get_base_power(sys_base)

        truth = read_dispatch_limits(db, date_range)

        @testset "attaches to a thermal, hydro and renewable unit" begin
            sys = deepcopy(sys_base)
            set_nem_dispatch_limits!(sys, db, date_range)

            thermal = get_component(ThermalStandard, sys, "ER01")
            hydro = get_component(HydroDispatch, sys, "BW02")
            renewable = get_component(RenewableDispatch, sys, "BW03")
            @test !isnothing(thermal)
            @test !isnothing(hydro)
            @test !isnothing(renewable)

            for device in (thermal, hydro, renewable)
                for name in ("ramp_up_rate", "ramp_down_rate", "initial_mw", "max_active_power")
                    ta = get_time_series_array(SingleTimeSeries, device, name)
                    @test length(ta) == length(date_range) - 1
                end
            end
        end

        @testset "attaches the full dispatch envelope to a scheduled load" begin
            sys = deepcopy(sys_base)
            set_nem_dispatch_limits!(sys, db, date_range)
            pump = get_component(InterruptiblePowerLoad, sys, "PUMP1")
            for name in ("ramp_up_rate", "ramp_down_rate", "initial_mw", "max_active_power", "availability")
                @test length(get_time_series_array(SingleTimeSeries, pump, name)) == length(date_range) - 1
            end
            rows = sort(subset(truth, :DUID => ByRow(==("PUMP1"))), :SETTLEMENTDATE)
            @test isapprox(
                get_time_series_values(SingleTimeSeries, pump, "initial_mw"), rows.INITIALMW ./ base_power; atol = 1.0e-8,
            )
        end

        @testset "pins a non-scheduled load's energy to zero whatever DISPATCHLOAD meters" begin
            sys = deepcopy(sys_base)
            set_fcas_bids!(sys, db, date_range)
            @test all(>(0.0), subset(truth, :DUID => ByRow(==("ASLOAD1"))).INITIALMW)
            set_nem_dispatch_limits!(sys, db, date_range)
            asload = get_component(InterruptiblePowerLoad, sys, "ASLOAD1")
            @test get_available(asload)
            for name in ("ramp_up_rate", "ramp_down_rate", "initial_mw", "max_active_power", "availability")
                @test all(==(0.0), get_time_series_values(SingleTimeSeries, asload, name))
            end
        end

        @testset "attaches ramp/initial series to a battery, with no max_active_power" begin
            sys = deepcopy(sys_base)
            set_nem_dispatch_limits!(sys, db, date_range)

            battery = get_component(EnergyReservoirStorage, sys, "BW01")
            @test !isnothing(battery)
            for name in ("ramp_up_rate", "ramp_down_rate", "initial_mw")
                ta = get_time_series_array(SingleTimeSeries, battery, name)
                @test length(ta) == length(date_range) - 1
            end
            # A battery's availability comes from its per-direction energy bid, not AVAILABILITY.
            @test !has_time_series(battery, SingleTimeSeries, "max_active_power")

            rows = sort(subset(truth, :DUID => ByRow(==("BW01"))), :SETTLEMENTDATE)
            got_up = get_time_series_values(SingleTimeSeries, battery, "ramp_up_rate")
            got_down = get_time_series_values(SingleTimeSeries, battery, "ramp_down_rate")
            got_init = get_time_series_values(SingleTimeSeries, battery, "initial_mw")
            @test isapprox(got_up, rows.RAMPUPRATE ./ 60 ./ base_power; atol = 1.0e-8)
            @test isapprox(got_down, rows.RAMPDOWNRATE ./ 60 ./ base_power; atol = 1.0e-8)
            @test isapprox(got_init, rows.INITIALMW ./ base_power; atol = 1.0e-8)
        end

        @testset "ramp rates convert MW/h to MW/min and per-unitise; initial_mw matches DISPATCHLOAD exactly, per-unitised" begin
            sys = deepcopy(sys_base)
            set_nem_dispatch_limits!(sys, db, date_range)

            devices = vcat(
                collect(get_components(ThermalStandard, sys)),
                collect(get_components(HydroDispatch, sys)),
                collect(get_components(RenewableDispatch, sys)),
            )
            n_checked = 0
            for device in devices
                duid = get_name(device)
                rows = sort(subset(truth, :DUID => ByRow(==(duid))), :SETTLEMENTDATE)
                isempty(rows) && continue

                got_up = get_time_series_values(SingleTimeSeries, device, "ramp_up_rate")
                got_down = get_time_series_values(SingleTimeSeries, device, "ramp_down_rate")
                got_init = get_time_series_values(SingleTimeSeries, device, "initial_mw")

                @test isapprox(got_up, rows.RAMPUPRATE ./ 60 ./ base_power; atol = 1.0e-8)
                @test isapprox(got_down, rows.RAMPDOWNRATE ./ 60 ./ base_power; atol = 1.0e-8)
                @test isapprox(got_init, rows.INITIALMW ./ base_power; atol = 1.0e-8)
                n_checked += 1
            end
            @test n_checked == 5  # ER01, ER02, BW02, BW03, BW04
        end

        @testset "max_active_power equals AVAILABILITY / static max_active_power for a known DUID and interval" begin
            sys = deepcopy(sys_base)
            set_nem_dispatch_limits!(sys, db, date_range)

            # Mock fixture: availability_for("BW03", i) = 84.0 + (i % 6); the third interval
            # (i=2) is AVAILABILITY = 86.0, and BW03's static max_active_power is its 100 MW
            # REGISTEREDCAPACITY - so the normalised fraction at that interval is exactly 0.86.
            renewable = get_component(RenewableDispatch, sys, "BW03")
            static_cap = with_units_base(() -> get_max_active_power(renewable), sys, "NATURAL_UNITS")
            @test isapprox(static_cap, 100.0; atol = 1.0e-8)
            got = get_time_series_values(
                SingleTimeSeries, renewable, "max_active_power"; ignore_scaling_factors = true,
            )
            @test isapprox(got[3], 86.0 / 100.0; atol = 1.0e-8)
        end

        @testset "availability and initial_mw read back as raw AVAILABILITY/INITIALMW" begin
            sys = deepcopy(sys_base)
            set_nem_dispatch_limits!(sys, db, date_range)
            renewable = get_component(RenewableDispatch, sys, "BW03")
            battery = get_component(EnergyReservoirStorage, sys, "BW01")
            horizon = length(date_range) - 1
            with_units_base(sys, "NATURAL_UNITS") do
                for (device, duid) in ((renewable, "BW03"), (battery, "BW01"))
                    rows = sort(subset(truth, :DUID => ByRow(==(duid))), :SETTLEMENTDATE)
                    @test isapprox(get_initial_mw(device, start_date, horizon), rows.INITIALMW; atol = 1.0e-8)
                end
                rows = sort(subset(truth, :DUID => ByRow(==("BW03"))), :SETTLEMENTDATE)
                @test isapprox(get_energy_availability(renewable, start_date, horizon), rows.AVAILABILITY; atol = 1.0e-8)
            end
            # A battery's availability comes from its energy bid, not AVAILABILITY.
            @test isnothing(get_energy_availability(battery, start_date, horizon))
        end

        @testset "max_active_power's scaling_factor_multiplier round-trips to the MW envelope" begin
            sys = deepcopy(sys_base)
            set_units_base_system!(sys, "NATURAL_UNITS")
            set_nem_dispatch_limits!(sys, db, date_range)

            devices = vcat(
                collect(get_components(ThermalStandard, sys)),
                collect(get_components(HydroDispatch, sys)),
                collect(get_components(RenewableDispatch, sys)),
            )
            n_checked = 0
            for device in devices
                duid = get_name(device)
                rows = sort(subset(truth, :DUID => ByRow(==(duid))), :SETTLEMENTDATE)
                isempty(rows) && continue
                got_mw = get_time_series_values(SingleTimeSeries, device, "max_active_power")
                @test isapprox(got_mw, rows.AVAILABILITY; atol = 1.0e-6)
                n_checked += 1
            end
            @test n_checked == 5  # ER01, ER02, BW02, BW03, BW04
        end

        @testset "max_active_power overwrites UIGF/bid-MAXAVAIL series regardless of call order" begin
            legacy_first = deepcopy(sys_base)
            set_units_base_system!(legacy_first, "NATURAL_UNITS")
            set_renewable_pv!(legacy_first, db, date_range)
            set_renewable_wind!(legacy_first, db, date_range)
            set_hydro_limits!(legacy_first, db, date_range)
            set_nem_dispatch_limits!(legacy_first, db, date_range)

            dispatch_only = deepcopy(sys_base)
            set_units_base_system!(dispatch_only, "NATURAL_UNITS")
            set_nem_dispatch_limits!(dispatch_only, db, date_range)

            for (type, duid) in ((RenewableDispatch, "BW03"), (RenewableDispatch, "BW04"), (HydroDispatch, "BW02"))
                legacy_device = get_component(type, legacy_first, duid)
                dispatch_device = get_component(type, dispatch_only, duid)
                got_legacy_first = get_time_series_values(SingleTimeSeries, legacy_device, "max_active_power")
                got_dispatch_only = get_time_series_values(SingleTimeSeries, dispatch_device, "max_active_power")

                rows = sort(subset(truth, :DUID => ByRow(==(duid))), :SETTLEMENTDATE)
                # AVAILABILITY-derived, not UIGF/bid-MAXAVAIL-derived: proves the overwrite
                # actually happened, not merely that a series with this name exists.
                @test isapprox(got_legacy_first, rows.AVAILABILITY; atol = 1.0e-6)
                # Whether a "max_active_power" series already existed before
                # set_nem_dispatch_limits! ran doesn't change its outcome.
                @test isapprox(got_legacy_first, got_dispatch_only; atol = 1.0e-10)
            end
        end

        @testset "rates vary per interval, not a scalar" begin
            sys = deepcopy(sys_base)
            set_nem_dispatch_limits!(sys, db, date_range)
            thermal = get_component(ThermalStandard, sys, "ER01")
            @test length(unique(get_time_series_values(SingleTimeSeries, thermal, "ramp_up_rate"))) > 1
            @test length(unique(get_time_series_values(SingleTimeSeries, thermal, "ramp_down_rate"))) > 1
            @test length(unique(get_time_series_values(SingleTimeSeries, thermal, "initial_mw"))) > 1
        end

        @testset "JSON round-trip" begin
            sys = deepcopy(sys_base)
            set_nem_dispatch_limits!(sys, db, date_range)

            mktpath = mktempdir()
            json_path = joinpath(mktpath, "sys.json")
            to_json(sys, json_path)
            sys2 = System(json_path)

            thermal1 = get_component(ThermalStandard, sys, "ER01")
            thermal2 = get_component(ThermalStandard, sys2, "ER01")
            for name in ("ramp_up_rate", "ramp_down_rate", "initial_mw")
                v1 = get_time_series_values(SingleTimeSeries, thermal1, name)
                v2 = get_time_series_values(SingleTimeSeries, thermal2, name)
                @test isapprox(v1, v2; atol = 1.0e-10)
            end
        end

        @testset "missing ramp data throws, naming the DUID" begin
            bad_hive = mktempdir()
            ddb = DuckDB.DB()
            conn = DuckDB.connect(ddb)
            DuckDB.execute(conn, "SET preserve_identifier_case=true")

            short_range = start_date:resolution:(start_date + Minute(10))
            grid = collect(short_range)[1:(end - 1)]  # 3 intervals
            duids = ["BW02", "BW03", "BW04", "ER01", "ER02"]

            rows = DataFrame(
                SETTLEMENTDATE = DateTime[], DUID = String[], INTERVENTION = Int[],
                INITIALMW = Union{Float64, Missing}[], RAMPUPRATE = Union{Float64, Missing}[],
                RAMPDOWNRATE = Union{Float64, Missing}[], AVAILABILITY = Union{Float64, Missing}[],
            )
            for (i, t) in enumerate(grid), duid in duids
                bad = duid == "ER01" && i == 2
                push!(
                    rows,
                    (
                        SETTLEMENTDATE = t, DUID = duid, INTERVENTION = 0,
                        INITIALMW = 50.0, RAMPUPRATE = bad ? missing : 5.0, RAMPDOWNRATE = 4.0,
                        AVAILABILITY = 100.0,
                    ),
                )
            end
            rows[!, :archive_month] = fill("2025-01", nrow(rows))

            DuckDB.register_data_frame(conn, rows, "tmp_table")
            table_dir = joinpath(bad_hive, "DISPATCHLOAD")
            mkpath(table_dir)
            DuckDB.execute(conn, "COPY (SELECT * FROM tmp_table) TO '$table_dir' (FORMAT 'PARQUET', PARTITION_BY (archive_month))")
            DuckDB.unregister_table(conn, "tmp_table")

            bad_db = aem_connect(HiveConfiguration(hive_location = bad_hive, filesystem = "file"))
            sys = deepcopy(sys_base)

            err = try
                set_nem_dispatch_limits!(sys, bad_db, short_range)
                nothing
            catch e
                e
            end
            @test err isa ArgumentError
            @test occursin("ER01", err.msg)
            # Throwing leaves sys untouched, even for the devices with perfectly good data.
            @test !has_time_series(get_component(ThermalStandard, sys, "ER02"), SingleTimeSeries, "ramp_up_rate")

            @test_logs (:warn, r"ER01") match_mode = :any begin
                set_nem_dispatch_limits!(sys, bad_db, short_range; allow_missing_ramp_rates = true)
            end
            @test !has_time_series(get_component(ThermalStandard, sys, "ER01"), SingleTimeSeries, "ramp_up_rate")
            @test has_time_series(get_component(ThermalStandard, sys, "ER02"), SingleTimeSeries, "ramp_up_rate")
            @test has_time_series(get_component(HydroDispatch, sys, "BW02"), SingleTimeSeries, "ramp_up_rate")
        end

        @testset "missing AVAILABILITY throws, naming the DUID" begin
            bad_hive = mktempdir()
            ddb = DuckDB.DB()
            conn = DuckDB.connect(ddb)
            DuckDB.execute(conn, "SET preserve_identifier_case=true")

            short_range = start_date:resolution:(start_date + Minute(10))
            grid = collect(short_range)[1:(end - 1)]  # 3 intervals
            duids = ["BW02", "BW03", "BW04", "ER01", "ER02"]

            rows = DataFrame(
                SETTLEMENTDATE = DateTime[], DUID = String[], INTERVENTION = Int[],
                INITIALMW = Union{Float64, Missing}[], RAMPUPRATE = Union{Float64, Missing}[],
                RAMPDOWNRATE = Union{Float64, Missing}[], AVAILABILITY = Union{Float64, Missing}[],
            )
            for (i, t) in enumerate(grid), duid in duids
                bad = duid == "ER01" && i == 2
                push!(
                    rows,
                    (
                        SETTLEMENTDATE = t, DUID = duid, INTERVENTION = 0,
                        INITIALMW = 50.0, RAMPUPRATE = 5.0, RAMPDOWNRATE = 4.0,
                        AVAILABILITY = bad ? missing : 100.0,
                    ),
                )
            end
            rows[!, :archive_month] = fill("2025-01", nrow(rows))

            DuckDB.register_data_frame(conn, rows, "tmp_table")
            table_dir = joinpath(bad_hive, "DISPATCHLOAD")
            mkpath(table_dir)
            DuckDB.execute(conn, "COPY (SELECT * FROM tmp_table) TO '$table_dir' (FORMAT 'PARQUET', PARTITION_BY (archive_month))")
            DuckDB.unregister_table(conn, "tmp_table")

            bad_db = aem_connect(HiveConfiguration(hive_location = bad_hive, filesystem = "file"))
            sys = deepcopy(sys_base)

            err = try
                set_nem_dispatch_limits!(sys, bad_db, short_range)
                nothing
            catch e
                e
            end
            @test err isa ArgumentError
            @test occursin("ER01", err.msg)
            @test !has_time_series(get_component(ThermalStandard, sys, "ER02"), SingleTimeSeries, "max_active_power")

            @test_logs (:warn, r"ER01") match_mode = :any begin
                set_nem_dispatch_limits!(sys, bad_db, short_range; allow_missing_ramp_rates = true)
            end
            @test !has_time_series(get_component(ThermalStandard, sys, "ER01"), SingleTimeSeries, "max_active_power")
            @test has_time_series(get_component(ThermalStandard, sys, "ER02"), SingleTimeSeries, "max_active_power")
        end

        @testset "zero AVAILABILITY and zero ramp rates are carried through, not rejected" begin
            # AEMO publishes AVAILABILITY = 0 for an unavailable unit (or a PV farm at night)
            # and RAMPUPRATE/RAMPDOWNRATE = 0 for a unit held at fixed output. Both are real
            # dispatch limits, so they must reach the System rather than drop the device.
            zero_hive = mktempdir()
            ddb = DuckDB.DB()
            conn = DuckDB.connect(ddb)
            DuckDB.execute(conn, "SET preserve_identifier_case=true")

            short_range = start_date:resolution:(start_date + Minute(10))
            grid = collect(short_range)[1:(end - 1)]  # 3 intervals
            duids = ["BW01", "BW02", "BW03", "BW04", "ER01", "ER02", "PUMP1", "PUMP2", "WDR1"]

            rows = DataFrame(
                SETTLEMENTDATE = DateTime[], DUID = String[], INTERVENTION = Int[],
                INITIALMW = Union{Float64, Missing}[], RAMPUPRATE = Union{Float64, Missing}[],
                RAMPDOWNRATE = Union{Float64, Missing}[], AVAILABILITY = Union{Float64, Missing}[],
            )
            for t in grid, duid in duids
                unavailable = duid == "ER01"   # offline: zero availability
                pinned = duid == "ER02"        # available but cannot move
                push!(
                    rows,
                    (
                        SETTLEMENTDATE = t, DUID = duid, INTERVENTION = 0,
                        INITIALMW = unavailable ? 0.0 : 50.0,
                        RAMPUPRATE = pinned ? 0.0 : 5.0,
                        RAMPDOWNRATE = pinned ? 0.0 : 4.0,
                        AVAILABILITY = unavailable ? 0.0 : 100.0,
                    ),
                )
            end
            rows[!, :archive_month] = fill("2025-01", nrow(rows))

            DuckDB.register_data_frame(conn, rows, "tmp_table")
            table_dir = joinpath(zero_hive, "DISPATCHLOAD")
            mkpath(table_dir)
            DuckDB.execute(conn, "COPY (SELECT * FROM tmp_table) TO '$table_dir' (FORMAT 'PARQUET', PARTITION_BY (archive_month))")
            DuckDB.unregister_table(conn, "tmp_table")

            zero_db = aem_connect(HiveConfiguration(hive_location = zero_hive, filesystem = "file"))
            sys = deepcopy(sys_base)

            @test_nowarn set_nem_dispatch_limits!(sys, zero_db, short_range)

            battery = get_component(EnergyReservoirStorage, sys, "BW01")
            @test has_time_series(battery, SingleTimeSeries, "ramp_up_rate")
            @test !has_time_series(battery, SingleTimeSeries, "max_active_power")

            offline = get_component(ThermalStandard, sys, "ER01")
            @test all(
                iszero,
                get_time_series_values(
                    SingleTimeSeries, offline, "max_active_power"; ignore_scaling_factors = true,
                ),
            )

            fixed = get_component(ThermalStandard, sys, "ER02")
            @test all(iszero, get_time_series_values(SingleTimeSeries, fixed, "ramp_up_rate"))
            @test all(iszero, get_time_series_values(SingleTimeSeries, fixed, "ramp_down_rate"))
            @test has_time_series(get_component(HydroDispatch, sys, "BW02"), SingleTimeSeries, "ramp_up_rate")
        end

        @testset "negative AVAILABILITY throws, naming the DUID" begin
            neg_hive = mktempdir()
            ddb = DuckDB.DB()
            conn = DuckDB.connect(ddb)
            DuckDB.execute(conn, "SET preserve_identifier_case=true")

            short_range = start_date:resolution:(start_date + Minute(10))
            grid = collect(short_range)[1:(end - 1)]  # 3 intervals
            duids = ["BW02", "BW03", "BW04", "ER01", "ER02"]

            rows = DataFrame(
                SETTLEMENTDATE = DateTime[], DUID = String[], INTERVENTION = Int[],
                INITIALMW = Union{Float64, Missing}[], RAMPUPRATE = Union{Float64, Missing}[],
                RAMPDOWNRATE = Union{Float64, Missing}[], AVAILABILITY = Union{Float64, Missing}[],
            )
            for (i, t) in enumerate(grid), duid in duids
                bad = duid == "ER01" && i == 2
                push!(
                    rows,
                    (
                        SETTLEMENTDATE = t, DUID = duid, INTERVENTION = 0,
                        INITIALMW = 50.0, RAMPUPRATE = bad ? -1.0 : 5.0, RAMPDOWNRATE = 4.0,
                        AVAILABILITY = bad ? -100.0 : 100.0,
                    ),
                )
            end
            rows[!, :archive_month] = fill("2025-01", nrow(rows))

            DuckDB.register_data_frame(conn, rows, "tmp_table")
            table_dir = joinpath(neg_hive, "DISPATCHLOAD")
            mkpath(table_dir)
            DuckDB.execute(conn, "COPY (SELECT * FROM tmp_table) TO '$table_dir' (FORMAT 'PARQUET', PARTITION_BY (archive_month))")
            DuckDB.unregister_table(conn, "tmp_table")

            neg_db = aem_connect(HiveConfiguration(hive_location = neg_hive, filesystem = "file"))
            sys = deepcopy(sys_base)

            err = try
                set_nem_dispatch_limits!(sys, neg_db, short_range)
                nothing
            catch e
                e
            end
            @test err isa ArgumentError
            @test occursin("ER01", err.msg)
            @test !has_time_series(get_component(ThermalStandard, sys, "ER02"), SingleTimeSeries, "max_active_power")
        end

        @testset "zero static max_active_power throws, naming the DUID" begin
            sys = deepcopy(sys_base)
            thermal = get_component(ThermalStandard, sys, "ER01")
            with_units_base(sys, "NATURAL_UNITS") do
                set_active_power_limits!(thermal, (min = 0.0, max = 0.0))
                return
            end

            err = try
                set_nem_dispatch_limits!(sys, db, date_range)
                nothing
            catch e
                e
            end
            @test err isa ArgumentError
            @test occursin("ER01", err.msg)
            @test !has_time_series(get_component(HydroDispatch, sys, "BW02"), SingleTimeSeries, "max_active_power")

            @test_logs (:warn, r"ER01") match_mode = :any begin
                set_nem_dispatch_limits!(sys, db, date_range; allow_missing_ramp_rates = true)
            end
            @test !has_time_series(thermal, SingleTimeSeries, "max_active_power")
            @test has_time_series(get_component(HydroDispatch, sys, "BW02"), SingleTimeSeries, "max_active_power")
        end
    end

    @testset "set_fcas_scaling_inputs!" begin
        resolution = Minute(5)
        start_date = DateTime(2025, 1, 1, 0, 0)
        date_range = start_date:resolution:(start_date + Hour(2))
        base_power = get_base_power(sys_base)

        truth = read_fcas_scaling_inputs(db, date_range)

        @testset "attaches AGC enablement/ramp series to every DUID with scaling rows" begin
            sys = deepcopy(sys_base)
            set_fcas_scaling_inputs!(sys, db, date_range)

            devices = vcat(
                collect(get_components(Generator, sys)), collect(get_components(EnergyReservoirStorage, sys)),
            )
            @test length(devices) == 6  # BW01, BW02, BW03, BW04, ER01, ER02

            for device in devices
                duid = get_name(device)
                rows = sort(subset(truth, :DUID => ByRow(==(duid))), :SETTLEMENTDATE)
                @test !isempty(rows)

                got_raise_min = get_time_series_values(SingleTimeSeries, device, "fcas_agc_enablement_min_RAISEREG")
                got_raise_max = get_time_series_values(SingleTimeSeries, device, "fcas_agc_enablement_max_RAISEREG")
                got_lower_min = get_time_series_values(SingleTimeSeries, device, "fcas_agc_enablement_min_LOWERREG")
                got_lower_max = get_time_series_values(SingleTimeSeries, device, "fcas_agc_enablement_max_LOWERREG")
                got_raise_rate = get_time_series_values(SingleTimeSeries, device, "fcas_agc_ramp_rate_RAISEREG")
                got_lower_rate = get_time_series_values(SingleTimeSeries, device, "fcas_agc_ramp_rate_LOWERREG")
                got_agc_status = get_time_series_values(SingleTimeSeries, device, "fcas_agc_status")

                @test isapprox(got_raise_min, rows.RAISEREGENABLEMENTMIN ./ base_power; atol = 1.0e-9)
                @test isapprox(got_raise_max, rows.RAISEREGENABLEMENTMAX ./ base_power; atol = 1.0e-9)
                @test isapprox(got_lower_min, rows.LOWERREGENABLEMENTMIN ./ base_power; atol = 1.0e-9)
                @test isapprox(got_lower_max, rows.LOWERREGENABLEMENTMAX ./ base_power; atol = 1.0e-9)
                @test isapprox(got_raise_rate, rows.RAMPUPRATE ./ base_power; atol = 1.0e-9)
                @test isapprox(got_lower_rate, rows.RAMPDOWNRATE ./ base_power; atol = 1.0e-9)
                @test isapprox(got_agc_status, rows.AGCSTATUS; atol = 1.0e-9)

                initial_time = start_date
                horizon = length(date_range) - 1
                @test get_fcas_agc_status(device, initial_time, horizon) == round.(Int, rows.AGCSTATUS)
            end
        end

        @testset "get_fcas_agc_status is nothing when fcas_agc_status is not attached" begin
            sys = deepcopy(sys_base)
            device = get_component(ThermalStandard, sys, "ER01")
            @test isnothing(get_fcas_agc_status(device, start_date, length(date_range) - 1))
        end

        @testset "get_fcas_agc_status is nothing at an interval with no AGCSTATUS" begin
            sys = deepcopy(sys_base)
            device = get_component(ThermalStandard, sys, "ER01")
            full_grid = collect(date_range)[1:(end - 1)]
            by_time = Dict(t => (AGCSTATUS = (t == full_grid[1] ? missing : 1.0),) for t in full_grid)
            AustralianElectricityMarkets._attach_fcas_scaling_series!(
                sys, device, by_time, full_grid, :AGCSTATUS, "fcas_agc_status", 1.0,
            )
            status = get_fcas_agc_status(device, start_date, length(full_grid))
            @test isnothing(status[1])
            @test all(==(1), status[2:end])
        end

        @testset "fcas_uigf is attached only for semi-scheduled units (BW03, BW04)" begin
            sys = deepcopy(sys_base)
            set_fcas_scaling_inputs!(sys, db, date_range)

            @test has_time_series(get_component(RenewableDispatch, sys, "BW03"), SingleTimeSeries, "fcas_uigf")
            @test has_time_series(get_component(RenewableDispatch, sys, "BW04"), SingleTimeSeries, "fcas_uigf")
            @test !has_time_series(get_component(ThermalStandard, sys, "ER01"), SingleTimeSeries, "fcas_uigf")
            @test !has_time_series(get_component(HydroDispatch, sys, "BW02"), SingleTimeSeries, "fcas_uigf")
        end

        @testset "an absent interval is stored as NaN; an all-absent column attaches nothing" begin
            sys = deepcopy(sys_base)
            device = get_component(ThermalStandard, sys, "ER01")
            full_grid = collect(date_range)[1:(end - 1)]
            incomplete_by_time = Dict(
                t => (RAISEREGENABLEMENTMIN = (t == full_grid[1] ? missing : 25.0),) for t in full_grid[1:(end - 1)]
            )
            absent_by_time = Dict(t => (RAISEREGENABLEMENTMIN = missing,) for t in full_grid)

            AustralianElectricityMarkets._attach_fcas_scaling_series!(
                sys, device, incomplete_by_time, full_grid, :RAISEREGENABLEMENTMIN,
                "fcas_agc_enablement_min_RAISEREG", base_power,
            )
            got = get_time_series_values(SingleTimeSeries, device, "fcas_agc_enablement_min_RAISEREG")
            @test isnan(got[1]) && isnan(got[end])
            @test all(isapprox.(got[2:(end - 1)], 25.0 / base_power))

            AustralianElectricityMarkets._attach_fcas_scaling_series!(
                sys, device, absent_by_time, full_grid, :RAISEREGENABLEMENTMIN,
                "fcas_agc_enablement_max_RAISEREG", base_power,
            )
            @test !has_time_series(device, SingleTimeSeries, "fcas_agc_enablement_max_RAISEREG")
        end

        @testset "get_scaled_fcas_trapezium skips scaling only at an absent interval" begin
            sys = deepcopy(sys_base)
            set_market_bids!(sys, db, date_range; resolution = resolution)
            set_fcas_bids!(sys, db, date_range; resolution = resolution)

            device = get_component(ThermalStandard, sys, "ER01")
            full_grid = collect(date_range)[1:(end - 1)]
            horizon = length(full_grid)
            # 60 MW/h is a 5 MW AGC ramping capability over 5 minutes.
            by_time = Dict(t => (RAMPUPRATE = (t == full_grid[1] ? missing : 60.0),) for t in full_grid)
            AustralianElectricityMarkets._attach_fcas_scaling_series!(
                sys, device, by_time, full_grid, :RAMPUPRATE, "fcas_agc_ramp_rate_RAISEREG", base_power,
            )

            raw, scaled = with_units_base(sys, "NATURAL_UNITS") do
                (
                    get_fcas_trapezium(device, BidType.RAISEREG, start_date, horizon),
                    get_scaled_fcas_trapezium(device, BidType.RAISEREG, start_date, horizon),
                )
            end
            @test get_max_avail(raw[1]) > 5.0
            @test isequal(Tuple(scaled[1]), Tuple(raw[1]))
            @test all(i -> isapprox(get_max_avail(scaled[i]), min(get_max_avail(raw[i]), 5.0)), 2:horizon)
        end

        @testset "get_scaled_fcas_trapezium narrows the trapezium wherever the AGC input is more restrictive" begin
            sys = deepcopy(sys_base)
            set_market_bids!(sys, db, date_range; resolution = resolution)
            set_fcas_bids!(sys, db, date_range; resolution = resolution)
            set_fcas_scaling_inputs!(sys, db, date_range)

            device = get_component(ThermalStandard, sys, "ER01")
            initial_time = start_date
            horizon = length(date_range) - 1

            raw = get_fcas_trapezium(device, BidType.RAISEREG, initial_time, horizon)
            scaled = get_scaled_fcas_trapezium(device, BidType.RAISEREG, initial_time, horizon)
            @test length(raw) == horizon

            for i in 1:horizon
                @test get_max_avail(scaled[i]) <= get_max_avail(raw[i])
                @test get_enablement_min(scaled[i]) >= get_enablement_min(raw[i])
                @test get_enablement_max(scaled[i]) <= get_enablement_max(raw[i])
            end
            @test any(i -> get_max_avail(scaled[i]) < get_max_avail(raw[i]), 1:horizon)

            # The AGC ramping capability is the MW/h ramp rate times the interval length.
            rows = sort(subset(truth, :DUID => ByRow(==("ER01"))), :SETTLEMENTDATE)
            for (resolution_i, hours) in ((Minute(5), 5 / 60), (Minute(30), 0.5))
                scaled_i = with_units_base(sys, "NATURAL_UNITS") do
                    get_scaled_fcas_trapezium(
                        device, BidType.RAISEREG, initial_time, horizon; resolution = resolution_i,
                    )
                end
                raw_mw = with_units_base(() -> get_max_avail.(get_fcas_trapezium(device, BidType.RAISEREG, initial_time, horizon)), sys, "NATURAL_UNITS")
                @test isapprox(get_max_avail.(scaled_i), min.(raw_mw, rows.RAMPUPRATE .* hours); atol = 1.0e-6)
            end

            # agc_first_interval_only: AGC scaling on the first step only.
            first_only = get_scaled_fcas_trapezium(device, BidType.RAISEREG, initial_time, horizon; agc_first_interval_only = true)
            @test isequal(Tuple(first_only[1]), Tuple(scaled[1]))
            @test all(i -> isequal(Tuple(first_only[i]), Tuple(raw[i])), 2:horizon)

            # agc_ramp_scaling = false: AGC enablement scaling only, MaxAvail left at the bid's.
            no_ramp = get_scaled_fcas_trapezium(device, BidType.RAISEREG, initial_time, horizon; agc_ramp_scaling = false)
            @test get_max_avail.(no_ramp) == get_max_avail.(raw)
            @test get_enablement_min.(no_ramp) == get_enablement_min.(scaled)
            @test get_enablement_max.(no_ramp) == get_enablement_max.(scaled)

            # A contingency market carries no AGC scaling input series at all: unscaled.
            raw_contingency = get_fcas_trapezium(device, BidType.RAISE6SEC, initial_time, horizon)
            scaled_contingency = get_scaled_fcas_trapezium(device, BidType.RAISE6SEC, initial_time, horizon)
            @test all(i -> isequal(Tuple(raw_contingency[i]), Tuple(scaled_contingency[i])), 1:horizon)
        end
    end

    @testset "get_initial_mw reads a battery's net initial_mw series set_nem_dispatch_limits! attaches" begin
        resolution = Minute(5)
        start_date = DateTime(2025, 1, 1, 0, 0)
        date_range = start_date:resolution:(start_date + Hour(2))
        base_power = get_base_power(sys_base)
        truth = read_dispatch_limits(db, date_range)
        rows = sort(subset(truth, :DUID => ByRow(==("BW01"))), :SETTLEMENTDATE)

        @testset "reads net initial_mw off the EnergyReservoirStorage device" begin
            sys = deepcopy(sys_base)
            set_nem_dispatch_limits!(sys, db, date_range)
            bat = get_component(EnergyReservoirStorage, sys, "BW01")
            got = get_time_series_values(SingleTimeSeries, bat, "initial_mw")
            @test isapprox(got, rows.INITIALMW ./ base_power; atol = 1.0e-9)

            initial_time = start_date
            horizon = length(date_range) - 1
            with_units_base(sys, "NATURAL_UNITS") do
                @test isapprox(
                    get_initial_mw(bat, initial_time, horizon), rows.INITIALMW; atol = 1.0e-9,
                )
                return
            end
        end

        @testset "get_initial_mw is nothing when initial_mw is not attached" begin
            sys = deepcopy(sys_base)
            bat = get_component(EnergyReservoirStorage, sys, "BW01")
            @test isnothing(get_initial_mw(bat, start_date, length(date_range) - 1))
        end

        @testset "a device with an incomplete series over date_range is left without it" begin
            sys = deepcopy(sys_base)
            bat = get_component(EnergyReservoirStorage, sys, "BW01")
            # No DISPATCHLOAD rows exist for this far-future range: every interval is missing.
            future_range = DateTime(2099, 1, 1, 0, 0):resolution:(DateTime(2099, 1, 1, 2, 0))
            set_nem_dispatch_limits!(sys, db, future_range; allow_missing_ramp_rates = true)
            @test !has_time_series(bat, SingleTimeSeries, "initial_mw")
        end
    end

    @testset "set_nem_initial_conditions!" begin
        interval = DateTime(2025, 1, 1, 0, 0)
        base_power = get_base_power(sys_base)
        truth = read_dispatch_limits(db, [interval, interval + Minute(1)])

        @testset "seeds active_power on a thermal, hydro and renewable unit (NATURAL_UNITS)" begin
            sys = deepcopy(sys_base)
            set_units_base_system!(sys, "NATURAL_UNITS")
            set_nem_initial_conditions!(sys, db, interval)

            for (type, duid) in
                ((ThermalStandard, "ER01"), (HydroDispatch, "BW02"), (RenewableDispatch, "BW03"))
                device = get_component(type, sys, duid)
                @test !isnothing(device)
                expected = only(subset(truth, :DUID => ByRow(==(duid))).INITIALMW)
                @test isapprox(get_active_power(device), expected; atol = 1.0e-8)
            end
        end

        @testset "seeds active_power on a battery (net MW, NATURAL_UNITS)" begin
            sys = deepcopy(sys_base)
            set_units_base_system!(sys, "NATURAL_UNITS")
            set_nem_initial_conditions!(sys, db, interval)

            battery = get_component(EnergyReservoirStorage, sys, "BW01")
            @test !isnothing(battery)
            expected = only(subset(truth, :DUID => ByRow(==("BW01"))).INITIALMW)
            @test isapprox(get_active_power(battery), expected; atol = 1.0e-8)
        end

        @testset "seeds active_power on a thermal, hydro and renewable unit (SYSTEM_BASE)" begin
            sys = deepcopy(sys_base)
            set_units_base_system!(sys, "SYSTEM_BASE")
            set_nem_initial_conditions!(sys, db, interval)

            for (type, duid) in
                ((ThermalStandard, "ER01"), (HydroDispatch, "BW02"), (RenewableDispatch, "BW03"))
                device = get_component(type, sys, duid)
                expected = only(subset(truth, :DUID => ByRow(==(duid))).INITIALMW)
                @test isapprox(get_active_power(device), expected / base_power; atol = 1.0e-8)
            end
        end

        @testset "missing INITIALMW throws, naming the DUID, and leaves sys untouched" begin
            bad_hive = mktempdir()
            ddb = DuckDB.DB()
            conn = DuckDB.connect(ddb)
            DuckDB.execute(conn, "SET preserve_identifier_case=true")

            duids = ["BW02", "BW03", "BW04", "ER01", "ER02"]
            rows = DataFrame(
                SETTLEMENTDATE = DateTime[], DUID = String[], INTERVENTION = Int[],
                INITIALMW = Union{Float64, Missing}[], RAMPUPRATE = Union{Float64, Missing}[],
                RAMPDOWNRATE = Union{Float64, Missing}[], AVAILABILITY = Union{Float64, Missing}[],
            )
            for duid in duids
                bad = duid == "ER01"
                push!(
                    rows,
                    (
                        SETTLEMENTDATE = interval, DUID = duid, INTERVENTION = 0,
                        INITIALMW = bad ? missing : 50.0, RAMPUPRATE = 5.0, RAMPDOWNRATE = 4.0,
                        AVAILABILITY = 100.0,
                    ),
                )
            end
            rows[!, :archive_month] = fill("2025-01", nrow(rows))

            DuckDB.register_data_frame(conn, rows, "tmp_table")
            table_dir = joinpath(bad_hive, "DISPATCHLOAD")
            mkpath(table_dir)
            DuckDB.execute(conn, "COPY (SELECT * FROM tmp_table) TO '$table_dir' (FORMAT 'PARQUET', PARTITION_BY (archive_month))")
            DuckDB.unregister_table(conn, "tmp_table")

            bad_db = aem_connect(HiveConfiguration(hive_location = bad_hive, filesystem = "file"))
            sys = deepcopy(sys_base)
            er01_before = get_active_power(get_component(ThermalStandard, sys, "ER01"))
            er02_before = get_active_power(get_component(ThermalStandard, sys, "ER02"))

            err = try
                set_nem_initial_conditions!(sys, bad_db, interval)
                nothing
            catch e
                e
            end
            @test err isa ArgumentError
            @test occursin("ER01", err.msg)
            # Throwing leaves sys untouched, even for the devices with perfectly good data.
            @test get_active_power(get_component(ThermalStandard, sys, "ER01")) == er01_before
            @test get_active_power(get_component(ThermalStandard, sys, "ER02")) == er02_before

            @test_logs (:warn, r"ER01") match_mode = :any begin
                set_nem_initial_conditions!(sys, bad_db, interval; allow_missing_ramp_rates = true)
            end
            @test get_active_power(get_component(ThermalStandard, sys, "ER01")) == er01_before
            @test isapprox(
                get_active_power(get_component(ThermalStandard, sys, "ER02")),
                50.0 / get_base_power(sys); atol = 1.0e-8,
            )
        end
    end

    @testset "ramp-down floor above AVAILABILITY raises max_active_power to the floor" begin
        floor_hive = mktempdir()
        ddb = DuckDB.DB()
        conn = DuckDB.connect(ddb)
        DuckDB.execute(conn, "SET preserve_identifier_case=true")

        resolution = Minute(5)
        start_date = DateTime(2025, 1, 1, 0, 0)
        short_range = start_date:resolution:(start_date + Minute(10))
        grid = collect(short_range)[1:(end - 1)]  # 3 intervals
        duids = ["BW01", "BW02", "BW03", "BW04", "ER01", "ER02", "PUMP1", "PUMP2", "WDR1"]

        rows = DataFrame(
            SETTLEMENTDATE = DateTime[], DUID = String[], INTERVENTION = Int[],
            INITIALMW = Union{Float64, Missing}[], RAMPUPRATE = Union{Float64, Missing}[],
            RAMPDOWNRATE = Union{Float64, Missing}[], AVAILABILITY = Union{Float64, Missing}[],
        )
        for t in grid, duid in duids
            # ER01: zero RAMPDOWNRATE and INITIALMW above AVAILABILITY, so the floor is INITIALMW.
            floor_case = duid == "ER01"
            push!(
                rows,
                (
                    SETTLEMENTDATE = t, DUID = duid, INTERVENTION = 0,
                    INITIALMW = floor_case ? 65.41 : 50.0,
                    RAMPUPRATE = 5.0,
                    RAMPDOWNRATE = floor_case ? 0.0 : 4.0,
                    AVAILABILITY = floor_case ? 65.0 : 100.0,
                ),
            )
        end
        rows[!, :archive_month] = fill("2025-01", nrow(rows))

        DuckDB.register_data_frame(conn, rows, "tmp_table")
        table_dir = joinpath(floor_hive, "DISPATCHLOAD")
        mkpath(table_dir)
        DuckDB.execute(conn, "COPY (SELECT * FROM tmp_table) TO '$table_dir' (FORMAT 'PARQUET', PARTITION_BY (archive_month))")
        DuckDB.unregister_table(conn, "tmp_table")

        floor_db = aem_connect(HiveConfiguration(hive_location = floor_hive, filesystem = "file"))
        sys = deepcopy(sys_base)
        set_nem_dispatch_limits!(sys, floor_db, short_range)

        er01 = get_component(ThermalStandard, sys, "ER01")
        static_cap = with_units_base(() -> get_max_active_power(er01), sys, "NATURAL_UNITS")
        got_er01 = get_time_series_values(
            SingleTimeSeries, er01, "max_active_power"; ignore_scaling_factors = true,
        )
        @test all(isapprox.(got_er01, 65.41 / static_cap; atol = 1.0e-8))

        # ER02's floor (50.0 - 4.0/12 ≈ 49.67) is below its AVAILABILITY (100.0).
        er02 = get_component(ThermalStandard, sys, "ER02")
        got_er02 = get_time_series_values(
            SingleTimeSeries, er02, "max_active_power"; ignore_scaling_factors = true,
        )
        @test all(isapprox.(got_er02, 100.0 / static_cap; atol = 1.0e-8))
    end

    @testset "unavailable devices are excluded from the strict setters" begin
        partial_hive = mktempdir()
        ddb = DuckDB.DB()
        conn = DuckDB.connect(ddb)
        DuckDB.execute(conn, "SET preserve_identifier_case=true")

        resolution = Minute(5)
        start_date = DateTime(2025, 1, 1, 0, 0)
        short_range = start_date:resolution:(start_date + Minute(10))
        grid = collect(short_range)[1:(end - 1)]  # 3 intervals
        covered_duids = ["BW01", "BW02", "BW03", "BW04", "ER02", "PUMP1", "PUMP2", "WDR1"]  # every dispatch device except ER01

        rows = DataFrame(
            SETTLEMENTDATE = DateTime[], DUID = String[], INTERVENTION = Int[],
            INITIALMW = Union{Float64, Missing}[], RAMPUPRATE = Union{Float64, Missing}[],
            RAMPDOWNRATE = Union{Float64, Missing}[], AVAILABILITY = Union{Float64, Missing}[],
        )
        for t in grid, duid in covered_duids
            push!(
                rows,
                (
                    SETTLEMENTDATE = t, DUID = duid, INTERVENTION = 0,
                    INITIALMW = 50.0, RAMPUPRATE = 5.0, RAMPDOWNRATE = 4.0, AVAILABILITY = 100.0,
                ),
            )
        end
        rows[!, :archive_month] = fill("2025-01", nrow(rows))

        DuckDB.register_data_frame(conn, rows, "tmp_table")
        table_dir = joinpath(partial_hive, "DISPATCHLOAD")
        mkpath(table_dir)
        DuckDB.execute(conn, "COPY (SELECT * FROM tmp_table) TO '$table_dir' (FORMAT 'PARQUET', PARTITION_BY (archive_month))")
        DuckDB.unregister_table(conn, "tmp_table")

        partial_db = aem_connect(HiveConfiguration(hive_location = partial_hive, filesystem = "file"))

        @testset "unavailable: no throw, and no series added for the unavailable device" begin
            sys = deepcopy(sys_base)
            er01 = get_component(ThermalStandard, sys, "ER01")
            set_available!(er01, false)

            @test_nowarn set_nem_dispatch_limits!(sys, partial_db, short_range)
            @test !has_time_series(er01, SingleTimeSeries, "ramp_up_rate")
            @test has_time_series(get_component(ThermalStandard, sys, "ER02"), SingleTimeSeries, "ramp_up_rate")

            er01_active_power_before = get_active_power(er01)
            @test_nowarn set_nem_initial_conditions!(sys, partial_db, first(short_range))
            @test get_active_power(er01) == er01_active_power_before
        end

        @testset "available: still throws, naming the DUID" begin
            sys = deepcopy(sys_base)

            err = try
                set_nem_dispatch_limits!(sys, partial_db, short_range)
                nothing
            catch e
                e
            end
            @test err isa ArgumentError
            @test occursin("ER01", err.msg)

            err2 = try
                set_nem_initial_conditions!(sys, partial_db, first(short_range))
                nothing
            catch e
                e
            end
            @test err2 isa ArgumentError
            @test occursin("ER01", err2.msg)
        end
    end
    @testset "set_market_bids! refers energy bids to the reference node" begin
        using DuckDB
        # Copies the mock hive, rewriting DUDETAILSUMMARY with `f`.
        function loss_factor_db(f)
            dir = mktempdir()
            cp(AEM_TEST_HIVE_DIR, dir; force = true)
            conn = DuckDB.connect(DuckDB.DB())
            DuckDB.execute(conn, "SET preserve_identifier_case=true")
            table_dir = joinpath(dir, "DUDETAILSUMMARY")
            df = DataFrame(DuckDB.execute(conn, "SELECT * FROM read_parquet('$table_dir/**/*.parquet', hive_partitioning=true)"))
            df = f(df)
            rm(table_dir; recursive = true)
            mkpath(table_dir)
            DuckDB.register_data_frame(conn, df, "tmp_table")
            DuckDB.execute(conn, "COPY (SELECT * FROM tmp_table) TO '$table_dir' (FORMAT 'PARQUET', PARTITION_BY (archive_month))")
            return aem_connect(HiveConfiguration(hive_location = dir, filesystem = "file"))
        end
        fy_change = DateTime(2025, 7, 1)
        # Old financial year (closed at fy_change) and new one (open) for every DUID.
        function two_years(df)
            old = copy(df)
            old.END_DATE = Union{DateTime, Missing}[fy_change for _ in 1:nrow(old)]
            old.DISPATCHTYPE = [d in ("BW01", "BW04") ? "BIDIRECTIONAL" : "GENERATOR" for d in old.DUID]
            old.TRANSMISSIONLOSSFACTOR = [d == "ER01" ? 0.9 : d == "BW01" ? 0.8 : d == "ER02" ? 0.0 : 1.0 for d in old.DUID]
            old.DISTRIBUTIONLOSSFACTOR = Union{Float64, Missing}[d == "ER01" ? 0.97 : d == "BW03" ? missing : 1.0 for d in old.DUID]
            old.SECONDARY_TLF = Union{Float64, Missing}[d == "BW01" ? 0.5 : d == "BW02" ? 0.7 : d == "BW04" ? -1.0 : missing for d in old.DUID]
            new = copy(df)
            new.START_DATE .= fy_change
            new.TRANSMISSIONLOSSFACTOR = [d == "ER01" ? 0.8 : 1.0 for d in new.DUID]
            new.DISTRIBUTIONLOSSFACTOR = fill(1.0, nrow(new))
            new.SECONDARY_TLF = Union{Float64, Missing}[missing for _ in 1:nrow(new)]
            return vcat(old, new)
        end
        ldb = loss_factor_db(two_years)
        start_date = DateTime(2025, 1, 1, 0, 0)
        date_range = start_date:Minute(5):(start_date + Hour(1))
        factor(df, d, col) = only(df[df.DUID .== d, col])

        @testset "read_loss_factors" begin
            old = read_loss_factors(ldb; as_of = start_date)
            @test factor(old, "ER01", :LOAD_LOSS_FACTOR) ≈ 0.9 * 0.97   # DLF is applied
            @test factor(old, "ER01", :GEN_LOSS_FACTOR) ≈ 0.9 * 0.97
            @test factor(old, "BW01", :GEN_LOSS_FACTOR) == 0.5            # BIDIRECTIONAL: secondary on GEN
            @test factor(old, "BW01", :LOAD_LOSS_FACTOR) == 0.8
            @test factor(old, "BW02", :GEN_LOSS_FACTOR) == 1.0            # SECONDARY_TLF ignored off a BDU
            @test factor(old, "ER02", :LOAD_LOSS_FACTOR) == 1.0           # zero TLF
            @test factor(old, "BW03", :LOAD_LOSS_FACTOR) == 1.0           # missing DLF
            @test factor(old, "BW04", :GEN_LOSS_FACTOR) == 1.0            # invalid secondary falls back
            new = read_loss_factors(ldb; as_of = DateTime(2025, 7, 2))
            @test factor(new, "ER01", :LOAD_LOSS_FACTOR) == 0.8
            @test factor(new, "BW01", :GEN_LOSS_FACTOR) == 1.0
            # The new row starts at the boundary; a Date before it resolves the old one.
            @test factor(read_loss_factors(ldb; as_of = fy_change - Minute(5)), "ER01", :LOAD_LOSS_FACTOR) ≈ 0.9 * 0.97
            @test factor(read_loss_factors(ldb; as_of = fy_change), "ER01", :LOAD_LOSS_FACTOR) == 0.8
            # No as_of keeps the open row.
            @test factor(read_loss_factors(ldb), "ER01", :LOAD_LOSS_FACTOR) == 0.8
            for pattern in (r"non-positive distribution", r"non-positive transmission", r"non-positive secondary")
                @test_logs (:warn, pattern) match_mode = :any read_loss_factors(ldb; as_of = start_date)
            end
            @test_logs (:warn, r"change within the date range") match_mode = :any read_loss_factors(ldb; as_of = start_date, through = DateTime(2025, 7, 1, 1))
        end

        sys_raw = nem_system(ldb, RegionalNetworkConfiguration())
        set_market_bids!(sys_raw, ldb, date_range; resolution = Minute(5), loss_factors = false)
        sys_lf = nem_system(ldb, RegionalNetworkConfiguration())
        set_market_bids!(sys_lf, ldb, date_range; resolution = Minute(5))
        prices(sys, name, series = "variable_cost") = with_units_base(sys, "NATURAL_UNITS") do
            ta = get_time_series_array(Deterministic, get_component(Device, sys, name), series)
            return get_y_coords(first(values(ta)))
        end
        mw(sys, name) = with_units_base(sys, "NATURAL_UNITS") do
            ta = get_time_series_array(Deterministic, get_component(Device, sys, name), "variable_cost")
            return get_x_coords(first(values(ta)))
        end

        @testset "prices are divided, MW is not" begin
            @test prices(sys_lf, "ER01") ≈ prices(sys_raw, "ER01") ./ (0.9 * 0.97)
            @test prices(sys_lf, "BW02") ≈ prices(sys_raw, "BW02")
            @test prices(sys_lf, "ER02") ≈ prices(sys_raw, "ER02")
            @test prices(sys_lf, "BW01") ≈ prices(sys_raw, "BW01") ./ 0.5
            @test prices(sys_lf, "BW01", "decremental_variable_cost") ≈
                prices(sys_raw, "BW01", "decremental_variable_cost") ./ 0.8
            @test mw(sys_lf, "ER01") ≈ mw(sys_raw, "ER01")
        end

        @testset "referred prices reorder a merit order" begin
            # Raw prices rise with the band; ER01's referred price exceeds BW02's raw price.
            @test last(prices(sys_raw, "ER01")) < last(prices(sys_raw, "BW02")) + 1.0
            @test last(prices(sys_lf, "ER01")) > last(prices(sys_lf, "BW02"))
        end

        @testset "cache without the loss factor columns keeps raw prices" begin
            bare = loss_factor_db(df -> select(df, Not(:TRANSMISSIONLOSSFACTOR, :DISTRIBUTIONLOSSFACTOR, :SECONDARY_TLF)))
            sys_bare = nem_system(bare, RegionalNetworkConfiguration())
            @test_logs (:warn, r"no loss factor columns") match_mode = :any set_market_bids!(sys_bare, bare, date_range; resolution = Minute(5))
            @test prices(sys_bare, "ER01") ≈ prices(sys_raw, "ER01")
        end

        @testset "a unit without a DUDETAILSUMMARY row keeps raw prices and is named" begin
            # BW02's only row starts after the range, so it has no factor at its start.
            partial = loss_factor_db(df -> subset(two_years(df), [:DUID, :START_DATE] => ByRow((d, t) -> !(d == "BW02" && t < fy_change))))
            sys_partial = nem_system(partial, RegionalNetworkConfiguration())
            @test_logs (:warn, r"No loss factor for bid unit") match_mode = :any set_market_bids!(sys_partial, partial, date_range; resolution = Minute(5))
        end
    end
end
