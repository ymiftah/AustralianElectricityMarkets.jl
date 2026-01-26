@testitem "Datareader tests" begin
    using AustralianElectricityMarkets
    using TidierDB
    using DataFrames
    using Dates
    using PowerSystems

    hive_dir = get(ENV, "AEM_TEST_HIVE_DIR", "")
    @test isdir(hive_dir)

    config = HiveConfiguration(hive_location = hive_dir, filesystem = "file")
    db = aem_connect(duckdb(), config)

    @testset "read_interconnectors" begin
        df = read_interconnectors(db)
        @test df isa DataFrame
        @test nrow(df) > 0
        @test "INTERCONNECTORID" in names(df)
    end

    @testset "read_demand" begin
        df = read_demand(db)
        @test df isa DataFrame
        @test nrow(df) > 0
        @test "REGIONID" in names(df)
        @test df.REGIONID[1] == "VIC1"
        @test df.TOTALDEMAND[1] == 1000.0
    end

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
    end

    @testset "read_energy_bids" begin
        # Use 2025 to match mock data
        date_range = DateTime(2025, 1, 1, 0, 0):Dates.Minute(5):DateTime(2025, 1, 1, 1, 0)
        df = read_energy_bids(db, date_range)
        @test df isa DataFrame
        @test nrow(df) > 0
        @test "DUID" in names(df)
        @test "MAXAVAIL" in names(df)
        @test "BW01" in df.DUID
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
