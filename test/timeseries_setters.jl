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
    sys_base, _ = nem_network(db)

    # Writes a DISPATCHLOAD hive whose row (interval i of grid, duid) takes the values `cell(duid, i)`.
    function dispatchload_db(cell, grid, duids)
        rows = DataFrame(
            SETTLEMENTDATE = DateTime[], DUID = String[], INTERVENTION = Int[],
            INITIALMW = Union{Float64, Missing}[], RAMPUPRATE = Union{Float64, Missing}[],
            RAMPDOWNRATE = Union{Float64, Missing}[], AVAILABILITY = Union{Float64, Missing}[],
        )
        for (i, t) in enumerate(grid), duid in duids
            push!(rows, (; SETTLEMENTDATE = t, DUID = duid, INTERVENTION = 0, cell(duid, i)...))
        end
        rows[!, :archive_month] = fill("2025-01", nrow(rows))
        hive = mktempdir()
        conn = DuckDB.connect(DuckDB.DB())
        DuckDB.execute(conn, "SET preserve_identifier_case=true")
        DuckDB.register_data_frame(conn, rows, "tmp_table")
        table_dir = joinpath(hive, "DISPATCHLOAD")
        mkpath(table_dir)
        DuckDB.execute(conn, "COPY (SELECT * FROM tmp_table) TO '$table_dir' (FORMAT 'PARQUET', PARTITION_BY (archive_month))")
        DuckDB.unregister_table(conn, "tmp_table")
        return aem_connect(HiveConfiguration(hive_location = hive, filesystem = "file"))
    end

    @testset "demand build rejects incomplete regional demand" begin
        # The mock hive holds demand to 04:00; a window running to 06:00 has no rows for the last two hours.
        start_date = DateTime(2025, 1, 1, 3, 0)
        late_range = start_date:Minute(5):(start_date + Hour(3))
        err = try
            attach_demand!(deepcopy(sys_base), db, late_range; resolution = Minute(5))
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
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

            @testset "demand build" begin
                attach_demand!(sys, db, date_range; resolution = resolution)
                for load in get_components(PowerLoad, sys)
                    ta = get_time_series_array(SingleTimeSeries, load, "max_active_power")
                    # subset! logic in setters/timeseries.jl: first(date_range) <= x < last(date_range)
                    @test length(ta) == length(date_range) - 1
                    if length(ta) > 1
                        @test TimeSeries.timestamp(ta)[2] - TimeSeries.timestamp(ta)[1] == resolution
                    end
                end
            end

            @testset "set_market_bids!" begin
                # PUMP2 has no bid and WDR1 bids GEN: unavailable, one aggregated warning each.
                @test_logs (:warn, r"WDR1") (:warn, r"PUMP2") match_mode = :any set_market_bids!(
                    sys, db, date_range; resolution = resolution,
                )
                for gen in get_components(NEMThermalGen, sys)
                    # set_market_bids! creates one value per bid interval of date_range.
                    ta = get_time_series_array(SingleTimeSeries, gen, "bid_energy_offer_curves_gen")
                    @test length(ta) == length(date_range) - 1
                end

                @testset "Scheduled loads" begin
                    @test !get_available(get_component(NEMLoad, sys, "PUMP2"))
                    @test !get_available(get_component(NEMLoad, sys, "WDR1"))
                    pump = get_component(NEMLoad, sys, "PUMP1")
                    @test get_available(pump)
                    ta = get_time_series_array(SingleTimeSeries, pump, "bid_energy_offer_curves_load")
                    @test length(ta) == length(date_range) - 1
                    # A load has no incremental bid
                    @test !has_time_series(pump, SingleTimeSeries, "bid_energy_offer_curves_gen")
                end

                @testset "Batteries" begin
                    for bat in get_components(NEMStorage, sys)
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
                        @test length(avail.gen) == horizon
                        @test avail.gen ≈ avail.load
                        @test all(x -> 100.0 <= x <= 149.0, avail.gen)
                        @test avail.gen[end] > avail.gen[1]
                    end
                    @test !has_time_series(first(get_components(NEMThermalGen, sys)), SingleTimeSeries, "bid_energy_max_avail_load")
                    @test !has_time_series(first(get_components(PowerLoad, sys)), SingleTimeSeries, "bid_energy_offer_curves_gen")
                end
            end
        end
    end

    @testset "set_market_bids! records each direction's bid on the NEMOfferCost" begin
        sys = deepcopy(sys_base)
        start_date = DateTime(2025, 1, 1, 0, 0)
        date_range = start_date:Minute(5):(start_date + Hour(1))
        set_market_bids!(sys, db, date_range)
        gen = first(get_components(NEMThermalGen, sys))
        storage = first(get_components(NEMStorage, sys))
        for (device, direction) in ((gen, AustralianElectricityMarkets.BidDirection.GEN), (storage, AustralianElectricityMarkets.BidDirection.GEN), (storage, AustralianElectricityMarkets.BidDirection.LOAD))
            bid = only(b for b in AustralianElectricityMarkets.get_energy_bids(get_operation_cost(device)) if b.direction == direction)
            @test bid.offer_curves.name == AustralianElectricityMarkets.bid_series_name(AustralianElectricityMarkets.BidType.ENERGY, :offer_curves, direction)
            @test bid.max_avail.name == AustralianElectricityMarkets.bid_series_name(AustralianElectricityMarkets.BidType.ENERGY, :max_avail, direction)
            @test get_time_series_timestamps(SingleTimeSeries, device, bid.offer_curves.name)[1] == date_range[1]
        end
        @test !any(has_time_series(gen, SingleTimeSeries, n) for n in ("variable_cost", "incremental_initial_input"))
    end

    @testset "set_market_bids! twice keeps one NEMEnergyBid per direction" begin
        sys = deepcopy(sys_base)
        start_date = DateTime(2025, 1, 1, 0, 0)
        first_range = start_date:Minute(5):(start_date + Hour(1))
        second_range = (start_date + Minute(30)):Minute(5):(start_date + Minute(90))
        set_market_bids!(sys, db, first_range)
        set_market_bids!(sys, db, second_range)
        for device in vcat(collect(get_components(NEMThermalGen, sys)), collect(get_components(NEMStorage, sys)))
            get_available(device) || continue
            bids = AustralianElectricityMarkets.get_energy_bids(get_operation_cost(device))
            directions = [b.direction for b in bids]
            @test allunique(directions)
            @test !isempty(directions)
            for direction in directions
                name = AustralianElectricityMarkets.bid_series_name(AustralianElectricityMarkets.BidType.ENERGY, :offer_curves, direction)
                # The second call's window replaced the first's series.
                @test get_time_series_timestamps(SingleTimeSeries, device, name)[1] == second_range[1]
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

        attach_demand!(sys, db, date_range; resolution = resolution)

        demand_df = read_demand(db; resolution = resolution)
        subset!(demand_df, :SETTLEMENTDATE => ByRow(x -> first(date_range) <= x < last(date_range)))

        @testset "demand build matches true TOTALDEMAND and LOSSDEMAND (NATURAL_UNITS)" begin
            for load in get_components(PowerLoad, sys)
                region_id = replace(get_name(load), " Load" => "")
                region_demand = @chain demand_df begin
                    subset(:REGIONID => ByRow(==(region_id)))
                    sort(:SETTLEMENTDATE)
                end
                isempty(region_demand) && continue
                reconstructed = get_time_series_values(SingleTimeSeries, load, "max_active_power")
                @test isapprox(reconstructed, region_demand.TOTALDEMAND; atol = 1.0e-6)
                reconstructed = get_time_series_values(SingleTimeSeries, load, "loss_demand")
                @test isapprox(reconstructed, region_demand.LOSSDEMAND; atol = 1.0e-6)
                @test !isapprox(reconstructed, region_demand.TOTALDEMAND; atol = 1.0e-6)
            end
        end

    end

    @testset "read_uigf" begin
        resolution = Minute(5)
        start_date = DateTime(2025, 1, 1, 0, 0)
        date_range = start_date:resolution:(start_date + Hour(2))

        uigf = read_uigf(db, date_range; resolution = resolution)

        @testset "read_uigf returns only semi-scheduled units" begin
            @test !isempty(uigf)
            @test Set(names(uigf)) == Set(["SETTLEMENTDATE", "DUID", "UIGF"])
            # BW03 (Solar) and BW04 (Wind) are the fixture's only semi-scheduled DUIDs.
            @test Set(unique(uigf.DUID)) == Set(["BW03", "BW04"])
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
        for b in eachrow(got)
            window = sort(
                subset(rows, :SETTLEMENTDATE => ByRow(x -> b.SETTLEMENTDATE - Minute(30) < x <= b.SETTLEMENTDATE)),
                :SETTLEMENTDATE,
            )
            @test length(window.SETTLEMENTDATE) == 6
            @test b.INITIALMW == first(window.INITIALMW)
            @test b.RAMPUPRATE == minimum(window.RAMPUPRATE)
            @test b.RAMPDOWNRATE == minimum(window.RAMPDOWNRATE)
            @test b.AVAILABILITY == minimum(window.AVAILABILITY)
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

        @testset "attaches the operating condition of a scheduled load, per-unitised" begin
            sys = deepcopy(sys_base)
            set_unit_conditions!(sys, db, date_range)
            pump = get_component(NEMLoad, sys, "PUMP1")
            rows = sort(subset(truth, :DUID => ByRow(==("PUMP1"))), :SETTLEMENTDATE)
            values(name) = get_time_series_values(SingleTimeSeries, pump, name)
            @test isapprox(values("initial_mw"), rows.INITIALMW ./ base_power; atol = 1.0e-8)
            @test isapprox(values("availability"), rows.AVAILABILITY ./ base_power; atol = 1.0e-8)
            @test values("dispatch_ramp_up_rate") == rows.RAMPUPRATE ./ 60 ./ base_power
            @test values("dispatch_ramp_down_rate") == rows.RAMPDOWNRATE ./ 60 ./ base_power
            @test values(AustralianElectricityMarkets.NEM_SERIES.dispatch_mode) == rows.DISPATCHMODE
            @test values(fcas_name("fcas_regulation_availability", RAISE)) ≈ rows.RAISEREGAVAILABILITY ./ base_power
            @test values(fcas_name("fcas_agc_enablement_min", LOWER)) ≈ rows.LOWERREGENABLEMENTMIN ./ base_power
            @test values(fcas_name("fcas_agc_enablement_max", RAISE)) ≈ rows.RAISEREGENABLEMENTMAX ./ base_power
            # Ramps, the upper limit and AGC ramp rates are derived in AEMSim, not here.
            @test !has_time_series(pump, SingleTimeSeries, "ramp_up_rate")
            @test !has_time_series(pump, SingleTimeSeries, "max_active_power")
        end

        @testset "a non-scheduled load is pinned to zero whatever DISPATCHLOAD meters" begin
            sys = deepcopy(sys_base)
            set_market_bids!(sys, db, date_range)
            @test all(>(0.0), subset(truth, :DUID => ByRow(==("ASLOAD1"))).INITIALMW)
            set_unit_conditions!(sys, db, date_range)
            asload = get_component(NEMLoad, sys, "ASLOAD1")
            @test get_available(asload)
            for name in ("initial_mw", "availability")
                @test all(==(0.0), get_time_series_values(SingleTimeSeries, asload, name))
            end
            # The metered ramp rates stay as published, for AGC ramping; AEMSim zeroes the ramp limits.
            @test get_time_series_values(SingleTimeSeries, asload, "dispatch_ramp_up_rate") ≈ subset(truth, :DUID => ByRow(==("ASLOAD1"))).RAMPUPRATE ./ 60 ./ base_power
            @test get_ext(asload)["nem_semi_scheduled"] === false
        end

        @testset "a battery gets dispatch ramps and initial_mw, with no availability" begin
            sys = deepcopy(sys_base)
            set_unit_conditions!(sys, db, date_range)
            battery = get_component(NEMStorage, sys, "BW01")
            @test has_time_series(battery, SingleTimeSeries, "initial_mw")
            @test has_time_series(battery, SingleTimeSeries, "dispatch_ramp_up_rate")
            @test !has_time_series(battery, SingleTimeSeries, "availability")
        end

        @testset "a semi-scheduled unit gets its UIGF, a scheduled unit none" begin
            semi_range = DateTime(2025, 1, 1):Minute(5):DateTime(2025, 1, 1, 0, 10)
            sys = first(nem_network(db))
            set_market_bids!(sys, db, semi_range)
            set_unit_conditions!(sys, db, semi_range)
            for (duid, forecast) in [("BW03", [40.0, 41.0]), ("BW04", [70.0, 69.0])]
                gen = get_component(NEMRenewableGen, sys, duid)
                @test get_ext(gen)["nem_semi_scheduled"] === true
                @test get_time_series_values(SingleTimeSeries, gen, "uigf"; ignore_scaling_factors = true) .* get_base_power(sys) ≈ forecast
            end
            coal = get_component(NEMThermalGen, sys, "ER01")
            @test get_ext(coal)["nem_semi_scheduled"] === false
            @test !has_time_series(coal, SingleTimeSeries, "uigf")
        end

        @testset "a repeat call replaces the series with the same values" begin
            sys = deepcopy(sys_base)
            set_unit_conditions!(sys, db, date_range)
            before = get_time_series_values(SingleTimeSeries, get_component(NEMLoad, sys, "PUMP1"), "initial_mw")
            set_unit_conditions!(sys, db, date_range)
            @test get_time_series_values(SingleTimeSeries, get_component(NEMLoad, sys, "PUMP1"), "initial_mw") == before
        end

        # Copies the cache, rewrites `table` with `transform!`, and checks that `sys` got no condition.
        # The exception `corrupt_and_build` last threw, so tests can match its message.
        last_error = Ref{Any}(nothing)
        function corrupt_and_build(table, transform!; registered = nothing, sys = deepcopy(sys_base))
            bad = corrupt_cache(table, transform!)
            try
                set_unit_conditions!(sys, bad, check_range; registered)
            catch e
                last_error[] = e
                rethrow()
            finally
                close(bad.db)
            end
            return sys
        end
        untouched(sys) = !any(has_time_series(d, SingleTimeSeries, AustralianElectricityMarkets.NEM_SERIES.initial_mw) for d in get_components(Device, sys))
        check_range = DateTime(2025, 1, 1, 0, 0):Minute(5):DateTime(2025, 1, 1, 0, 10)
        spans = registration_spans(read_units(db; as_of = first(check_range), through = last(check_range) - Minute(5)))
        at(t) = DateTime(2025, 1, 1, 0, t)
        dispatch_rows(frame) = frame.DUID .== "ER01"

        @testset "a missing RAMPUPRATE throws, naming the DUID, and leaves sys untouched" begin
            sys = deepcopy(sys_base)
            @test_throws ArgumentError corrupt_and_build(
                :DISPATCHLOAD, frame -> begin
                    frame.RAMPUPRATE = Union{Float64, Missing}[r.DUID == "ER01" && r.SETTLEMENTDATE == at(5) ? missing : r.RAMPUPRATE for r in eachrow(frame)]
                end; sys
            )
            @test occursin("ER01: missing INITIALMW/RAMPUPRATE/RAMPDOWNRATE/AVAILABILITY at $(at(5))", last_error[].msg)
            @test untouched(sys)
        end

        @testset "a negative AVAILABILITY throws, naming the DUID, and leaves sys untouched" begin
            sys = deepcopy(sys_base)
            @test_throws ArgumentError corrupt_and_build(
                :DISPATCHLOAD, frame -> begin
                    frame.AVAILABILITY = Union{Float64, Missing}[r.DUID == "ER01" && r.SETTLEMENTDATE == at(5) ? -1.0 : r.AVAILABILITY for r in eachrow(frame)]
                end; sys
            )
            @test occursin("ER01: negative AVAILABILITY", last_error[].msg)
            @test untouched(sys)
        end

        @testset "zero AVAILABILITY and zero ramp rates are carried through, not rejected" begin
            sys = corrupt_and_build(
                :DISPATCHLOAD, frame -> begin
                    frame.AVAILABILITY = Union{Float64, Missing}[r.DUID == "ER01" && r.SETTLEMENTDATE == at(5) ? 0.0 : r.AVAILABILITY for r in eachrow(frame)]
                    frame.RAMPUPRATE = Union{Float64, Missing}[r.DUID == "ER01" && r.SETTLEMENTDATE == at(5) ? 0.0 : r.RAMPUPRATE for r in eachrow(frame)]
                end
            )
            availability = get_time_series_values(SingleTimeSeries, get_component(NEMThermalGen, sys, "ER01"), "availability")
            @test availability[2] == 0.0
            @test get_time_series_values(SingleTimeSeries, get_component(NEMThermalGen, sys, "ER01"), "dispatch_ramp_up_rate")[2] == 0.0
        end

        @testset "a device with no DISPATCHLOAD rows throws, naming the DUID" begin
            sys = deepcopy(sys_base)
            @test_throws ArgumentError corrupt_and_build(:DISPATCHLOAD, frame -> filter!(r -> r.DUID != "ER01", frame); sys)
            @test occursin("ER01: no DISPATCHLOAD rows", last_error[].msg)
            @test untouched(sys)
        end

        @testset "a missing row inside a unit's registration throws, and one outside it does not" begin
            registered = copy(spans)
            registered["ER01"] = (at(0), at(10))
            sys = deepcopy(sys_base)
            @test_throws ArgumentError corrupt_and_build(
                :DISPATCHLOAD, frame -> filter!(r -> !(r.DUID == "ER01" && r.SETTLEMENTDATE == at(5)), frame); registered, sys,
            )
            @test occursin("ER01: missing DISPATCHLOAD row(s) for 1 of 2 interval(s)", last_error[].msg)
            @test untouched(sys)

            registered["ER01"] = (at(5), at(10))
            sys = corrupt_and_build(:DISPATCHLOAD, frame -> filter!(r -> !(r.DUID == "ER01" && r.SETTLEMENTDATE == at(0)), frame); registered)
            # Unregistered at 00:00 with no row: the ramp rates there are NaN, the limits zero.
            ramp = get_time_series_values(SingleTimeSeries, get_component(NEMThermalGen, sys, "ER01"), "dispatch_ramp_up_rate")
            @test isnan(ramp[1])
            @test get_time_series_values(SingleTimeSeries, get_component(NEMThermalGen, sys, "ER01"), "initial_mw")[1] == 0.0
        end

        @testset "a schedule type changing mid-range throws, naming the DUID" begin
            sys = deepcopy(sys_base)
            @test_throws ArgumentError corrupt_and_build(
                :DUDETAILSUMMARY, frame -> begin
                    i = findfirst(==("ER01"), frame.DUID)
                    extra = frame[[i], :]
                    frame.END_DATE[i] = at(0)
                    extra.START_DATE .= at(0)
                    extra.SCHEDULE_TYPE .= "SEMI-SCHEDULED"
                    append!(frame, extra)
                end; sys
            )
            @test occursin("ER01: schedule type changes or is missing in the requested range", last_error[].msg)
            @test untouched(sys)
        end

        @testset "a zero static max_active_power throws, naming the DUID" begin
            sys = deepcopy(sys_base)
            set_active_power_limits!(get_component(NEMThermalGen, sys, "ER01"), (min = 0.0, max = 0.0))
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

        @testset "a cached DISPATCHLOAD without a required column throws, leaving sys untouched" begin
            sys = deepcopy(sys_base)
            @test_throws ArgumentError corrupt_and_build(:DISPATCHLOAD, frame -> select!(frame, Not(:UIGF)); sys)
            @test untouched(sys)
        end

        @testset "an unavailable unit is excluded from the strict checks" begin
            sys = deepcopy(sys_base)
            set_available!(get_component(NEMThermalGen, sys, "ER02"), false)
            set_unit_conditions!(sys, corrupt_cache(:DISPATCHLOAD, frame -> filter!(r -> r.DUID != "ER02", frame)), check_range)
            @test !has_time_series(get_component(NEMThermalGen, sys, "ER02"), SingleTimeSeries, AustralianElectricityMarkets.NEM_SERIES.initial_mw)
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
            old.DISPATCHTYPE = [d == "BW01" ? "BIDIRECTIONAL" : "GENERATOR" for d in old.DUID]
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
            old = read_loss_factors(ldb; as_of = start_date)
            @test factor(old, "ER01", :LOAD_LOSS_FACTOR) ≈ 0.9 * 0.97   # DLF is applied
            @test factor(old, "ER01", :GEN_LOSS_FACTOR) ≈ 0.9 * 0.97
            @test factor(old, "BW01", :GEN_LOSS_FACTOR) == 0.5            # BIDIRECTIONAL: secondary on GEN
            @test factor(old, "BW01", :LOAD_LOSS_FACTOR) == 0.8
            @test factor(old, "BW02", :GEN_LOSS_FACTOR) == 1.0            # SECONDARY_TLF ignored off a BDU
            new = read_loss_factors(ldb; as_of = DateTime(2025, 7, 2))
            @test factor(new, "ER01", :LOAD_LOSS_FACTOR) == 0.8
            @test factor(new, "BW01", :GEN_LOSS_FACTOR) == 1.0
            # The new row starts at the boundary; a Date before it resolves the old one.
            @test factor(read_loss_factors(ldb; as_of = fy_change - Minute(5)), "ER01", :LOAD_LOSS_FACTOR) ≈ 0.9 * 0.97
            @test factor(read_loss_factors(ldb; as_of = fy_change), "ER01", :LOAD_LOSS_FACTOR) == 0.8
            # No as_of keeps the open row.
            @test factor(read_loss_factors(ldb), "ER01", :LOAD_LOSS_FACTOR) == 0.8
            @test_logs (:warn, r"change within the date range") match_mode = :any read_loss_factors(ldb; as_of = start_date, through = DateTime(2025, 7, 1, 1))
        end

        sys_lf = first(nem_network(ldb))
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

        @testset "loss factors are kept on the unit for AEMSim to refer prices" begin
            @test get_ext(get_component(NEMThermalGen, sys_lf, "ER01"))["nem_gen_loss_factor"] ≈ 0.9 * 0.97
            @test get_ext(get_component(NEMStorage, sys_lf, "BW01"))["nem_gen_loss_factor"] ≈ 0.5
            @test get_ext(get_component(NEMStorage, sys_lf, "BW01"))["nem_load_loss_factor"] ≈ 0.8
        end

        @testset "a scheduled load's decremental bid is as offered" begin
            @test get_available(get_component(NEMLoad, sys_lf, "PUMP1"))
            @test prices(sys_lf, "PUMP1", "LOAD") ≈ raw_price("PUMP1", "LOAD")
            @test get_ext(get_component(NEMLoad, sys_lf, "PUMP1"))["nem_load_loss_factor"] ≈ 0.8
        end

        @testset "a bidding unit without a DUDETAILSUMMARY row in force is an error" begin
            # BW02's only row starts after the range, so it has no factor at its start.
            partial = loss_factor_db(df -> subset(two_years(df), [:DUID, :START_DATE] => ByRow((d, t) -> !(d == "BW02" && t < fy_change))))
            sys_partial = first(nem_network(partial))
            @test_throws ArgumentError set_market_bids!(sys_partial, partial, date_range; resolution = Minute(5))
        end
    end
end

@testset "Regional availability setter" begin
    using DataFrames, Statistics
    import TimeSeries
    db = aem_connect(HiveConfiguration(hive_location = AEM_TEST_HIVE_DIR, filesystem = "file"))
    sys_base = nem_system(db, RegionalNetworkConfiguration())
    resolution = Minute(30)
    start_date = DateTime(2025, 1, 1, 0, 0)
    date_range = start_date:Minute(5):(start_date + Hour(2))
    stamps = collect(start_date:resolution:(start_date + Hour(2) - resolution))

    # Raw 5-minute intervals (index i from start_date) that round up to the stamp t.
    raw_indices(t) = [i for i in 0:48 if ceil(start_date + Minute(5 * i), resolution) == t]
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
        @test natural_values(sys, bw02) ≈ [minimum(87 + i % 6 for i in raw_indices(t)) for t in stamps]
        # Semi-scheduled solar: UIGF, the mean over each bucket, not AVAILABILITY.
        @test natural_values(sys, bw03) ≈ [mean(40 + i for i in raw_indices(t)) for t in stamps]
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
            @test length(ta) == length(stamps)
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
