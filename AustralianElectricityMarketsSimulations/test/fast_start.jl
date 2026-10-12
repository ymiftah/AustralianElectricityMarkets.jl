function save_fast_start_table(hive, table, rows)
    conn = DuckDB.connect(DuckDB.DB())
    DuckDB.execute(conn, "SET preserve_identifier_case=true")
    DuckDB.register_data_frame(conn, rows, "tmp_table")
    table_dir = joinpath(hive, table)
    mkpath(table_dir)
    DuckDB.execute(conn, "COPY (SELECT * FROM tmp_table) TO '$table_dir' (FORMAT 'PARQUET', PARTITION_BY (archive_month))")
    DuckDB.unregister_table(conn, "tmp_table")
    return nothing
end

function fast_start_fixture(; current_outcomes = (mode = 0, mode_time = 99.0, total_cleared = 900.0), rrp = 50.0)
    hive = mktempdir()
    t = DateTime(2025, 1, 2, 4, 5)
    trading_day = Date(2025, 1, 2)
    day_offer = DataFrame(
        SETTLEMENTDATE = [DateTime(2025, 1, 1, 12), DateTime(2025, 1, 2, 12), DateTime(2025, 1, 2, 12), DateTime(2025, 1, 2, 12)],
        DUID = ["FS1", "FS1", "BIDI", "NULLFS"],
        DIRECTION = fill("GEN", 4), BIDTYPE = fill("ENERGY", 4), VERSIONNO = fill(1, 4),
        MINIMUMLOAD = [10.0, 11.0, 0.0, 0.0], DAILYENERGYCONSTRAINT = fill(1000.0, 4),
        T1 = Union{Missing, Float64}[1.0, 5.0, 0.0, missing],
        T2 = Union{Missing, Float64}[2.0, 6.0, 0.0, missing],
        T3 = Union{Missing, Float64}[3.0, 7.0, 0.0, missing],
        T4 = Union{Missing, Float64}[4.0, 8.0, 0.0, missing], archive_month = fill("2025-01", 4),
    )
    append!(
        day_offer, DataFrame(
            SETTLEMENTDATE = [DateTime(2025, 1, 2, 12)], DUID = ["BIDI"], DIRECTION = ["LOAD"],
            BIDTYPE = ["ENERGY"], VERSIONNO = [1], MINIMUMLOAD = [0.0], DAILYENERGYCONSTRAINT = [1000.0],
            T1 = [0.0], T2 = [0.0], T3 = [0.0], T4 = [0.0], archive_month = ["2025-01"],
        )
    )
    for i in 1:10
        day_offer[!, "PRICEBAND$i"] = fill(10.0 * i, nrow(day_offer))
    end
    save_fast_start_table(hive, "BIDDAYOFFER_D", day_offer)

    per_offer = DataFrame(
        SETTLEMENTDATE = [DateTime(2025, 1, 1, 12), DateTime(2025, 1, 2, 12), DateTime(2025, 1, 2, 12), DateTime(2025, 1, 2, 12), DateTime(2025, 1, 2, 12)],
        BIDTYPE = fill("ENERGY", 5), INTERVAL_DATETIME = [t - Minute(5), t, t, t, t],
        VERSIONNO = fill(1, 5), DUID = ["FS1", "FS1", "BIDI", "BIDI", "NULLFS"],
        DIRECTION = ["GEN", "GEN", "GEN", "LOAD", "GEN"],
        MAXAVAIL = [80.0, 80.0, 20.0, 15.0, 10.0], archive_month = fill("2025-01", 5),
    )
    for i in 1:10
        per_offer[!, "BANDAVAIL$i"] = fill(10.0, nrow(per_offer))
    end
    save_fast_start_table(hive, "BIDPEROFFER_D", per_offer)

    dispatch = DataFrame(
        SETTLEMENTDATE = [t - Minute(10), t - Minute(5), t - Minute(5), t - Minute(5), t - Minute(5), t - Minute(5), t, t, t, t],
        RUNNO = [1, 1, 1, 2, 1, 1, 1, 1, 1, 1], INTERVENTION = [0, 0, 1, 0, 0, 0, 0, 0, 1, 0],
        DUID = ["FS1", "FS1", "FS1", "FS1", "BIDI", "NULLFS", "FS1", "BIDI", "FS1", "NULLFS"],
        DISPATCHMODE = [1, 2, 4, 3, 1, 0, current_outcomes.mode, 0, 1, 0],
        DISPATCHMODETIME = [6.0, 7.0, 8.0, 9.0, 5.0, 3.0, current_outcomes.mode_time, 99.0, 99.0, 99.0],
        INITIALMW = [20.0, 22.0, 23.0, 24.0, 9.0, 5.0, 25.0, 10.0, 25.0, 5.0],
        TOTALCLEARED = [29.0, 30.0, 31.0, 32.0, 8.0, 4.0, current_outcomes.total_cleared, 900.0, 900.0, 900.0],
        RAMPUPRATE = [4.0, 4.0, 4.1, 4.2, 2.0, 1.0, 5.0, 3.0, 5.0, 1.0],
        RAMPDOWNRATE = [3.0, 3.0, 3.1, 3.2, 2.0, 1.0, 6.0, 2.0, 6.0, 1.0],
        AVAILABILITY = [70.0, 70.0, 71.0, 72.0, 12.0, 10.0, 75.0, 15.0, 75.0, 10.0], archive_month = fill("2025-01", 10),
    )
    save_fast_start_table(hive, "DISPATCHLOAD", dispatch)
    save_fast_start_table(
        hive, "DISPATCHPRICE", DataFrame(
            SETTLEMENTDATE = [t], RUNNO = [1], INTERVENTION = [0], REGIONID = ["NSW1"],
            RRP = [rrp], archive_month = ["2025-01"],
        )
    )
    return aem_connect(HiveConfiguration(hive_location = hive, filesystem = "file")), t
