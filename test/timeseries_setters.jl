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
                for gen in get_components(ThermalStandard, sys)
                    # Verify time series exists
                    ta = get_time_series_array(SingleTimeSeries, gen, "variable_cost")
                    # set_market_bids! creates one value per bid interval of date_range.
                    @test length(ta) == length(date_range) - 1
                end

                @testset "Scheduled loads" begin
                    @test !get_available(get_component(InterruptiblePowerLoad, sys, "PUMP2"))
                    @test !get_available(get_component(InterruptiblePowerLoad, sys, "WDR1"))
                    pump = get_component(InterruptiblePowerLoad, sys, "PUMP1")
                    @test get_available(pump)
                    ta = get_time_series_array(SingleTimeSeries, pump, "decremental_variable_cost")
                    @test length(ta) == length(date_range) - 1
                    @test !isempty(get_time_series_array(SingleTimeSeries, pump, "decremental_initial_input"))
                    # A load has no incremental offer
                    @test !has_time_series(pump, SingleTimeSeries, "variable_cost")
                end

                @testset "Batteries" begin
                    for bat in get_components(EnergyReservoirStorage, sys)
                        # GEN bids
                        ta_gen = get_time_series_array(SingleTimeSeries, bat, "variable_cost")
                        @test length(ta_gen) == length(date_range) - 1

                        # LOAD bids (decremental)
                        ta_load = get_time_series_array(SingleTimeSeries, bat, "decremental_variable_cost")
                        @test length(ta_load) == length(date_range) - 1

                        # The offer views read the same curves, one per side.
                        gen_offer, load_offer = get_energy_offer(bat, OfferSide.GEN), get_energy_offer(bat, OfferSide.LOAD)
                        @test gen_offer.side == OfferSide.GEN && load_offer.side == OfferSide.LOAD
                        @test gen_offer.timestamps == PowerSystems.TimeSeries.timestamp(ta_gen) && gen_offer.curves == values(ta_gen)
                        @test load_offer.curves == values(ta_load)

                        # Initial inputs
                        @test !isempty(get_time_series_array(SingleTimeSeries, bat, "incremental_initial_input"))
                        @test !isempty(get_time_series_array(SingleTimeSeries, bat, "decremental_initial_input"))

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
                    @test isnothing(get_energy_offer(first(get_components(PowerLoad, sys)), OfferSide.GEN))
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

    @testset "dispatch limits build" begin
        resolution = Minute(5)
        start_date = DateTime(2025, 1, 1, 0, 0)
        date_range = start_date:resolution:(start_date + Hour(2))
        base_power = get_base_power(sys_base)

        truth = read_dispatch_limits(db, date_range)

        @testset "attaches the full dispatch envelope to a scheduled load" begin
            sys = deepcopy(sys_base)
            attach_dispatch_limits!(sys, db, date_range)
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
            attach_dispatch_limits!(sys, db, date_range)
            asload = get_component(InterruptiblePowerLoad, sys, "ASLOAD1")
            @test get_available(asload)
            for name in ("ramp_up_rate", "ramp_down_rate", "initial_mw", "max_active_power", "availability")
                @test all(==(0.0), get_time_series_values(SingleTimeSeries, asload, name))
            end
        end

        @testset "aggregates DISPATCHLOAD onto a 30-minute step" begin
            # The mock DISPATCHLOAD starts at `start_date`, so the first bucket is 00:30: its window is complete.
            coarse = (start_date + Minute(30)):Minute(30):(start_date + Hour(2))
            fine = truth
            buckets = read_dispatch_limits(db, coarse; resolution = Minute(30))
            got = subset(buckets, :DUID => ByRow(==("PUMP1")))
            @test nrow(got) == length(coarse) - 1
            rows = subset(fine, :DUID => ByRow(==("PUMP1")))
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

        @testset "attaches ramp/initial series to a battery, with no max_active_power" begin
            sys = deepcopy(sys_base)
            attach_dispatch_limits!(sys, db, date_range)

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
            attach_dispatch_limits!(sys, db, date_range)

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
                got_mw = with_units_base(() -> get_time_series_values(SingleTimeSeries, device, "max_active_power"), sys, "NATURAL_UNITS")
                @test isapprox(got_mw, rows.AVAILABILITY; atol = 1.0e-6)
                n_checked += 1
            end
            @test n_checked == 5  # ER01, ER02, BW02, BW03, BW04
        end

        @testset "availability and initial_mw read back as raw AVAILABILITY/INITIALMW" begin
            sys = deepcopy(sys_base)
            attach_dispatch_limits!(sys, db, date_range)
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

        @testset "missing or negative dispatch inputs throw, naming the DUID, and leave sys untouched" begin
            short_range = start_date:resolution:(start_date + Minute(10))
            grid = collect(short_range)[1:(end - 1)]  # 3 intervals
            duids = ["BW02", "BW03", "BW04", "ER01", "ER02"]
            ok = (INITIALMW = 50.0, RAMPUPRATE = 5.0, RAMPDOWNRATE = 4.0, AVAILABILITY = 100.0)
            # Each case corrupts one field of ER01 at its second interval; `series` is what ER02 must keep.
            cases = (
                (label = "missing RAMPUPRATE", bad = (RAMPUPRATE = missing,), series = "ramp_up_rate"),
                (label = "missing AVAILABILITY", bad = (AVAILABILITY = missing,), series = "max_active_power"),
                (label = "negative AVAILABILITY", bad = (AVAILABILITY = -100.0,), series = "max_active_power"),
            )
            for case in cases
                @testset "$(case.label)" begin
                    bad_db = dispatchload_db(grid, duids) do duid, i
                        return duid == "ER01" && i == 2 ? merge(ok, case.bad) : ok
                    end
                    sys = deepcopy(sys_base)

                    err = try
                        attach_dispatch_limits!(sys, bad_db, short_range)
                        nothing
                    catch e
                        e
                    end
                    @test err isa ArgumentError
                    @test occursin("ER01", err.msg)
                    # Throwing leaves sys untouched, even for the devices with perfectly good data.
                    @test !has_time_series(get_component(ThermalStandard, sys, "ER02"), SingleTimeSeries, case.series)
                end
            end
        end

        @testset "zero AVAILABILITY and zero ramp rates are carried through, not rejected" begin
            # AEMO publishes AVAILABILITY = 0 for an unavailable unit (or a PV farm at night)
            # and RAMPUPRATE/RAMPDOWNRATE = 0 for a unit held at fixed output. Both are real
            # dispatch limits, so they must reach the System rather than drop the device.
            short_range = start_date:resolution:(start_date + Minute(10))
            grid = collect(short_range)[1:(end - 1)]  # 3 intervals
            duids = ["BW01", "BW02", "BW03", "BW04", "ER01", "ER02", "PUMP1", "PUMP2", "WDR1"]
            zero_db = dispatchload_db(grid, duids) do duid, _
                if duid == "ER01"  # offline
                    return (INITIALMW = 0.0, RAMPUPRATE = 5.0, RAMPDOWNRATE = 4.0, AVAILABILITY = 0.0)
                elseif duid == "ER02"  # available but cannot move
                    return (INITIALMW = 50.0, RAMPUPRATE = 0.0, RAMPDOWNRATE = 0.0, AVAILABILITY = 100.0)
                end
                return (INITIALMW = 50.0, RAMPUPRATE = 5.0, RAMPDOWNRATE = 4.0, AVAILABILITY = 100.0)
            end
            sys = deepcopy(sys_base)

            @test_nowarn attach_dispatch_limits!(sys, zero_db, short_range)

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

        @testset "zero static max_active_power throws, naming the DUID" begin
            sys = deepcopy(sys_base)
            thermal = get_component(ThermalStandard, sys, "ER01")
            with_units_base(sys, "NATURAL_UNITS") do
                set_active_power_limits!(thermal, (min = 0.0, max = 0.0))
                return
            end

            err = try
                attach_dispatch_limits!(sys, db, date_range)
                nothing
            catch e
                e
            end
            @test err isa ArgumentError
            @test occursin("ER01", err.msg)
            @test !has_time_series(get_component(HydroDispatch, sys, "BW02"), SingleTimeSeries, "max_active_power")
            @test !has_time_series(thermal, SingleTimeSeries, "max_active_power")
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
                @test isapprox(got_raise_rate, max.(rows.RAMPUPRATE, rows.RAISEREGAVAILABILITY .* 12) ./ base_power; atol = 1.0e-9)
                @test isapprox(got_lower_rate, max.(rows.RAMPDOWNRATE, rows.LOWERREGAVAILABILITY .* 12) ./ base_power; atol = 1.0e-9)
                @test isapprox(got_agc_status, rows.AGCSTATUS; atol = 1.0e-9)

                initial_time = start_date
                horizon = length(date_range) - 1
                @test get_fcas_agc_status(device, initial_time, horizon) == round.(Int, rows.AGCSTATUS)
            end
        end

        @testset "the AGC ramp rate is availability times 12 where that exceeds the ramp rate, else the ramp rate" begin
            sys = deepcopy(sys_base)
            set_fcas_scaling_inputs!(sys, db, date_range)

            raise_from_availability = truth.RAISEREGAVAILABILITY .* 12 .> truth.RAMPUPRATE
            lower_from_availability = truth.LOWERREGAVAILABILITY .* 12 .> truth.RAMPDOWNRATE
            @test any(raise_from_availability) && !all(raise_from_availability)
            @test any(lower_from_availability) && !all(lower_from_availability)

            for device in vcat(collect(get_components(Generator, sys)), collect(get_components(EnergyReservoirStorage, sys)))
                rows = sort(subset(truth, :DUID => ByRow(==(get_name(device)))), :SETTLEMENTDATE)
                got_raise = get_time_series_values(SingleTimeSeries, device, "fcas_agc_ramp_rate_RAISEREG")
                got_lower = get_time_series_values(SingleTimeSeries, device, "fcas_agc_ramp_rate_LOWERREG")
                raise_mask = rows.RAISEREGAVAILABILITY .* 12 .> rows.RAMPUPRATE
                lower_mask = rows.LOWERREGAVAILABILITY .* 12 .> rows.RAMPDOWNRATE

                @test isapprox(got_raise[raise_mask], rows.RAISEREGAVAILABILITY[raise_mask] .* 12 ./ base_power; atol = 1.0e-9)
                @test isapprox(got_raise[.!raise_mask], rows.RAMPUPRATE[.!raise_mask] ./ base_power; atol = 1.0e-9)
                @test isapprox(got_lower[lower_mask], rows.LOWERREGAVAILABILITY[lower_mask] .* 12 ./ base_power; atol = 1.0e-9)
                @test isapprox(got_lower[.!lower_mask], rows.RAMPDOWNRATE[.!lower_mask] ./ base_power; atol = 1.0e-9)
            end
        end

        @testset "a missing availability falls back to the ramp rate; a missing ramp rate stays missing" begin
            interval_hours = 5 / 60
            @test AustralianElectricityMarkets._agc_ramp_rate(5.0, missing, interval_hours) == 5.0
            @test AustralianElectricityMarkets._agc_ramp_rate(5.0, 1.0, interval_hours) == 12.0
            @test ismissing(AustralianElectricityMarkets._agc_ramp_rate(missing, 1.0, interval_hours))
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

            @test has_time_series(get_component(RenewableDispatch, sys, "BW03"), SingleTimeSeries, "uigf")
            @test has_time_series(get_component(RenewableDispatch, sys, "BW04"), SingleTimeSeries, "uigf")
            @test !has_time_series(get_component(ThermalStandard, sys, "ER01"), SingleTimeSeries, "uigf")
            @test !has_time_series(get_component(HydroDispatch, sys, "BW02"), SingleTimeSeries, "uigf")
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
                    AustralianElectricityMarkets._get_fcas_trapezium(device, BidType.RAISEREG, start_date, horizon),
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

            raw = AustralianElectricityMarkets._get_fcas_trapezium(device, BidType.RAISEREG, initial_time, horizon)
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
                raw_mw = with_units_base(() -> get_max_avail.(AustralianElectricityMarkets._get_fcas_trapezium(device, BidType.RAISEREG, initial_time, horizon)), sys, "NATURAL_UNITS")
                @test isapprox(
                    get_max_avail.(scaled_i),
                    min.(raw_mw, max.(rows.RAMPUPRATE, rows.RAISEREGAVAILABILITY .* 12) .* hours); atol = 1.0e-6,
                )
            end

            # A contingency market carries no AGC scaling input series at all: unscaled.
            raw_contingency = AustralianElectricityMarkets._get_fcas_trapezium(device, BidType.RAISE6SEC, initial_time, horizon)
            scaled_contingency = get_scaled_fcas_trapezium(device, BidType.RAISE6SEC, initial_time, horizon)
            @test all(i -> isequal(Tuple(raw_contingency[i]), Tuple(scaled_contingency[i])), 1:horizon)
        end
    end

    @testset "get_initial_mw without an attached initial_mw series" begin
        resolution = Minute(5)
        start_date = DateTime(2025, 1, 1, 0, 0)
        date_range = start_date:resolution:(start_date + Hour(2))

        @testset "get_initial_mw is nothing when initial_mw is not attached" begin
            sys = deepcopy(sys_base)
            bat = get_component(EnergyReservoirStorage, sys, "BW01")
            @test isnothing(get_initial_mw(bat, start_date, length(date_range) - 1))
        end

        @testset "a device with no DISPATCHLOAD rows over date_range throws and is left without series" begin
            sys = deepcopy(sys_base)
            bat = get_component(EnergyReservoirStorage, sys, "BW01")
            # No DISPATCHLOAD rows exist for this far-future range: every interval is missing.
            future_range = DateTime(2099, 1, 1, 0, 0):resolution:(DateTime(2099, 1, 1, 2, 0))
            @test_throws ArgumentError attach_dispatch_limits!(sys, db, future_range)
            @test !has_time_series(bat, SingleTimeSeries, "initial_mw")
        end
    end

    @testset "ramp-down floor above AVAILABILITY raises max_active_power to the floor" begin
        resolution = Minute(5)
        start_date = DateTime(2025, 1, 1, 0, 0)
        short_range = start_date:resolution:(start_date + Minute(10))
        grid = collect(short_range)[1:(end - 1)]  # 3 intervals
        duids = ["BW01", "BW02", "BW03", "BW04", "ER01", "ER02", "PUMP1", "PUMP2", "WDR1"]
        floor_db = dispatchload_db(grid, duids) do duid, _
            # ER01: zero RAMPDOWNRATE and INITIALMW above AVAILABILITY, so the floor is INITIALMW.
            if duid == "ER01"
                return (INITIALMW = 65.41, RAMPUPRATE = 5.0, RAMPDOWNRATE = 0.0, AVAILABILITY = 65.0)
            end
            return (INITIALMW = 50.0, RAMPUPRATE = 5.0, RAMPDOWNRATE = 4.0, AVAILABILITY = 100.0)
        end
        sys = deepcopy(sys_base)
        attach_dispatch_limits!(sys, floor_db, short_range)

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
        resolution = Minute(5)
        start_date = DateTime(2025, 1, 1, 0, 0)
        short_range = start_date:resolution:(start_date + Minute(10))
        grid = collect(short_range)[1:(end - 1)]  # 3 intervals
        covered_duids = ["BW01", "BW02", "BW03", "BW04", "ER02", "PUMP1", "PUMP2", "WDR1"]  # every dispatch device except ER01
        partial_db = dispatchload_db(grid, covered_duids) do _, _
            return (INITIALMW = 50.0, RAMPUPRATE = 5.0, RAMPDOWNRATE = 4.0, AVAILABILITY = 100.0)
        end

        @testset "unavailable: no throw, and no series added for the unavailable device" begin
            sys = deepcopy(sys_base)
            er01 = get_component(ThermalStandard, sys, "ER01")
            set_available!(er01, false)

            @test_nowarn attach_dispatch_limits!(sys, partial_db, short_range)
            @test !has_time_series(er01, SingleTimeSeries, "ramp_up_rate")
            @test has_time_series(get_component(ThermalStandard, sys, "ER02"), SingleTimeSeries, "ramp_up_rate")

        end

        @testset "available: still throws, naming the DUID" begin
            sys = deepcopy(sys_base)

            err = try
                attach_dispatch_limits!(sys, partial_db, short_range)
                nothing
            catch e
                e
            end
            @test err isa ArgumentError
            @test occursin("ER01", err.msg)

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

        sys_lf = nem_system(ldb, RegionalNetworkConfiguration())
        set_market_bids!(sys_lf, ldb, date_range; resolution = Minute(5))

        # Read raw bids (unscaled by loss factors) to compare
        raw_bids = read_bids(ldb, date_range; resolution = Minute(5))
        raw_curve(duid, direction) = AustralianElectricityMarkets._extract_power_bids(first(eachrow(raw_bids[(raw_bids.DUID .== duid) .& (raw_bids.DIRECTION .== direction), :])))
        raw_price(duid, direction) = get_y_coords(raw_curve(duid, direction))
        raw_mw(duid, direction) = get_x_coords(raw_curve(duid, direction))

        prices(sys, name, series = "variable_cost") = with_units_base(sys, "NATURAL_UNITS") do
            ta = get_time_series_array(SingleTimeSeries, get_component(Device, sys, name), series)
            return get_y_coords(first(values(ta)))
        end
        mw(sys, name) = with_units_base(sys, "NATURAL_UNITS") do
            ta = get_time_series_array(SingleTimeSeries, get_component(Device, sys, name), "variable_cost")
            return get_x_coords(first(values(ta)))
        end

        @testset "prices are divided, MW is not" begin
            @test prices(sys_lf, "ER01") ≈ round.(raw_price("ER01", "GEN") ./ (0.9 * 0.97); digits = 2)
            @test prices(sys_lf, "BW02") ≈ raw_price("BW02", "GEN")
            @test prices(sys_lf, "BW01") ≈ round.(raw_price("BW01", "GEN") ./ 0.5; digits = 2)
            @test prices(sys_lf, "BW01", "decremental_variable_cost") ≈
                round.(raw_price("BW01", "LOAD") ./ 0.8; digits = 2)
            @test mw(sys_lf, "ER01") ≈ raw_mw("ER01", "GEN")
        end

        @testset "a scheduled load's decremental bid uses its load loss factor" begin
            @test get_available(get_component(InterruptiblePowerLoad, sys_lf, "PUMP1"))
            @test prices(sys_lf, "PUMP1", "decremental_variable_cost") ≈
                round.(raw_price("PUMP1", "LOAD") ./ 0.8; digits = 2)
        end

        @testset "a bidding unit without a DUDETAILSUMMARY row in force is an error" begin
            # BW02's only row starts after the range, so it has no factor at its start.
            partial = loss_factor_db(df -> subset(two_years(df), [:DUID, :START_DATE] => ByRow((d, t) -> !(d == "BW02" && t < fy_change))))
            sys_partial = nem_system(partial, RegionalNetworkConfiguration())
            @test_throws ArgumentError set_market_bids!(sys_partial, partial, date_range; resolution = Minute(5))
        end
    end
