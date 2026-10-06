@testset "RegionModel common" begin

    hive_dir = AEM_TEST_HIVE_DIR
    config = isempty(hive_dir) ? HiveConfiguration() : HiveConfiguration(hive_location = hive_dir, filesystem = "file")
    db = aem_connect(config)

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
        bus_df = AustralianElectricityMarkets.RegionModel.get_bus_dataframe(db)
        df = AustralianElectricityMarkets.RegionModel.get_load_dataframe(bus_df)
        @test df isa DataFrame
        @test "active_power" in names(df)
        @test "max_active_power" in names(df)
        @test nrow(df) == 6 # One load per region
    end

    @testset "get_branch_dataframe" begin
        bus_df = AustralianElectricityMarkets.RegionModel.get_bus_dataframe(db)
        df = AustralianElectricityMarkets.RegionModel.get_branch_dataframe(bus_df, read_interconnectors(db))
        @test df isa DataFrame
        @test "rate" in names(df)
        @test "bus_from" in names(df)
        @test "bus_to" in names(df)
        # 6 interconnectors + 6 gen-to-load internal branches = 12
        @test nrow(df) == 12
    end

    @testset "get_generators_dataframe" begin
        bus_df = AustralianElectricityMarkets.RegionModel.get_bus_dataframe(db)
        df = AustralianElectricityMarkets.RegionModel.get_generators_dataframe(bus_df, read_units(db))
        @test df isa DataFrame
        @test "technology" in names(df)
        @test "base_power" in names(df)
        @test "min_active_power" in names(df)
        @test "max_active_power" in names(df)
        @test nrow(df) == 6
    end

    @testset "get_batteries_dataframe" begin
        bus_df = AustralianElectricityMarkets.RegionModel.get_bus_dataframe(db)
        df = AustralianElectricityMarkets.RegionModel.get_batteries_dataframe(bus_df, read_units(db))
        @test df isa DataFrame
        @test "storage_capacity" in names(df)
        @test "efficiency" in names(df)
        # Our mock data has 1 battery (BW01/GEN1)
        @test nrow(df) == 1
        @test df.name[1] == "BW01"
        @test df.storage_capacity[1] == 200.0
        @test df.base_power[1] == 100.0
    end

    @testset "read_units keeps units without a GENUNITS row" begin
        units = read_units(db)
        # PUMP2 is a scheduled load with no GENUNITS/DUALLOC row, so no technology or fuel.
        pump2 = only(eachrow(subset(units, :DUID => ByRow(==("PUMP2")))))
        @test pump2.DISPATCHTYPE == "LOAD"
        @test ismissing(pump2.TECHNOLOGY)
        @test allunique(units.DUID)
    end

    @testset "read_units resolves a genset shared with a legacy DUALLOC DUID" begin
        # PUMP1's genset also maps to PUMP1_OLD, which sorts after it (as OSB01 after OSB-AG).
        pump1 = only(eachrow(subset(read_units(db), :DUID => ByRow(==("PUMP1")))))
        @test pump1.TECHNOLOGY == PrimeMovers.HY
    end

    @testset "get_scheduled_loads_dataframe" begin
        bus_df = AustralianElectricityMarkets.RegionModel.get_bus_dataframe(db)
        df = AustralianElectricityMarkets.RegionModel.get_scheduled_loads_dataframe(bus_df, read_units(db))
        @test sort(df.name) == ["PUMP1", "PUMP2", "WDR1"]
        @test all(==("NSW1"), df.region)
        @test all(==(100.0), df.base_power)
        @test all(==(1.0), df.max_active_power)
        # Without the DISPATCHTYPE column no load can be identified
        @test isempty(
            AustralianElectricityMarkets.RegionModel.get_scheduled_loads_dataframe(
                bus_df, select(read_units(db), Not(:DISPATCHTYPE)),
            )
        )
    end

    @testset "get_interfaces_dataframe" begin
        df = AustralianElectricityMarkets.RegionModel.get_interfaces_dataframe(read_interconnectors(db))
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

        # Check battery scaling (fix in a2b1f67)
        bat = get_component(EnergyReservoirStorage, system, "BW01")
        @test get_storage_capacity(bat) == 2.0 # 200.0 / 100.0

        # ER01 has deliberately asymmetric mock MAXRATEOFCHANGEUP=3.0/MAXRATEOFCHANGEDOWN=7.0
        # (REGISTEREDCAPACITY=100.0) - guards against up/down being crossed in get_generators_dataframe.
        thermal = get_component(ThermalStandard, system, "ER01")
        limits = get_ramp_limits(thermal)
        @test limits.up == 0.03 # 3.0 / 100.0
        @test limits.down == 0.07 # 7.0 / 100.0

        # The scheduled load PUMP1 is a controllable load with a market bid slot, in NSW1.
        pump = get_component(InterruptiblePowerLoad, system, "PUMP1")
        @test !isnothing(pump)
        @test get_name(get_area(get_bus(pump))) == "NSW1"
        @test get_operation_cost(pump) isa LoadCost
        @test length(get_components(InterruptiblePowerLoad, system)) == 3
        # A load with a GENUNITS row is not also a generator: its DUID names exactly one Device.
        @test get_component(Device, system, "PUMP1") isa InterruptiblePowerLoad
        @test isnothing(get_component(HydroDispatch, system, "PUMP1"))

        # Interconnectors/Interfaces
        @test length(get_components(AreaInterchange, system)) == 6
    end

    @testset "ISP technology coverage in PM_MAPPING" begin
        # AustralianElectricityMarketsData.read_isp_variable_opex/read_isp_fixed_opex return
        # raw isp_technology strings (that package does not depend on PowerSystems); the
        # PM_MAPPING lookup, used by RegionModel._map_primemover!, must have an entry for
        # every isp_technology value present in the bundled ISP2025 data.
        for tech in unique(vcat(read_isp_variable_opex().isp_technology, read_isp_fixed_opex().isp_technology))
            @test haskey(AustralianElectricityMarkets.PM_MAPPING, tech)
        end
    end

end
