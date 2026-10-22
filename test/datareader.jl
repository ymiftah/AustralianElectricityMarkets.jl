let
    hive_dir = AEM_TEST_HIVE_DIR
    @test isdir(hive_dir)

    config = HiveConfiguration(hive_location = hive_dir, filesystem = "file")
    db = aem_connect(config)

    @testset "_table_is_cached" begin
        # A glob matching zero files is a legitimate false, not an error - confirmed directly
        # this still holds once the bare `catch -> false` was removed (see query_helpers.jl).
        @test AustralianElectricityMarkets._table_is_cached(db, :DISPATCHCONSTRAINT)
        @test !AustralianElectricityMarkets._table_is_cached(db, :NOT_A_REAL_TABLE)
    end

    @testset "read_units" begin
        df = read_units(db)
        @test df isa DataFrame
        @test nrow(df) > 0
        @test "DUID" in names(df)
        @test !("TECHNOLOGY" in names(df))
        @test !("FUELTYPE" in names(df))
        @test "BW01" in df.DUID
        # Verify technology mapping from mock data "Battery Storage" (BW01)
        mapped = AustralianElectricityMarkets.RegionModel._map_unit_technology(df)
        @test only(mapped.TECHNOLOGY[mapped.DUID .== "BW01"]) == PrimeMovers.BA
        @test only(mapped.FUELTYPE[mapped.DUID .== "BW01"]) == ThermalFuels.OTHER

        # BAYSW (station for BW01-BW04) is renamed in a later STATION archive_month
        # partition (mock_data.jl). read_units() must resolve one name per DUID —
        # not fan out into duplicate rows via the STATIONID -> STATIONNAME join.
        @test allunique(df.DUID)
        bw01_names = df.STATIONNAME[df.DUID .== "BW01"]
        @test length(bw01_names) == 1
        @test only(bw01_names) == "Bayswater Power Station"
    end

    @testset "read_bids" begin
        # Use 2025 to match mock data
        date_range = DateTime(2025, 1, 1, 0, 0):Dates.Minute(5):DateTime(2025, 1, 1, 1, 0)
        df = read_bids(db, date_range)
        @test df isa DataFrame
        @test nrow(df) > 0
        @test "DUID" in names(df)
        @test "PRICEBANDARRAY" in names(df) && "BANDAVAILARRAY" in names(df)
        @test !("piecewise_step_data" in names(df))
    end

    @testset "Bounded demand preserves complete aggregation bins" begin
        start = DateTime(2025, 1, 1)
        for resolution in (Minute(5), Minute(15), Hour(1))
            full = read_demand(db; resolution = resolution)
            for (from, to) in (
                    (start, start + Hour(2)),
                    (start + Minute(7), start + Minute(77)),
                    (start + Minute(55), start + Minute(125)),
                    (start + Minute(235), start + Minute(245)),
                    (start - Hour(1), start + Minute(5)),
                    (start + Hour(5), start + Hour(6)),
                )
                date_range = from:Minute(5):to
                expected = full[(first(date_range) .<= full.SETTLEMENTDATE) .& (full.SETTLEMENTDATE .< last(date_range)), :]
                bounded = read_demand(db, date_range; resolution = resolution)
                @test isequal(sort(bounded, [:SETTLEMENTDATE, :REGIONID]), sort(expected, [:SETTLEMENTDATE, :REGIONID]))
            end
        end

        hourly = read_demand(db, (start + Minute(55)):Minute(5):(start + Minute(125)); resolution = Hour(1))
        nsw = hourly[hourly.REGIONID .== "NSW1", :]
        @test nsw.SETTLEMENTDATE == [start + Hour(1), start + Hour(2)]
        @test nsw.TOTALDEMAND == [1065.0, 1185.0]
        @test nsw.LOSSDEMAND == [1080.0, 1200.0]

        charging = read_demand(db, (start + Minute(235)):Minute(5):(start + Minute(245)))
        vic = charging[charging.REGIONID .== "VIC1", :]
        @test vic.TOTALDEMAND == [1470.0, 1480.0]
        @test vic.LOSSDEMAND == [1485.0, 1465.0]

        daily_range = Date(2025, 1, 1):Day(1):Date(2025, 1, 2)
        bounded = read_demand(db, daily_range)
        full = read_demand(db)
        @test isequal(sort(bounded, [:SETTLEMENTDATE, :REGIONID]), sort(full, [:SETTLEMENTDATE, :REGIONID]))
    end
end