end

@testset "Separate energy availability and UIGF inputs" begin
    using DataFrames, DuckDB
    range = DateTime(2025, 1, 1):Minute(5):DateTime(2025, 1, 1, 0, 10)
    db = aem_connect(HiveConfiguration(hive_location = AEM_TEST_HIVE_DIR))
    function energy_test_system(db)
        sys = nem_system(db, RegionalNetworkConfiguration())
        set_market_bids!(sys, db, range)
        return sys
    end
    sys = energy_test_system(db)
    set_nem_energy_limits!(sys, db, range)
    for (duid, forecast) in [("BW03", [40.0, 41.0]), ("BW04", [70.0, 69.0])]
        gen = get_component(RenewableDispatch, sys, duid)
        @test get_ext(gen)["nem_semi_scheduled"] === true
        @test get_time_series_values(SingleTimeSeries, gen, "energy_max_avail"; ignore_scaling_factors = true) .* get_base_power(sys) ≈ [100.0, 101.0]
        @test get_time_series_values(SingleTimeSeries, gen, "uigf"; ignore_scaling_factors = true) .* get_base_power(sys) ≈ forecast
    end
    coal = get_component(ThermalStandard, sys, "ER01")
    @test get_ext(coal)["nem_semi_scheduled"] === false
    @test !has_time_series(coal, SingleTimeSeries, "uigf")
    @test has_time_series(get_component(EnergyReservoirStorage, sys, "BW01"), SingleTimeSeries, "energy_max_avail")

    function invalid_energy_cache(table, transform!)
        hive = mktempdir()
        cp(AEM_TEST_HIVE_DIR, hive; force = true)
        bad = aem_connect(HiveConfiguration(hive_location = hive))
        frame = DataFrame(DuckDB.execute(bad.db, "SELECT * FROM " * read_hive(bad, table)))
        transform!(frame)
        folder = joinpath(hive, string(table))
        rm(folder; recursive = true)
        mkpath(folder)
        DuckDB.register_data_frame(bad.db, frame, "energy_test_data")
        DuckDB.execute(bad.db, "COPY energy_test_data TO '$folder' (FORMAT PARQUET, PARTITION_BY (archive_month))")
        DuckDB.unregister_table(bad.db, "energy_test_data")
        return bad
    end
    for problem in (:missing_uigf, :negative_uigf, :missing_offer, :missing_classification)
        table = problem == :missing_offer ? :BIDPEROFFER_D : problem == :missing_classification ? :DUDETAILSUMMARY : :DISPATCHLOAD
        bad = invalid_energy_cache(
            table, function (frame)
                if problem == :missing_offer
                    filter!(r -> !(r.DUID == "BW03" && r.BIDTYPE == "ENERGY" && r.INTERVAL_DATETIME == range[2]), frame)
                elseif problem == :missing_classification
                    frame.SCHEDULE_TYPE = Union{String, Missing}[r.DUID == "BW03" ? missing : r.SCHEDULE_TYPE for r in eachrow(frame)]
                else
                    frame.UIGF = Union{Float64, Missing}[r.DUID == "BW03" && r.SETTLEMENTDATE == range[2] ? (problem == :missing_uigf ? missing : -1.0) : r.UIGF for r in eachrow(frame)]
                end
                return
            end
        )
        untouched = energy_test_system(db)
        @test_throws ArgumentError set_nem_energy_limits!(untouched, bad, range)
        @test all(!has_time_series(g, SingleTimeSeries, "energy_max_avail") && !haskey(get_ext(g), "nem_semi_scheduled") for g in get_components(Generator, untouched) if get_available(g))
        close(bad.db)
    end
    @testset "a cached DISPATCHLOAD without UIGF is an error" begin
        old_schema = invalid_energy_cache(:DISPATCHLOAD, frame -> select!(frame, Not(:UIGF)))
        @test_throws Exception read_energy_limits(old_schema, range)
        @test_throws Exception set_nem_energy_limits!(energy_test_system(db), old_schema, range)
        close(old_schema.db)
    end

    @testset "invalid or missing MAXAVAIL is an error" begin
        for bad_value in (missing, -1.0)
            bad = invalid_energy_cache(
                :BIDPEROFFER_D, function (frame)
                    frame.MAXAVAIL = Union{Float64, Missing}[r.DUID == "BW03" && r.BIDTYPE == "ENERGY" && r.INTERVAL_DATETIME == range[2] ? bad_value : r.MAXAVAIL for r in eachrow(frame)]
                    return
                end
            )
            @test_throws ArgumentError set_nem_energy_limits!(energy_test_system(db), bad, range)
            close(bad.db)
        end
    end

    @testset "a schedule type changing mid-range is an error" begin
        bad = invalid_energy_cache(
            :DUDETAILSUMMARY, function (frame)
                changed = frame[frame.DUID .== "BW03", :][1:1, :]
                changed.START_DATE .= range[1]
                changed.SCHEDULE_TYPE .= "SCHEDULED"
                append!(frame, changed)
                return
            end
        )
        @test_throws ArgumentError set_nem_energy_limits!(energy_test_system(db), bad, range)
        close(bad.db)
    end

    @testset "non-scheduled loads receive zero availability" begin
        # The strict replay build needs complete invoked-constraint and dispatch inputs.
        complete_dir = mktempdir()
        create_mock_data(complete_dir; complete_inputs = true)
        write_mock_interconnector_results(complete_dir)
        complete_db = aem_connect(HiveConfiguration(hive_location = complete_dir, filesystem = "file"))
        replay_range = DateTime(2025, 1, 1, 0, 5):Minute(5):DateTime(2025, 1, 1, 0, 20)
        fcas_sys = nem_system(complete_db, NEMDEConfiguration(); date_range = replay_range)
        close(complete_db.db)
        loads = [l for l in get_components(ControllableLoad, fcas_sys) if get_available(l) && startswith(get_name(l), "ASLOAD")]
        @test !isempty(loads)
        for load in loads
            @test get_ext(load)["nem_semi_scheduled"] === false
            @test all(iszero, get_time_series_values(SingleTimeSeries, load, "energy_max_avail"; ignore_scaling_factors = true))
            @test !has_time_series(load, SingleTimeSeries, "uigf")
        end
    end

    @testset "a repeated call replaces series after a classification change" begin
        again = energy_test_system(db)
        set_nem_energy_limits!(again, db, range)
        gen = get_component(RenewableDispatch, again, "BW03")
        @test has_time_series(gen, SingleTimeSeries, "uigf")
        reclassified = invalid_energy_cache(
            :DUDETAILSUMMARY, function (frame)
                frame.SCHEDULE_TYPE = Union{String, Missing}[r.DUID == "BW03" ? "SCHEDULED" : r.SCHEDULE_TYPE for r in eachrow(frame)]
                return
            end
        )
        set_nem_energy_limits!(again, reclassified, range)
        @test get_ext(gen)["nem_semi_scheduled"] === false
        @test !has_time_series(gen, SingleTimeSeries, "uigf")
        @test get_time_series_values(SingleTimeSeries, gen, "energy_max_avail"; ignore_scaling_factors = true) .* get_base_power(again) ≈ [100.0, 101.0]
        set_nem_energy_limits!(again, db, range)
        @test get_ext(gen)["nem_semi_scheduled"] === true
        @test get_time_series_values(SingleTimeSeries, gen, "uigf"; ignore_scaling_factors = true) .* get_base_power(again) ≈ [40.0, 41.0]
        close(reclassified.db)
    end

    @testset "read_energy_limits returns offers, UIGF and schedule type" begin
        rows = read_energy_limits(db, range)
        bw03 = sort(rows[(rows.DUID .== "BW03") .& (rows.DIRECTION .== "GEN"), :], :SETTLEMENTDATE)
        @test bw03.SETTLEMENTDATE == collect(range)[1:2]
        @test bw03.MAXAVAIL ≈ [100.0, 101.0]
        @test bw03.UIGF ≈ [40.0, 41.0]
        @test all(==("SEMI-SCHEDULED"), bw03.SCHEDULE_TYPE)
        @test all(r -> r.SETTLEMENTDATE < last(range), eachrow(rows))
    end
    close(db.db)
