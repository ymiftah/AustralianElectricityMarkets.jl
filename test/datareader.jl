let
    hive_dir = AEM_TEST_HIVE_DIR
    @test isdir(hive_dir)

    config = HiveConfiguration(hive_location = hive_dir, filesystem = "file")
    db = aem_connect(config)

    @testset "read_units" begin
        df = read_units(db)
        @test df isa DataFrame
        @test nrow(df) > 0
        @test "DUID" in names(df)
        @test "TECHNOLOGY" in names(df)
        @test "FUELTYPE" in names(df)
        @test df.DUID[1] == "BW01"
        # Verify technology mapping from mock data "Battery Storage" (first unit)
        @test df.TECHNOLOGY[1] == PrimeMovers.BA

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
        @test "piecewise_step_data" in names(df)
    end
end
