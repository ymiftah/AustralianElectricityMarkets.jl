@testset "Time Series Setter Tests" begin
    using AustralianElectricityMarkets
    using PowerSystems
    using Dates
    using DataFrames
    using Statistics
    import TimeSeries

    db = aem_connect(HiveConfiguration(hive_location = AEM_TEST_HIVE_DIR, filesystem = "file"))

    # Base system for testing
    sys_base, _ = nem_network(db; date_range = MOCK_DATE_RANGE)

    @testset "demand build rejects incomplete regional demand" begin
        # The mock hive holds demand to 04:00; a window running to 06:00 has no rows for the last two hours.
        start_date = DateTime(2025, 1, 1, 3, 0)
        late_range = start_date:Minute(5):(start_date + Hour(3))
        err = (@test_throws ArgumentError attach_demand!(deepcopy(sys_base), db, late_range; resolution = Minute(5))).value
        @test occursin("missing regional demand inputs", err.msg)
    end

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

            @testset "set_market_bids!" begin
                # PUMP2 has no bid and WDR1 bids GEN: unavailable, one aggregated warning each.
                @test_logs (:warn, r"WDR1") (:warn, r"PUMP2") match_mode = :any set_market_bids!(
                    sys, db, date_range; resolution = resolution,
                )
                @testset "Scheduled loads" begin
                    @test !get_available(get_component(InterruptiblePowerLoad, sys, "PUMP2"))
                    @test !get_available(get_component(InterruptiblePowerLoad, sys, "WDR1"))
                    pump = get_component(InterruptiblePowerLoad, sys, "PUMP1")
                    @test get_available(pump)
                    ta = get_time_series_array(SingleTimeSeries, pump, "bid_energy_offer_curves_load")
                    @test length(ta) == length(date_range) - 1
                    # A load has no incremental bid
                    @test !has_time_series(pump, SingleTimeSeries, "bid_energy_offer_curves_gen")
                end

                @testset "Batteries" begin
                    for bat in get_components(EnergyReservoirStorage, sys)
                        # GEN bids
                        ta_gen = get_time_series_array(SingleTimeSeries, bat, "bid_energy_offer_curves_gen")
                        @test length(ta_gen) == length(date_range) - 1

                        # LOAD bids (decremental)
                        ta_load = get_time_series_array(SingleTimeSeries, bat, "bid_energy_offer_curves_load")
                        @test length(ta_load) == length(date_range) - 1

                        # Energy MAXAVAIL per direction, in MW as offered; the mock bids 100 + i MW on both
                        # sides, rising with the interval index i.
                        horizon = length(date_range) - 1
                        avail = (
                            gen = get_time_series_values(SingleTimeSeries, bat, "bid_energy_max_avail_gen"; start_time = first(date_range), len = horizon),
                            load = get_time_series_values(SingleTimeSeries, bat, "bid_energy_max_avail_load"; start_time = first(date_range), len = horizon),
                        )
                        @test avail.gen ≈ avail.load
                        @test all(x -> 100.0 <= x <= 149.0, avail.gen)
                        @test avail.gen[end] > avail.gen[1]
                    end
                    @test !has_time_series(first(get_components(ThermalStandard, sys)), SingleTimeSeries, "bid_energy_max_avail_load")
                    @test !has_time_series(first(get_components(PowerLoad, sys)), SingleTimeSeries, "bid_energy_offer_curves_gen")
                end
            end
        end
    end

    @testset "set_market_bids! twice keeps one NEMEnergyBid per direction" begin
        sys = deepcopy(sys_base)
        start_date = DateTime(2025, 1, 1, 0, 0)
        first_range = start_date:Minute(5):(start_date + Hour(1))
        second_range = (start_date + Minute(30)):Minute(5):(start_date + Minute(90))
        set_market_bids!(sys, db, first_range)
        set_market_bids!(sys, db, second_range)
        devices = filter(get_available, vcat(collect(get_components(ThermalStandard, sys)), collect(get_components(EnergyReservoirStorage, sys))))
        @test !isempty(devices)
        # One bid per direction, each over the second call's window.
        @test all(devices) do device
            directions = [b.direction for b in AustralianElectricityMarkets.get_energy_bids(AustralianElectricityMarkets._nem_offer_cost(device))]
            return !isempty(directions) && allunique(directions) && all(directions) do direction
                name = AustralianElectricityMarkets.bid_series_name(AustralianElectricityMarkets.BidType.ENERGY, :offer_curves, direction)
                return get_time_series_timestamps(SingleTimeSeries, device, name)[1] == second_range[1]
            end
        end
    end

    @testset "read_uigf" begin
        resolution = Minute(5)
        start_date = DateTime(2025, 1, 1, 0, 0)
        date_range = start_date:resolution:(start_date + Hour(2))

        uigf = read_uigf(db, date_range; resolution = resolution)

        @testset "read_uigf returns only semi-scheduled units" begin
            @test Set(names(uigf)) == Set(["SETTLEMENTDATE", "DUID", "UIGF"])
            # BW03 (Solar) and BW04 (Wind) are the fixture's only semi-scheduled DUIDs.
            @test Set(unique(uigf.DUID)) == Set(["BW03", "BW04"])
        end

        @testset "read_uigf throws when DISPATCHLOAD is not cached" begin
            empty_db = aem_connect(HiveConfiguration(hive_location = mktempdir(), filesystem = "file"))
            err = (@test_throws ArgumentError read_uigf(empty_db, date_range; resolution)).value
            @test occursin("DISPATCHLOAD", err.msg)
        end

        @testset "read_uigf fails when cached DISPATCHLOAD has no UIGF column" begin
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
            cp(joinpath(AEM_TEST_HIVE_DIR, "DUDETAILSUMMARY"), joinpath(no_uigf_hive, "DUDETAILSUMMARY"))

            no_uigf_db = aem_connect(HiveConfiguration(hive_location = no_uigf_hive, filesystem = "file"))
            err = (@test_throws DuckDB.QueryException read_uigf(no_uigf_db, date_range; resolution)).value
            @test occursin("UIGF", string(err.var))
        end

        @testset "read_uigf fails without DUDETAILSUMMARY's SCHEDULE_TYPE" begin
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
            err = (@test_throws ArgumentError read_uigf(hive_db, date_range; resolution)).value
            @test occursin("DUDETAILSUMMARY is not cached", err.msg)

            save_table(
                hive, DataFrame(
                    DUID = ["BW03"], START_DATE = [DateTime(2020, 1, 1)], archive_month = ["2025-01"],
                ), "DUDETAILSUMMARY",
            )
            err = (@test_throws DuckDB.QueryException read_uigf(hive_db, date_range; resolution)).value
            @test occursin("SCHEDULE_TYPE", string(err.var))
        end
    end

    @testset "read_offers" begin
        start_date = DateTime(2025, 1, 1, 0, 0)
        date_range = start_date:Minute(5):(start_date + Hour(1))
        offers = read_offers(db, date_range)
        key_columns = [:SETTLEMENTDATE, :INTERVAL_DATETIME, :DUID, :DIRECTION, :BIDTYPE]
        by_key(df) = sort(df, key_columns)

        @test all(
            c in names(offers) for c in [
                    "PRICEBANDARRAY", "BANDAVAILARRAY", "MAXAVAIL", "MINIMUMLOAD", "DAILYENERGYCONSTRAINT",
                    "FIXEDLOAD", "ROCUP", "ROCDOWN", "ENABLEMENTMIN", "LOWBREAKPOINT", "HIGHBREAKPOINT", "ENABLEMENTMAX",
                ]
        )
        @test eltype(offers.BIDTYPE) == BidType

        @testset "energy rows match read_bids" begin
            energy = by_key(subset(offers, :BIDTYPE => ByRow(==(AustralianElectricityMarkets.BidType.ENERGY))))
            bids = sort(read_bids(db, date_range), [:SETTLEMENTDATE, :INTERVAL_DATETIME, :DUID, :DIRECTION])
            shared = intersect(names(energy), names(bids))
            @test nrow(energy) == nrow(bids)
            @test isequal(select(energy, shared), select(bids, shared))
        end

        @testset "FCAS rows match read_fcas_bids" begin
            fcas = by_key(subset(offers, :BIDTYPE => ByRow(!=(AustralianElectricityMarkets.BidType.ENERGY))))
            reference = by_key(read_fcas_bids(db, date_range, collect(FCAS_BID_TYPES)))
            shared = intersect(names(fcas), names(reference))
            @test nrow(fcas) == nrow(reference)
            @test isequal(select(fcas, shared), select(reference, shared))
        end

        @testset "FIXEDLOAD rows match read_fixed_loads" begin
            loaded = by_key(subset(offers, :FIXEDLOAD => ByRow(>(0)), :BIDTYPE => ByRow(==(AustralianElectricityMarkets.BidType.ENERGY))))
            expected = sort(read_fixed_loads(db, date_range), [:INTERVAL_DATETIME, :DUID, :DIRECTION])
            @test !isempty(expected)
            @test nrow(loaded) == nrow(expected)
            @test loaded.FIXEDLOAD == expected.FIXEDLOAD
            @test loaded.INTERVAL_DATETIME == expected.INTERVAL_DATETIME
        end

        @testset "markets restricts the BIDTYPE rows" begin
            energy_only = read_offers(db, date_range; markets = (AustralianElectricityMarkets.BidType.ENERGY,))
            @test all(==(AustralianElectricityMarkets.BidType.ENERGY), energy_only.BIDTYPE)
            @test nrow(energy_only) == nrow(subset(offers, :BIDTYPE => ByRow(==(AustralianElectricityMarkets.BidType.ENERGY))))
        end

        @testset "fast-start columns come from the daily offer version in force" begin
            late = DateTime(2025, 1, 1, 3, 0):Minute(5):DateTime(2025, 1, 1, 3, 30)
            energy(o) = subset(o, :BIDTYPE => ByRow(==(AustralianElectricityMarkets.BidType.ENERGY)))
            unit(o, duid, direction) = sort(subset(energy(o), :DUID => ByRow(==(duid)), :DIRECTION => ByRow(==(direction))), :INTERVAL_DATETIME)
            bw04 = unit(read_offers(db, late), "BW04", "GEN")
            # 03:00 keeps the initial offer, 03:05 to 03:15 the exact 03:02:34 rebid, 03:20 on the 03:17 rebid.
            @test bw04.INTERVAL_DATETIME == collect(late)[1:(end - 1)]
            @test bw04.T1 == [10.0, 12.0, 12.0, 12.0, 0.0, 0.0]
            @test bw04.MINIMUMLOAD == [0.0, 5.0, 5.0, 5.0, 0.0, 0.0]
            # Price bands and the other units stay on BIDDAYOFFER_D.
            @test all(==(collect(51.0:60.0)), bw04.PRICEBANDARRAY)
            @test all(iszero, unit(read_offers(db, late), "BW02", "GEN").T1)
            @test all(iszero, unit(read_offers(db, late), "PUMP1", "LOAD").T1)
        end

        # A copy of the mock hive with `table` rewritten by `select` (a DuckDB SELECT over `src`), or removed.
        function edited_hive(table; select = nothing)
            hive = joinpath(mktempdir(), "hive")
            cp(AEM_TEST_HIVE_DIR, hive)
            if isnothing(select)
                rm(joinpath(hive, String(table)); recursive = true)
            else
                edit_db = DuckDB.DB()
                for (root, _, files) in walkdir(joinpath(hive, String(table))), f in filter(endswith(".parquet"), files)
                    path = joinpath(root, f)
                    query = replace(select, "src" => "read_parquet('$path')")
                    DuckDB.execute(edit_db, "COPY ($query) TO '$path.new' (FORMAT PARQUET)")
                    mv("$path.new", path; force = true)
                end
                DuckDB.close(edit_db)
            end
            return aem_connect(HiveConfiguration(hive_location = hive, filesystem = "file"))
        end

        @testset "a NULL field of the version in force is kept, not filled from BIDDAYOFFER_D" begin
            late = DateTime(2025, 1, 1, 3, 0):Minute(5):DateTime(2025, 1, 1, 3, 30)
            # The 03:17 rebid, in force from 03:20, leaves T1 empty; BIDDAYOFFER_D's T1 is 10.
            null_db = edited_hive(
                :BIDDAYOFFER;
                select = "SELECT * REPLACE (CASE WHEN DUID = 'BW04' AND VERSIONNO = 3 THEN NULL ELSE T1 END AS T1) FROM src",
            )
            offers = read_offers(null_db, late; markets = (AustralianElectricityMarkets.BidType.ENERGY,))
            bw04 = sort(subset(offers, :DUID => ByRow(==("BW04")), :DIRECTION => ByRow(==("GEN"))), :INTERVAL_DATETIME)
            @test isequal(bw04.T1, [10.0, 12.0, 12.0, 12.0, missing, missing])
        end

        @testset "FCAS offers read without BIDDAYOFFER" begin
            fcas_db = edited_hive(:BIDDAYOFFER)
            raise6 = read_fcas_bids(fcas_db, date_range, AustralianElectricityMarkets.BidType.RAISE6SEC)
            @test nrow(raise6) > 0
            @test_throws ArgumentError read_offers(fcas_db, date_range; markets = (AustralianElectricityMarkets.BidType.ENERGY,))
        end

        @testset "bids read over a Date range" begin
            days = Date(2025, 1, 1):Day(1):Date(2025, 1, 2)
            @test nrow(read_bids(db, days)) > 0
            @test nrow(read_bids(db, days; resolution = Minute(30))) > 0
            @test nrow(read_fcas_bids(db, days, AustralianElectricityMarkets.BidType.RAISE6SEC)) > 0
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
                # `ceil` buckets by the bucket's own end stamp, so the first (partial) bucket is the
                # singleton i=0. The ten 10 MW bands sum to 100 MW in every bucket.
                rows = [only(subset(gen_bids, :INTERVAL_DATETIME => ByRow(==(start_date + Minute(5 * last(is)))))) for is in buckets]
                @test [r.MAXAVAIL for r in rows] ≈ [mean(100.0 .+ is) for is in buckets] atol = 1.0e-8
                @test [sum(r.BANDAVAILARRAY) for r in rows] ≈ fill(100.0, length(buckets)) atol = 1.0e-8
            end
        end
    end

    @testset "Demand matches TOTALDEMAND and LOSSDEMAND whatever the units base at write time" begin
        # Regression: a 100x demand scaling bug. Both write modes must store the same MW series.
        resolution = Minute(5)
        start_date = DateTime(2025, 1, 1, 0, 0)
        date_range = start_date:resolution:(start_date + Hour(2))

        demand_df = read_demand(db, MOCK_DATE_RANGE; resolution = resolution)
        subset!(demand_df, :SETTLEMENTDATE => ByRow(x -> first(date_range) <= x < last(date_range)))

        function seed(write_mode)
            s = deepcopy(sys_base)
            set_units_base_system!(s, write_mode)
            attach_demand!(s, db, date_range; resolution = resolution)
            set_units_base_system!(s, "NATURAL_UNITS")
            return s
        end

        for write_mode in ("SYSTEM_BASE", "NATURAL_UNITS")
            @testset "written in $write_mode, read in NATURAL_UNITS" begin
                s = seed(write_mode)
                wrong = String[]
                for load in get_components(PowerLoad, s)
                    region_id = replace(get_name(load), " Load" => "")
                    truth = @chain demand_df begin
                        subset(:REGIONID => ByRow(==(region_id)))
                        sort(:SETTLEMENTDATE)
                    end
                    isempty(truth) && continue
                    got = get_time_series_values(SingleTimeSeries, load, "max_active_power")
                    loss = get_time_series_values(SingleTimeSeries, load, "loss_demand")
                    isapprox(got, truth.TOTALDEMAND; atol = 1.0e-6) && isapprox(loss, truth.LOSSDEMAND; atol = 1.0e-6) &&
                        !isapprox(loss, truth.TOTALDEMAND; atol = 1.0e-6) || push!(wrong, region_id)
                end
                @test isempty(wrong)
            end
        end
    end

    @testset "read_dispatch_limits aggregates DISPATCHLOAD onto a 30-minute step" begin
        resolution = Minute(5)
        start_date = DateTime(2025, 1, 1, 0, 0)
        date_range = start_date:resolution:(start_date + Hour(2))
        truth = read_dispatch_limits(db, date_range)
        # The mock DISPATCHLOAD starts at `start_date`, so the first bucket is 00:30: its window is complete.
        coarse = (start_date + Minute(30)):Minute(30):(start_date + Hour(2))
        buckets = read_dispatch_limits(db, coarse; resolution = Minute(30))
        got = subset(buckets, :DUID => ByRow(==("PUMP1")))
        @test nrow(got) == length(coarse) - 1
        rows = subset(truth, :DUID => ByRow(==("PUMP1")))
        @test all(eachrow(got)) do b
            window = sort(
                subset(rows, :SETTLEMENTDATE => ByRow(x -> b.SETTLEMENTDATE - Minute(30) < x <= b.SETTLEMENTDATE)),
                :SETTLEMENTDATE,
            )
            return length(window.SETTLEMENTDATE) == 6 && b.INITIALMW == first(window.INITIALMW) &&
                (b.RAMPUPRATE, b.RAMPDOWNRATE, b.AVAILABILITY) ==
                (minimum(window.RAMPUPRATE), minimum(window.RAMPDOWNRATE), minimum(window.AVAILABILITY))
        end
    end

    @testset "set_unit_conditions!" begin
        resolution = Minute(5)
        start_date = DateTime(2025, 1, 1, 0, 0)
        date_range = start_date:resolution:(start_date + Hour(2))
        base_power = get_base_power(sys_base)
        RAISE = AustralianElectricityMarkets.BidType.RAISEREG
        LOWER = AustralianElectricityMarkets.BidType.LOWERREG
        fcas_name = AustralianElectricityMarkets.fcas_series_name
        truth = read_unit_conditions(db, date_range)
        # The natural-unit values of a unit's telemetry or observed-state series, read through its key.
        unit_values(device, key) = get_time_series_values(SingleTimeSeries, device, get_name(key); ignore_scaling_factors = true)

        # Copies the cache at `table` and rewrites that table with `transform!`.
        function corrupt_cache(table, transform!)
            hive = mktempdir()
            cp(AEM_TEST_HIVE_DIR, hive; force = true)
            bad = aem_connect(HiveConfiguration(hive_location = hive))
            frame = DataFrame(DuckDB.execute(bad.db, "SELECT * FROM " * read_hive(bad, table)))
            transform!(frame)
            folder = joinpath(hive, string(table))
            rm(folder; recursive = true)
            mkpath(folder)
            DuckDB.register_data_frame(bad.db, frame, "corrupt_data")
            DuckDB.execute(bad.db, "COPY corrupt_data TO '$folder' (FORMAT PARQUET, PARTITION_BY (archive_month))")
            DuckDB.unregister_table(bad.db, "corrupt_data")
            return bad
        end

        @testset "attaches the operating condition of a scheduled load in natural units, through its keys" begin
            sys = deepcopy(sys_base)
            set_unit_conditions!(sys, db, date_range)
            pump = get_component(InterruptiblePowerLoad, sys, "PUMP1")
            rows = sort(subset(truth, :DUID => ByRow(==("PUMP1"))), :SETTLEMENTDATE)
            telemetry, observed = get_telemetry(pump), get_observed_state(pump)
            # The mode is the previous interval's DISPATCHMODE; the mock's prior row at 23:55 is mode 0.
            @test [
                unit_values(pump, observed.initial_mw), unit_values(pump, observed.dispatch_mode),
                unit_values(pump, telemetry.agc_status), unit_values(pump, telemetry.ramp_up_limit),
                unit_values(pump, telemetry.ramp_down_limit), unit_values(pump, telemetry.raise_reg_max_avail),
                unit_values(pump, telemetry.lower_reg_max_avail), first.(unit_values(pump, telemetry.lower_reg_enablement)),
                last.(unit_values(pump, telemetry.raise_reg_enablement)),
            ] == [
                rows.INITIALMW, [0.0; rows.DISPATCHMODE[1:(end - 1)]], rows.AGCSTATUS, rows.RAMPUPRATE, rows.RAMPDOWNRATE,
                rows.RAISEREGAVAILABILITY, rows.LOWERREGAVAILABILITY, rows.LOWERREGENABLEMENTMIN, rows.RAISEREGENABLEMENTMAX,
            ]
            @test isnothing(telemetry.uigf)
            # Ramps, the upper limit and AGC ramp rates are derived in AEMSim, not here.
            @test !has_time_series(pump, SingleTimeSeries, "ramp_up_rate")
            @test !has_time_series(pump, SingleTimeSeries, "max_active_power")
        end

        @testset "the dispatch mode at each stamp is the previous interval's DISPATCHMODE" begin
            # PUMP1 is in modes 0, 1, 2, 3 at 00:05, 00:10, 00:15, 00:20; the grid is 00:10 to 00:20.
            modes = Dict(
                DateTime(2025, 1, 1, 0, 5) => 0, DateTime(2025, 1, 1, 0, 10) => 1,
                DateTime(2025, 1, 1, 0, 15) => 2, DateTime(2025, 1, 1, 0, 20) => 3,
            )
            function set_modes!(frame)
                for i in eachindex(frame.DUID)
                    frame.DUID[i] == "PUMP1" && haskey(modes, frame.SETTLEMENTDATE[i]) || continue
                    frame.DISPATCHMODE[i] = modes[frame.SETTLEMENTDATE[i]]
                end
                return
            end
            bad = corrupt_cache(:DISPATCHLOAD, set_modes!)
            window = DateTime(2025, 1, 1, 0, 10):resolution:DateTime(2025, 1, 1, 0, 25)
            sys = deepcopy(sys_base)
            set_unit_conditions!(sys, bad, window)
            pump = get_component(InterruptiblePowerLoad, sys, "PUMP1")
            @test unit_values(pump, get_observed_state(pump).dispatch_mode) == [0.0, 1.0, 2.0]
            # The other observed series still read the row at each stamp.
            pump_rows = sort(subset(truth, :DUID => ByRow(==("PUMP1"))), :SETTLEMENTDATE)
            @test unit_values(pump, get_observed_state(pump).initial_mw) == pump_rows.INITIALMW[3:5]
        end

        @testset "a non-scheduled load is pinned to zero whatever DISPATCHLOAD meters" begin
            sys = deepcopy(sys_base)
            set_market_bids!(sys, db, date_range)
            @test all(>(0.0), subset(truth, :DUID => ByRow(==("ASLOAD1"))).INITIALMW)
            set_unit_conditions!(sys, db, date_range)
            asload = get_component(InterruptiblePowerLoad, sys, "ASLOAD1")
            @test get_available(asload)
            @test all(==(0.0), unit_values(asload, get_observed_state(asload).initial_mw))
            # The metered ramp rates stay as published, for AGC ramping; AEMSim zeroes the ramp limits.
            @test unit_values(asload, get_telemetry(asload).ramp_up_limit) ≈ subset(truth, :DUID => ByRow(==("ASLOAD1"))).RAMPUPRATE
            @test !is_semi_scheduled(asload)
        end

        @testset "a semi-scheduled unit gets its UIGF, a scheduled unit none" begin
            semi_range = DateTime(2025, 1, 1):Minute(5):DateTime(2025, 1, 1, 0, 10)
            sys = first(nem_network(db; date_range = MOCK_DATE_RANGE))
            set_market_bids!(sys, db, semi_range)
            set_unit_conditions!(sys, db, semi_range)
            for (duid, forecast) in [("BW03", [40.0, 41.0]), ("BW04", [70.0, 69.0])]
                gen = get_component(RenewableDispatch, sys, duid)
                @test is_semi_scheduled(gen)
                @test unit_values(gen, get_telemetry(gen).uigf) ≈ forecast
            end
            coal = get_component(ThermalStandard, sys, "ER01")
            @test !is_semi_scheduled(coal)
            @test isnothing(get_telemetry(coal).uigf)
        end

        @testset "a repeat call replaces the series with the same values" begin
            sys = deepcopy(sys_base)
            set_unit_conditions!(sys, db, date_range)
            pump = get_component(InterruptiblePowerLoad, sys, "PUMP1")
            before = unit_values(pump, get_observed_state(pump).initial_mw)
            set_unit_conditions!(sys, db, date_range)
            @test unit_values(pump, get_observed_state(pump).initial_mw) == before
        end

        # Copies the cache, rewrites `table` with `transform!`, and checks that `sys` got no condition.
        # The exception `corrupt_and_build` last threw, so tests can match its message.
        last_error = Ref{Any}(nothing)
        function corrupt_and_build(table, transform!; sys = deepcopy(sys_base))
            bad = corrupt_cache(table, transform!)
            try
                set_unit_conditions!(sys, bad, check_range)
            catch e
                last_error[] = e
                rethrow()
            finally
                close(bad.db)
            end
            return sys
        end
        untouched(sys) = !any(has_time_series(d, SingleTimeSeries, AustralianElectricityMarkets.NEM_OBSERVED_SERIES.initial_mw) for d in get_components(Device, sys))
        check_range = DateTime(2025, 1, 1, 0, 0):Minute(5):DateTime(2025, 1, 1, 0, 10)
        at(t) = DateTime(2025, 1, 1, 0, t)
        # `registration` with the registration span [from, until].
        with_span(registration, from, until) = NEMRegistration(;
            schedule_type = registration.schedule_type, gen_loss_factor = registration.gen_loss_factor,
            load_loss_factor = registration.load_loss_factor, registered_from = from, registered_until = until,
        )
        dispatch_rows(frame) = frame.DUID .== "ER01"

        # Sets `column` to `value` on `duid`'s row at 00:05.
        set_at(column, duid, value) = frame -> (frame[!, column] = Union{Float64, Missing}[r.DUID == duid && r.SETTLEMENTDATE == at(5) ? value : r[column] for r in eachrow(frame)])
        @testset "a corrupt DISPATCHLOAD throws ($message) and leaves sys untouched" for (transform!, message) in (
                set_at(:RAMPUPRATE, "ER01", missing) => "ER01: missing INITIALMW/RAMPUPRATE/RAMPDOWNRATE/AVAILABILITY at $(at(5))",
                set_at(:AVAILABILITY, "ER01", -1.0) => "ER01: negative AVAILABILITY",
                (frame -> filter!(r -> r.DUID != "ER01", frame)) => "ER01: no DISPATCHLOAD rows",
                set_at(:UIGF, "BW03", -1.0) => "BW03 at $(at(5)): missing or invalid UIGF",
            )
            sys = deepcopy(sys_base)
            @test_throws ArgumentError corrupt_and_build(:DISPATCHLOAD, transform!; sys)
            @test occursin(message, last_error[].msg)
            @test untouched(sys)
        end

        @testset "a DISPATCHLOAD without a UIGF column fails the query and leaves sys untouched" begin
            sys = deepcopy(sys_base)
            @test_throws DuckDB.QueryException corrupt_and_build(:DISPATCHLOAD, frame -> select!(frame, Not(:UIGF)); sys)
            @test untouched(sys)
        end

        @testset "zero AVAILABILITY and zero ramp rates are carried through, not rejected" begin
            sys = corrupt_and_build(:DISPATCHLOAD, frame -> (set_at(:AVAILABILITY, "ER01", 0.0)(frame); set_at(:RAMPUPRATE, "ER01", 0.0)(frame)))
            er01 = get_component(ThermalStandard, sys, "ER01")
            @test unit_values(er01, get_telemetry(er01).ramp_up_limit)[2] == 0.0
        end

        @testset "a missing row inside a unit's registration throws, and one outside it does not" begin
            sys = deepcopy(sys_base)
            er01 = get_component(ThermalStandard, sys, "ER01")
            set_registration!(er01, with_span(get_registration(er01), at(0), at(10)))
            @test_throws ArgumentError corrupt_and_build(
                :DISPATCHLOAD, frame -> filter!(r -> !(r.DUID == "ER01" && r.SETTLEMENTDATE == at(5)), frame); sys,
            )
            @test occursin("ER01: missing DISPATCHLOAD row(s) for 1 of 2 interval(s)", last_error[].msg)
            @test untouched(sys)

            sys = deepcopy(sys_base)
            er01 = get_component(ThermalStandard, sys, "ER01")
            set_registration!(er01, with_span(get_registration(er01), at(5), at(10)))
            sys = corrupt_and_build(:DISPATCHLOAD, frame -> filter!(r -> !(r.DUID == "ER01" && r.SETTLEMENTDATE == at(0)), frame); sys)
            # Unregistered at 00:00 with no row: the ramp rates there are NaN, the limits zero.
            er01 = get_component(ThermalStandard, sys, "ER01")
            @test isnan(unit_values(er01, get_telemetry(er01).ramp_up_limit)[1])
            @test unit_values(er01, get_observed_state(er01).initial_mw)[1] == 0.0
        end

        @testset "a schedule type changing mid-range throws at build, naming the DUID" begin
            bad = corrupt_cache(
                :DUDETAILSUMMARY, frame -> begin
                    i = findfirst(==("ER01"), frame.DUID)
                    extra = frame[[i], :]
                    frame.END_DATE[i] = at(0)
                    extra.START_DATE .= at(0)
                    extra.SCHEDULE_TYPE .= "SEMI-SCHEDULED"
                    append!(frame, extra)
                end
            )
            @test_throws r"ER01 change REGIONID/DISPATCHTYPE/SCHEDULE_TYPE" nem_network(bad; date_range = at(0):Minute(5):at(10))
        end

        @testset "a zero static max_active_power throws, naming the DUID" begin
            sys = deepcopy(sys_base)
            set_active_power_limits!(get_component(ThermalStandard, sys, "ER01"), (min = 0.0, max = 0.0))
            @test_throws ArgumentError corrupt_and_build(:DISPATCHLOAD, identity; sys)
            @test occursin("ER01: static max_active_power is 0.0", last_error[].msg)
            @test untouched(sys)
        end

        @testset "a negative UIGF on a semi-scheduled unit throws, naming the DUID" begin
            sys = deepcopy(sys_base)
            @test_throws ArgumentError corrupt_and_build(
                :DISPATCHLOAD, frame -> begin
                    frame.UIGF = Union{Float64, Missing}[r.DUID == "BW03" && r.SETTLEMENTDATE == at(5) ? -1.0 : r.UIGF for r in eachrow(frame)]
                end; sys
            )
            @test occursin("BW03 at $(at(5)): missing or invalid UIGF", last_error[].msg)
            @test untouched(sys)
        end

        @testset "an unavailable unit is excluded from the strict checks" begin
            sys = deepcopy(sys_base)
            set_available!(get_component(ThermalStandard, sys, "ER02"), false)
            set_unit_conditions!(sys, corrupt_cache(:DISPATCHLOAD, frame -> filter!(r -> r.DUID != "ER02", frame)), check_range)
            @test isnothing(AustralianElectricityMarkets._nem_unit_data(get_component(ThermalStandard, sys, "ER02")).observed_state)
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
            old.DISPATCHTYPE = [d == "BW01" ? "BIDIRECTIONAL" : t == "LOAD" ? "LOAD" : "GENERATOR" for (d, t) in zip(old.DUID, old.DISPATCHTYPE)]
            old.TRANSMISSIONLOSSFACTOR = [d == "ER01" ? 0.9 : d in ("BW01", "PUMP1") ? 0.8 : 1.0 for d in old.DUID]
            old.DISTRIBUTIONLOSSFACTOR = [d == "ER01" ? 0.97 : 1.0 for d in old.DUID]
            old.SECONDARY_TLF = Union{Float64, Missing}[d == "BW01" ? 0.5 : d == "BW02" ? 0.7 : missing for d in old.DUID]
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
            old = read_loss_factors(ldb, mock_range_at(start_date))
            @test factor(old, "ER01", :LOAD_LOSS_FACTOR) ≈ 0.9 * 0.97   # DLF is applied
            @test factor(old, "ER01", :GEN_LOSS_FACTOR) ≈ 0.9 * 0.97
            @test factor(old, "BW01", :GEN_LOSS_FACTOR) == 0.5            # BIDIRECTIONAL: secondary on GEN
            @test factor(old, "BW01", :LOAD_LOSS_FACTOR) == 0.8
            @test factor(old, "BW02", :GEN_LOSS_FACTOR) == 1.0            # SECONDARY_TLF ignored off a BDU
            new = read_loss_factors(ldb, mock_range_at(DateTime(2025, 7, 2)))
            @test factor(new, "ER01", :LOAD_LOSS_FACTOR) == 0.8
            @test factor(new, "BW01", :GEN_LOSS_FACTOR) == 1.0
            # The new row starts at the boundary, so the interval ending at it still takes the old row.
            @test factor(read_loss_factors(ldb, mock_range_at(fy_change)), "ER01", :LOAD_LOSS_FACTOR) ≈ 0.9 * 0.97
            @test factor(read_loss_factors(ldb, mock_range_at(fy_change + Minute(5))), "ER01", :LOAD_LOSS_FACTOR) == 0.8
            @test_logs (:warn, r"change within the date range") match_mode = :any read_loss_factors(ldb, start_date:Minute(5):(DateTime(2025, 7, 1, 1) + Minute(5)))
        end

        sys_lf, _ = nem_network(ldb; date_range)
        set_market_bids!(sys_lf, ldb, date_range; resolution = Minute(5))

        # Read raw bids (unscaled by loss factors) to compare
        raw_bids = read_bids(ldb, date_range; resolution = Minute(5))
        raw_curve(duid, direction) = AustralianElectricityMarkets._extract_power_bids(first(eachrow(raw_bids[(raw_bids.DUID .== duid) .& (raw_bids.DIRECTION .== direction), :])))
        raw_price(duid, direction) = get_y_coords(raw_curve(duid, direction))
        raw_mw(duid, direction) = get_x_coords(raw_curve(duid, direction))

        prices(sys, name, direction = "GEN") = with_units_base(sys, "NATURAL_UNITS") do
            ta = get_time_series_array(SingleTimeSeries, get_component(Device, sys, name), AustralianElectricityMarkets.bid_series_name(AustralianElectricityMarkets.BidType.ENERGY, :offer_curves, AustralianElectricityMarkets.BidDirection(direction)))
            return get_y_coords(first(values(ta)))
        end
        mw(sys, name) = with_units_base(sys, "NATURAL_UNITS") do
            ta = get_time_series_array(SingleTimeSeries, get_component(Device, sys, name), AustralianElectricityMarkets.bid_series_name(AustralianElectricityMarkets.BidType.ENERGY, :offer_curves, AustralianElectricityMarkets.BidDirection.GEN))
            return get_x_coords(first(values(ta)))
        end

        @testset "bid prices are as offered, MW is not divided" begin
            @test prices(sys_lf, "ER01") ≈ raw_price("ER01", "GEN")
            @test prices(sys_lf, "BW02") ≈ raw_price("BW02", "GEN")
            @test prices(sys_lf, "BW01") ≈ raw_price("BW01", "GEN")
            @test prices(sys_lf, "BW01", "LOAD") ≈ raw_price("BW01", "LOAD")
            @test mw(sys_lf, "ER01") ≈ raw_mw("ER01", "GEN")
        end

        @testset "loss factors are kept on the registration for AEMSim to refer prices" begin
            @test get_registration(get_component(ThermalStandard, sys_lf, "ER01")).gen_loss_factor ≈ 0.9 * 0.97
            @test get_registration(get_component(EnergyReservoirStorage, sys_lf, "BW01")).gen_loss_factor ≈ 0.5
            @test get_registration(get_component(EnergyReservoirStorage, sys_lf, "BW01")).load_loss_factor ≈ 0.8
        end

        @testset "a scheduled load's decremental bid is as offered" begin
            @test get_available(get_component(InterruptiblePowerLoad, sys_lf, "PUMP1"))
            @test prices(sys_lf, "PUMP1", "LOAD") ≈ raw_price("PUMP1", "LOAD")
            @test get_registration(get_component(InterruptiblePowerLoad, sys_lf, "PUMP1")).load_loss_factor ≈ 0.8
        end

        @testset "a unit with no loss factor throws at build, naming it" begin
            unfactored = loss_factor_db(
                df -> begin
                    df = two_years(df)
                    df.TRANSMISSIONLOSSFACTOR = Union{Float64, Missing}[d == "BW02" ? missing : x for (d, x) in zip(df.DUID, df.TRANSMISSIONLOSSFACTOR)]
                    df
                end
            )
            @test_throws r"No DUDETAILSUMMARY loss factor for BW02" nem_network(unfactored; date_range)
        end
    end