end

@testset "Grid padding of bids and FCAS rows" begin
    AEM = AustralianElectricityMarkets
    grid = DateTime(2025, 1, 1, 0, 5):Minute(5):DateTime(2025, 1, 1, 0, 15)
    curve(prices, widths) = PowerSystems.PiecewiseStepData(vcat(0.0, cumsum(widths)), prices)
    rows = DataFrame(
        DUID = ["X", "X"], DIRECTION = ["GEN", "GEN"], INTERVAL_DATETIME = [grid[2], grid[3]],
        MAXAVAIL = [10.0, 20.0], piecewise_step_data = [curve([1.0, 2.0], [5.0, 5.0]), curve([1.5, 2.5], [5.0, 10.0])],
    )
    padded = AEM._pad_bids_to_grid(rows, grid)
    @test nrow(padded) == length(grid)
    @test padded.INTERVAL_DATETIME == collect(grid)
    @test padded.MAXAVAIL == [0.0, 10.0, 20.0]
    # An absent stamp is a zero-width curve on the first real row's prices.
    @test PowerSystems.get_y_coords(padded.piecewise_step_data[1]) == [1.0, 2.0]
    @test PowerSystems.get_x_coords(padded.piecewise_step_data[1]) == [0.0, 0.0, 0.0]
    @test PowerSystems.get_x_coords(padded.piecewise_step_data[2]) == [0.0, 5.0, 10.0]
    @test_throws ArgumentError AEM._pad_bids_to_grid(vcat(rows, rows), grid)
    @test_throws ArgumentError AEM._pad_bids_to_grid(rows, grid[1:2])

    values = DataFrame(INTERVAL_DATETIME = [grid[2]], X = [7.0])
    @test AEM._on_grid(values, :X, grid, 0.0, "U1", BidType.RAISEREG) == [0.0, 7.0, 0.0]
    @test_throws ArgumentError AEM._on_grid(vcat(values, values), :X, grid, 0.0, "U1", BidType.RAISEREG)
    @test_throws ArgumentError AEM._on_grid(DataFrame(INTERVAL_DATETIME = [grid[end] + Minute(5)], X = [1.0]), :X, grid, 0.0, "U1", BidType.RAISEREG)
end
