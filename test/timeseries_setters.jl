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
            @test isapprox(got_up, rows.RAMPUPRATE ./ base_power; atol = 1.0e-8)
            @test isapprox(got_down, rows.RAMPDOWNRATE ./ base_power; atol = 1.0e-8)
            @test isapprox(got_init, rows.INITIALMW ./ base_power; atol = 1.0e-8)
        end

        @testset "values are per-unit of the system base, matching DISPATCHLOAD exactly" begin
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

                @test isapprox(got_up, rows.RAMPUPRATE ./ base_power; atol = 1.0e-8)
                @test isapprox(got_down, rows.RAMPDOWNRATE ./ base_power; atol = 1.0e-8)
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
            duids = ["BW01", "BW02", "BW03", "BW04", "ER01", "ER02"]

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
end
