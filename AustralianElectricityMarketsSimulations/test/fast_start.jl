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
