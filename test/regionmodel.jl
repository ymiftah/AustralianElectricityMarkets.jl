@testset "Test RegionModel" begin

    required_tables = table_requirements(RegionalNetworkConfiguration())

    hive_dir = AEM_TEST_HIVE_DIR
    config = isempty(hive_dir) ? HiveConfiguration() : HiveConfiguration(hive_location = hive_dir, filesystem = "file")
    db = aem_connect(duckdb(), config)

    @testset "Table Requirements and Reading" begin
        map(
            required_tables
        ) do table
            if isempty(hive_dir)
                fetch_table_data(table, Date(2025, 1, 1):Date(2025, 1, 1))
            end
            df = read_hive(db, table) |> x -> (
                TidierDB.@collect(
                    TidierDB.@head(
                        x, 5
                    )
                )
            )
            @test nrow(df) == 5
        end
    end

    @testset "get_bus_dataframe" begin
        df = AustralianElectricityMarkets.RegionModel.get_bus_dataframe(db)
        @test df isa DataFrame
        @test "region" in names(df)
        @test "bustype" in names(df)
        @test "name" in names(df)
        @test nrow(df) == 12 # 6 regions * 2 (Gen + Load)
        @test all(contains(AustralianElectricityMarkets.RegionModel.GEN_SUFFIX), df.name[1:6])
        @test all(contains(AustralianElectricityMarkets.RegionModel.LOAD_SUFFIX), df.name[7:12])
    end

    @testset "get_load_dataframe" begin
        df = AustralianElectricityMarkets.RegionModel.get_load_dataframe(db)
        @test df isa DataFrame
        @test "active_power" in names(df)
        @test "max_active_power" in names(df)
        @test nrow(df) == 6 # One load per region
    end

    @testset "get_branch_dataframe" begin
        df = AustralianElectricityMarkets.RegionModel.get_branch_dataframe(db)
        @test df isa DataFrame
        @test "rate" in names(df)
        @test "bus_from" in names(df)
        @test "bus_to" in names(df)
        # 6 interconnectors + 6 gen-to-load internal branches = 12
        @test nrow(df) == 12
    end

    @testset "get_generators_dataframe" begin
        df = AustralianElectricityMarkets.RegionModel.get_generators_dataframe(db)
        @test df isa DataFrame
        @test "technology" in names(df)
        @test "base_power" in names(df)
        @test "min_active_power" in names(df)
        @test "max_active_power" in names(df)
        @test nrow(df) == 6
    end

    @testset "get_batteries_dataframe" begin
        df = AustralianElectricityMarkets.RegionModel.get_batteries_dataframe(db)
        @test df isa DataFrame
        @test "storage_capacity" in names(df)
        @test "efficiency" in names(df)
        # Our mock data has 1 battery (BW01/GEN1)
        @test nrow(df) == 1
        @test df.name[1] == "BW01"
    end

    @testset "get_interfaces_dataframe" begin
        df = AustralianElectricityMarkets.RegionModel.get_interfaces_dataframe(db)
        @test df isa DataFrame
        @test "from_area" in names(df)
        @test "to_area" in names(df)
        @test "available" in names(df)
        @test nrow(df) == 6
        # Check Snowy availability logic
        snowy_rows = df[(df.from_area .== "SNOWY1") .| (df.to_area .== "SNOWY1"), :]
        @test all(snowy_rows.available .== false)
    end

    @testset "nem_system" begin
        system = nem_system(db, RegionalNetworkConfiguration())
        @test system isa System

        areas = get_components(Area, system) |> collect .|> get_name |> sort!
        @test areas == ["NSW1", "QLD1", "SA1", "SNOWY1", "TAS1", "VIC1"]

        # 6 Regions * 2 Buses = 12
        @test length(get_components(ACBus, system)) == 12

        # 6 loads
        @test length(get_components(PowerLoad, system)) == 6

        # Generators: 6 total in mock data.
        # BW01 is Battery
        # BW02 is Hydro
        # BW03 is Solar (RenewableDispatch)
        # BW04 is Wind (RenewableDispatch)
        # ER01, ER02 are ThermalStandard
        @test length(get_components(ThermalStandard, system)) == 2
        @test length(get_components(HydroDispatch, system)) == 1
        @test length(get_components(EnergyReservoirStorage, system)) == 1
        @test length(get_components(RenewableDispatch, system)) == 2

        # Interconnectors/Interfaces
        @test length(get_components(AreaInterchange, system)) == 6
    end

end