end

@testset "Fast-start inputs" begin
    db, t = fast_start_fixture()
    inputs = AEMS.read_fast_start_inputs(db, t)
    fs = inputs["FS1"]

    @test fs.profile isa AEMS.FastStartProfile
    @test (fs.profile.minimum_load_mw, fs.profile.t1_minutes, fs.profile.t2_minutes, fs.profile.t3_minutes, fs.profile.t4_minutes) ==
        (11.0, 5.0, 6.0, 7.0, 8.0)
    @test fs.state == AEMS.FastStartState(2, 7.0)
    @test (fs.initial_mw, fs.ramp_up_rate, fs.ramp_down_rate, fs.max_avail) == (25.0, 5.0, 6.0, 80.0)
    @test fs.previous_total_cleared == 30.0
    @test !haskey(inputs, "BIDI")
    @test !haskey(inputs, "NULLFS")

    bids = read_bids(db, [t, t + Minute(5)]; resolution = Minute(5))
    bidi = sort(subset(bids, :DUID => ByRow(==("BIDI"))), :DIRECTION)
    @test bidi.DIRECTION == ["GEN", "LOAD"]
    @test bidi.T1 == [0.0, 0.0]

    @test AEMS.read_fast_start_inputs(db, DateTime(2025, 1, 2, 4, 0))["FS1"].profile.minimum_load_mw == 10.0
    @test AEMS.read_fast_start_inputs(db, DateTime(2025, 1, 2, 4, 5))["FS1"].profile.minimum_load_mw == 11.0
    intervention = AEMS.read_fast_start_inputs(db, t; intervention = 1)["FS1"]
    @test intervention.state == AEMS.FastStartState(4, 8.0)
    @test intervention.previous_total_cleared == 31.0

    altered_db, _ = fast_start_fixture(; current_outcomes = (mode = 4, mode_time = 0.0, total_cleared = -100.0), rrp = -900.0)
    @test AEMS.read_fast_start_inputs(altered_db, t)["FS1"] == fs