end

@testset "Regional availability setter" begin
    using DataFrames, Statistics
    import TimeSeries
    db = aem_connect(HiveConfiguration(hive_location = AEM_TEST_HIVE_DIR, filesystem = "file"))
    sys_base = nem_system(db, RegionalNetworkConfiguration(); date_range = MOCK_DATE_RANGE)
    resolution = Minute(30)
    start_date = DateTime(2025, 1, 1, 0, 0)
    date_range = start_date:Minute(5):(start_date + Hour(2))
    stamps = collect(start_date:resolution:(start_date + Hour(2) - resolution))

    # Raw 5-minute intervals (index i from start_date) that round up to the stamp t. The DISPATCHLOAD
    # fixture also has the prior row at i = -1 (23:55), which falls in the first bucket, stamped 00:00.
    raw_indices(t, range = 0:48) = [i for i in range if ceil(start_date + Minute(5 * i), resolution) == t]
    # Fixture: BW03 UIGF is 40 + i (its AVAILABILITY is also present, so UIGF must win); BW02
    # AVAILABILITY is 87 + i % 6; regional SS_SOLAR_UIGF is 120 + i in every region, and its
    # SS_SOLAR_AVAILABILITY is 100 + i, which must not be read.
    function regional_system()
        sys = deepcopy(sys_base)
        bw03 = get_component(RenewableDispatch, sys, "BW03")
        # BW03 is QLD1's only solar unit with UIGF, so its 400 MW keeps 100 + i below the denominator.
        with_units_base(() -> set_rating!(bw03, 400.0), sys, "NATURAL_UNITS")
        # A solar unit with no DISPATCHLOAD rows, in BW03's region and on its bus.
        add_component!(
            sys, RenewableDispatch(;
                name = "PVX1", available = true, bus = get_bus(bw03), active_power = 0.0,
                reactive_power = 0.0, rating = get_rating(bw03), prime_mover_type = PrimeMovers.PVe,
                reactive_power_limits = nothing, power_factor = 1.0,
                operation_cost = RenewableGenerationCost(nothing), base_power = get_base_power(bw03),
            ),
        )
        return sys
    end
    natural_values(sys, device) = with_units_base(
        () -> get_time_series_values(SingleTimeSeries, device, "max_active_power"), sys, "NATURAL_UNITS",
    )

    @testset "attaches each priority source in MW of the unit" begin
        sys = regional_system()
        set_regional_availability!(sys, db, date_range; resolution)
        bw02 = get_component(HydroDispatch, sys, "BW02")
        bw03 = get_component(RenewableDispatch, sys, "BW03")
        pvx = get_component(RenewableDispatch, sys, "PVX1")
        @test with_units_base(() -> get_max_active_power(bw03), sys, "NATURAL_UNITS") ≈ 400.0
        pvx_capacity = with_units_base(() -> get_max_active_power(pvx), sys, "NATURAL_UNITS")

        # Scheduled hydro: AVAILABILITY, the minimum over each bucket.
        @test natural_values(sys, bw02) ≈ [minimum(87 + i % 6 for i in raw_indices(t, -1:48)) for t in stamps]
        # Semi-scheduled solar: UIGF, the mean over each bucket, not AVAILABILITY.
        @test natural_values(sys, bw03) ≈ [mean(40 + i for i in raw_indices(t, -1:48)) for t in stamps]
        # No dispatch rows: the regional 120 + i UIGF over the 400 MW of QLD1 solar UIGF capacity.
        expected_factor = [clamp(mean(120 + i for i in raw_indices(t)) / 400.0, 0.0, 1.0) for t in stamps]
        @test natural_values(sys, pvx) ≈ expected_factor .* pvx_capacity
        @test all(0.0 .< expected_factor .< 1.0)
    end

    @testset "a repeat call replaces the series with the same values" begin
        sys = regional_system()
        set_regional_availability!(sys, db, date_range; resolution)
        bw03 = get_component(RenewableDispatch, sys, "BW03")
        before = natural_values(sys, bw03)
        set_regional_availability!(sys, db, date_range; resolution)
        series = [ts for ts in get_time_series_multiple(bw03) if get_name(ts) == "max_active_power"]
        @test length(series) == 1
        @test natural_values(sys, bw03) ≈ before
    end

    @testset "the series covers exactly the stamps" begin
        sys = regional_system()
        set_regional_availability!(sys, db, date_range; resolution)
        for name in ("BW02", "BW03", "PVX1")
            device = get_component(name == "BW02" ? HydroDispatch : RenewableDispatch, sys, name)
            ta = get_time_series_array(SingleTimeSeries, device, "max_active_power")
            @test TimeSeries.timestamp(ta) == stamps
        end
        # A Date range is read by its first and last days, half-hourly across the first day.
        sys_days = regional_system()
        set_regional_availability!(sys_days, db, Date(2025, 1, 1):Date(2025, 1, 2); resolution)
        ta = get_time_series_array(SingleTimeSeries, get_component(RenewableDispatch, sys_days, "BW03"), "max_active_power")
        @test TimeSeries.timestamp(ta) == collect(DateTime(2025, 1, 1):resolution:DateTime(2025, 1, 1, 23, 30))
    end

    @testset "unavailable units are skipped" begin
        sys = regional_system()
        bw02 = get_component(HydroDispatch, sys, "BW02")
        set_available!(bw02, false)
        set_regional_availability!(sys, db, date_range; resolution)
        @test !has_time_series(bw02, SingleTimeSeries, "max_active_power")
        @test has_time_series(get_component(RenewableDispatch, sys, "BW03"), SingleTimeSeries, "max_active_power")
    end

    @testset "the denominator counts unavailable units" begin
        sys = regional_system()
        set_available!(get_component(RenewableDispatch, sys, "BW03"), false)
        set_regional_availability!(sys, db, date_range; resolution)
        pvx = get_component(RenewableDispatch, sys, "PVX1")
        pvx_capacity = with_units_base(() -> get_max_active_power(pvx), sys, "NATURAL_UNITS")
        expected_factor = [clamp(mean(120 + i for i in raw_indices(t)) / 400.0, 0.0, 1.0) for t in stamps]
        @test natural_values(sys, pvx) ≈ expected_factor .* pvx_capacity
    end

    @testset "a start off the resolution grid throws" begin
        sys = regional_system()
        misaligned = start_date + Minute(7)
        @test_throws ArgumentError set_regional_availability!(
            sys, db, misaligned:Minute(5):(misaligned + Hour(1)); resolution,
        )
    end

    @testset "a device with zero capacity is zero at every stamp" begin
        sys = regional_system()
        bw03 = get_component(RenewableDispatch, sys, "BW03")
        add_component!(
            sys, RenewableDispatch(;
                name = "PVZ1", available = true, bus = get_bus(bw03), active_power = 0.0,
                reactive_power = 0.0, rating = 0.0, prime_mover_type = PrimeMovers.PVe,
                reactive_power_limits = nothing, power_factor = 1.0,
                operation_cost = RenewableGenerationCost(nothing), base_power = get_base_power(bw03),
            ),
        )
        set_regional_availability!(sys, db, date_range; resolution)
        @test natural_values(sys, get_component(RenewableDispatch, sys, "PVZ1")) ≈ zeros(length(stamps))
    end
end
