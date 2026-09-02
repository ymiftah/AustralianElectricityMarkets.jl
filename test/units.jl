@testset "Unit physical bid parameters and MLFs" begin
    using AustralianElectricityMarkets
    using PowerSystems
    using Dates
    using DataFrames

    hive_dir = AEM_TEST_HIVE_DIR
    config = HiveConfiguration(hive_location = hive_dir, filesystem = "file")
    db = aem_connect(config)

    start_date = DateTime(2025, 1, 1, 0, 0)
    date_range = start_date:Minute(5):(start_date + Hour(1))

    @testset "read_marginal_loss_factors" begin
        mlfs = read_marginal_loss_factors(db, date_range)
        @test mlfs isa Dict{String, Float64}
        # BW01's current window (START_DATE 2025-01-01) wins over both its superseded
        # 2020-2024 window (TLF 0.80) and its stale 2024-12 archive_month duplicate of the
        # *same* window (TLF 0.50, superseded by the 2025-01 archive_month's 0.95).
        @test mlfs["BW01"] == 0.95
        @test mlfs["BW02"] == 0.96
        @test mlfs["BW03"] == 0.97
        @test mlfs["BW04"] == 0.98
        @test mlfs["ER01"] == 0.99
        @test mlfs["ER02"] == 1.0

        # Resolving as of a date range fully before the current window: only BW01's
        # superseded row is valid over it (its END_DATE, 2024-12-31, covers it); every other
        # DUID's only row starts 2025-01-01, so it isn't valid yet and is absent entirely.
        old_range = DateTime(2020, 6, 1):Minute(5):DateTime(2020, 6, 1, 1, 0)
        old_mlfs = read_marginal_loss_factors(db, old_range)
        @test old_mlfs["BW01"] == 0.8
        @test !haskey(old_mlfs, "BW02")

        empty_db = aem_connect(HiveConfiguration(hive_location = mktempdir(), filesystem = "file"))
        @test_throws ArgumentError read_marginal_loss_factors(empty_db, date_range)
    end

    @testset "set_marginal_loss_factors!" begin
        sys = nem_system(db, RegionalNetworkConfiguration())
        set_marginal_loss_factors!(sys, db, date_range)

        er01 = get_component(ThermalStandard, sys, "ER01")
        @test get_ext(er01)["transmission_loss_factor"] == 0.99

        # BW01 is a battery (EnergyReservoirStorage, not Generator) - the same ext mechanism
        # must reach it too, since a later PR's regional energy balance needs the MLF for
        # every unit contributing to it, not just conventional generators.
        bw01 = get_component(EnergyReservoirStorage, sys, "BW01")
        @test get_ext(bw01)["transmission_loss_factor"] == 0.95
    end

    @testset "read_bids carries ROCUP/ROCDOWN through the energy path" begin
        bids = read_bids(db, date_range)
        @test "ROCUP" in names(bids)
        @test "ROCDOWN" in names(bids)
        er01_bids = subset(bids, :DUID => ByRow(==("ER01")), :DIRECTION => ByRow(==("GEN")))
        @test !isempty(er01_bids)
        @test all(==(5.0), er01_bids.ROCUP)
        @test all(==(5.0), er01_bids.ROCDOWN)

        # DUIDs never bidding a ramp rate come through as `missing`, not silently dropped.
        er02_bids = subset(bids, :DUID => ByRow(==("ER02")), :DIRECTION => ByRow(==("GEN")))
        @test !isempty(er02_bids)
        @test all(ismissing, er02_bids.ROCUP)
    end

    @testset "set_bid_ramp_rates!" begin
        sys = nem_system(db, RegionalNetworkConfiguration())
        set_bid_ramp_rates!(sys, db, date_range)

        # ER01 (ThermalStandard) bids ROCUP=ROCDOWN=5.0, well above its registered
        # MAXRATEOFCHANGEUP/DOWN (1.0 MW/min, mock DUDETAIL) - the effective rate must be
        # capped down to the registered value, in both the up and down direction.
        er01 = get_component(ThermalStandard, sys, "ER01")
        @test has_time_series(er01, Deterministic, "bid_ramp_rate")
        er01_ts = get_time_series(Deterministic, er01, "bid_ramp_rate")
        er01_rates = first(values(get_data(er01_ts)))
        @test all(==((1.0, 1.0)), er01_rates)

        # BW02 (HydroDispatch) bids a tighter rate (0.5 up / 0.4 down) than its registered
        # cap - the bid, not the registered rate, must pass through unchanged.
        bw02 = get_component(HydroDispatch, sys, "BW02")
        @test has_time_series(bw02, Deterministic, "bid_ramp_rate")
        bw02_ts = get_time_series(Deterministic, bw02, "bid_ramp_rate")
        bw02_rates = first(values(get_data(bw02_ts)))
        @test all(==((0.5, 0.4)), bw02_rates)

        # ER02 never bids a ramp rate - falls back to the registered rate, not "unlimited".
        er02 = get_component(ThermalStandard, sys, "ER02")
        @test has_time_series(er02, Deterministic, "bid_ramp_rate")
        er02_ts = get_time_series(Deterministic, er02, "bid_ramp_rate")
        er02_rates = first(values(get_data(er02_ts)))
        @test all(==((1.0, 1.0)), er02_rates)
    end

    @testset "_effective_ramp_rate mutation check" begin
        # Earns the "min(bid, registered) actually binds" claim by mutation rather than by
        # re-reading the implementation: a capping bug (using the bid rate unconditionally)
        # must make this fail, and the real function must pass it.
        registered = (up = 1.0, down = 1.0)
        broken(rocup, rocdown, registered) = (something(rocup, registered.up), something(rocdown, registered.down))

        # Broken: no capping against `registered` at all - a bid rate above the registered
        # cap sails straight through.
        @test broken(5.0, 5.0, registered) != (1.0, 1.0)

        # Real implementation: bid above registered -> capped; bid below -> passes through;
        # missing bid -> registered fallback.
        @test AustralianElectricityMarkets._effective_ramp_rate(5.0, 5.0, registered) == (1.0, 1.0)
        @test AustralianElectricityMarkets._effective_ramp_rate(0.5, 0.4, registered) == (0.5, 0.4)
        @test AustralianElectricityMarkets._effective_ramp_rate(missing, missing, registered) == (1.0, 1.0)
    end

    @testset "set_bid_minimum_load!" begin
        sys = nem_system(db, RegionalNetworkConfiguration())
        set_bid_minimum_load!(sys, db, date_range)

        # MINIMUMLOAD is per-DUID in the mock (5.0*i for i in 1:6, in DUID order
        # BW01..ER02) - ER01 is the 5th, so 25.0.
        er01 = get_component(ThermalStandard, sys, "ER01")
        @test has_time_series(er01, Deterministic, "bid_minimum_load")
        er01_ts = get_time_series(Deterministic, er01, "bid_minimum_load")
        @test all(==(25.0), first(values(get_data(er01_ts))))

        bw03 = get_component(RenewableDispatch, sys, "BW03")
        @test has_time_series(bw03, Deterministic, "bid_minimum_load")
        bw03_ts = get_time_series(Deterministic, bw03, "bid_minimum_load")
        @test all(==(15.0), first(values(get_data(bw03_ts))))
    end
end