end

function fast_start_input(;
        profile = AEMS.FastStartProfile(20.0, 2.0, 3.0, 4.0, 5.0), mode = 0,
        elapsed = 0.0, initial_mw = 0.0, ramp_up = 60.0, ramp_down = 60.0,
        max_avail = 100.0, previous_total_cleared = 0.0
    )
    return AEMS.FastStartInput(
        profile, AEMS.FastStartState(mode, elapsed), initial_mw, ramp_up, ramp_down, max_avail,
        previous_total_cleared,
    )
end

@testset "Fast-start state transitions and envelopes" begin
    @testset "Mode 0 commitment threshold" begin
        for (candidate, expected) in (
                (0.004, AEMS.FastStartState(0, 0.0)),
                (0.005, AEMS.FastStartState(0, 0.0)),
                (0.006, AEMS.FastStartState(2, 3.0)),
            )
            input = fast_start_input()
            envelope = AEMS.plan_fast_start(input, candidate; interval_minutes = 5.0)
            @test envelope.state == expected
            if candidate > 0.005
                @test envelope.ramp_minutes === nothing
            end
        end
    end

    @testset "Profile segments and fixed versus lower bounds" begin
        cases = [
            (AEMS.FastStartState(0, 0.0), 0.0, 0.0, 0.0),
            (AEMS.FastStartState(1, 1.0), 0.0, 0.0, 0.0),
            (AEMS.FastStartState(2, 1.5), 0.0, 10.0, 10.0),
            (AEMS.FastStartState(3, 0.0), 0.0, 20.0, nothing),
            (AEMS.FastStartState(4, 2.0), 0.0, 12.0, nothing),
        ]
        for (state, minutes, lower, upper) in cases
            input = fast_start_input(; mode = state.mode, elapsed = state.elapsed_minutes)
            envelope = AEMS.plan_fast_start(input, 10.0; interval_minutes = minutes)
            @test envelope.profile_lower_mw == lower
            @test envelope.profile_upper_mw == upper
            if state.mode <= 2
                @test envelope.ramp_minutes === nothing
            end
        end
        mode3 = AEMS.plan_fast_start(fast_start_input(; mode = 3), 10.0; interval_minutes = 0.0)
        @test mode3.profile_lower_mw == 20.0
        @test mode3.profile_upper_mw === nothing
    end

    @testset "Transitions cross zero and multiple segments exactly" begin
        ordinary_profile = AEMS.FastStartProfile(20.0, 2.0, 3.0, 4.0, 5.0)
        ordinary_cases = [
            (AEMS.FastStartState(1, 0.0), 2.0, AEMS.FastStartState(1, 2.0)),
            (AEMS.FastStartState(2, 1.0), 2.0, AEMS.FastStartState(2, 3.0)),
            (AEMS.FastStartState(3, 3.0), 1.0, AEMS.FastStartState(3, 4.0)),
        ]
        for (state, minutes, expected) in ordinary_cases
            input = fast_start_input(; profile = ordinary_profile, mode = state.mode, elapsed = state.elapsed_minutes)
            @test AEMS.plan_fast_start(input, 10.0; interval_minutes = minutes).state == expected
        end
        next_step_cases = [
            (AEMS.FastStartState(1, 2.0), AEMS.FastStartState(2, 1.0)),
            (AEMS.FastStartState(2, 3.0), AEMS.FastStartState(3, 1.0)),
            (AEMS.FastStartState(3, 4.0), AEMS.FastStartState(4, 1.0)),
        ]
        for (state, expected) in next_step_cases
            input = fast_start_input(; profile = ordinary_profile, mode = state.mode, elapsed = state.elapsed_minutes)
            @test AEMS.plan_fast_start(input, 0.0; interval_minutes = 1.0).state == expected
        end

        profile = AEMS.FastStartProfile(20.0, 0.0, 2.0, 0.0, 3.0)
        cases = [
            (AEMS.FastStartState(1, 0.0), 2.0, AEMS.FastStartState(2, 2.0)),
            (AEMS.FastStartState(1, 0.0), 5.0, AEMS.FastStartState(4, 3.0)),
            (AEMS.FastStartState(2, 1.0), 1.0, AEMS.FastStartState(2, 2.0)),
        ]
        for (state, minutes, expected) in cases
            input = fast_start_input(; profile, mode = state.mode, elapsed = state.elapsed_minutes)
            envelope = AEMS.plan_fast_start(input, 10.0; interval_minutes = minutes)
            @test envelope.state == expected
        end
        zero_segments = AEMS.FastStartProfile(20.0, 0.0, 0.0, 0.0, 5.0)
        envelope = AEMS.plan_fast_start(fast_start_input(; profile = zero_segments), 1.0)
        @test envelope.state == AEMS.FastStartState(4, 5.0)
        zero_t2 = AEMS.FastStartProfile(20.0, 1.0, 0.0, 1.0, 1.0)
        @test AEMS.plan_fast_start(
            fast_start_input(; profile = zero_t2, mode = 1), 1.0; interval_minutes = 2.0,
        ).state == AEMS.FastStartState(3, 1.0)
        zero_t4 = AEMS.FastStartProfile(20.0, 1.0, 1.0, 1.0, 0.0)
        @test AEMS.plan_fast_start(
            fast_start_input(; profile = zero_t4, mode = 4), 1.0; interval_minutes = 1.0,
        ).profile_lower_mw == 0.0
    end

    @testset "RTD preprocessing uses meter and prior target as specified" begin
        profile = AEMS.FastStartProfile(20.0, 2.0, 3.0, 4.0, 5.0)
        cases = [
            (0.999, 10.0, 0, 100.0, AEMS.FastStartState(0, 0.0)),
            (1.0, 10.0, 0, 100.0, AEMS.FastStartState(4, 5.0)),
            (1.001, 10.0, 0, 100.0, AEMS.FastStartState(4, 5.0)),
            (0.999, 0.0, 0, 100.0, AEMS.FastStartState(0, 0.0)),
            (1.0, 0.0, 0, 0.0, AEMS.FastStartState(4, 5.0)),
            (1.001, 0.0, 0, 0.0, AEMS.FastStartState(4, 5.0)),
            (0.5, 10.0, 2, 0.0, AEMS.FastStartState(4, 5.0)),
            (0.5, 10.0, 0, 0.0, AEMS.FastStartState(0, 0.0)),
        ]
        for (meter, prior_target, mode, max_avail, expected) in cases
            input = fast_start_input(
                ; profile, mode, initial_mw = meter, max_avail,
                previous_total_cleared = prior_target,
            )
            @test AEMS.preprocess_fast_start(input).state == expected
        end
    end

    @testset "Startup crossing uses profile anchor and full residual time" begin
        profile = AEMS.FastStartProfile(20.0, 10.0, 2.0, 40.0, 7.0)
        input = fast_start_input(; profile, mode = 1, elapsed = 10.0, initial_mw = 17.0, ramp_up = 780.0)
        envelope = AEMS.plan_fast_start(input, 0.0)
        @test envelope.state == AEMS.FastStartState(3, 3.0)
        @test envelope.ramp_initial_mw == 20.0
        @test envelope.ramp_minutes == 3.0
        @test envelope.ramp_initial_mw + envelope.ramp_minutes * input.ramp_up_rate / 60 == 59.0
        @test envelope.profile_lower_mw == 20.0
        @test envelope.profile_upper_mw === nothing

        beyond_t3 = fast_start_input(
            ; profile = AEMS.FastStartProfile(20.0, 1.0, 1.0, 1.0, 10.0),
            mode = 1, initial_mw = 17.0, ramp_up = 780.0,
        )
        crossed_t3 = AEMS.plan_fast_start(beyond_t3, 0.0)
        @test crossed_t3.state == AEMS.FastStartState(4, 2.0)
        @test crossed_t3.ramp_minutes == 3.0

        mortlk11_boundary = fast_start_input(
            ; profile = AEMS.FastStartProfile(20.0, 10.0, 2.0, 40.0, 7.0),
            mode = 1, elapsed = 5.0,
        )
        mortlk11_t1 = AEMS.plan_fast_start(mortlk11_boundary, 0.0)
        @test mortlk11_t1.state == AEMS.FastStartState(1, 10.0)
        mortlk11 = fast_start_input(
            ; profile = AEMS.FastStartProfile(20.0, 10.0, 2.0, 40.0, 7.0),
            mode = 1, elapsed = 10.0, initial_mw = 17.0, ramp_up = 780.0,
            ramp_down = 780.0, max_avail = 268.0,
        )
        mortlk11_result = AEMS.plan_fast_start(mortlk11, 0.0)
        @test mortlk11_result.state == AEMS.FastStartState(3, 3.0)
        @test mortlk11_result.ramp_initial_mw + mortlk11_result.ramp_minutes * mortlk11.ramp_up_rate / 60 == 59.0

        qps5_profile = AEMS.FastStartProfile(74.0, 22.0, 8.0, 21.0, 8.0)
        qps5_endpoint = fast_start_input(; profile = qps5_profile, mode = 2, elapsed = 3.0)
        qps5_t2 = AEMS.plan_fast_start(qps5_endpoint, 0.0)
        @test qps5_t2.state == AEMS.FastStartState(2, 8.0)
        @test qps5_t2.ramp_minutes === nothing
        qps5_next = fast_start_input(; profile = qps5_profile, mode = 2, elapsed = 8.0)
        qps5_result = AEMS.plan_fast_start(qps5_next, 0.0)
        @test qps5_result.state == AEMS.FastStartState(3, 5.0)
        @test qps5_result.ramp_minutes == 5.0

        meter_mismatch = fast_start_input(; mode = 3, initial_mw = 17.0)
        ordinary = AEMS.plan_fast_start(meter_mismatch, 0.0)
        @test ordinary.ramp_initial_mw == 17.0
        @test ordinary.ramp_minutes == 5.0

        continuation = AEMS.plan_fast_start(fast_start_input(; mode = 3), 0.0)
        @test continuation.state.mode == 4
    end

    @testset "Mode 4 shutdown waits for profile and ramp down" begin
        profile = AEMS.FastStartProfile(20.0, 1.0, 1.0, 1.0, 2.0)
        input = fast_start_input(; profile, mode = 4, elapsed = 0.0, initial_mw = 5.0, ramp_down = 150.0)
        before_t4 = AEMS.plan_fast_start(input, 0.0; interval_minutes = 1.0)
        @test !before_t4.can_shutdown
        @test AEMS.finalize_fast_start_state(before_t4, 0.0) == AEMS.FastStartState(4, 1.0)
        after_t4 = AEMS.plan_fast_start(input, 0.0; interval_minutes = 2.0)
        @test after_t4.can_shutdown
        @test AEMS.finalize_fast_start_state(after_t4, 0.005) == AEMS.FastStartState(0, 0.0)
        @test AEMS.finalize_fast_start_state(after_t4, 0.006) == AEMS.FastStartState(4, 2.0)

        slow_ramp = fast_start_input(; profile, mode = 4, initial_mw = 5.0, ramp_down = 60.0)
        ramp_limited = AEMS.plan_fast_start(slow_ramp, 0.0; interval_minutes = 2.0)
        @test !ramp_limited.can_shutdown
        @test AEMS.finalize_fast_start_state(ramp_limited, 0.0) == AEMS.FastStartState(4, 2.0)
    end
end
