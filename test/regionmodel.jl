@testset "Test RegionModel" begin

    required_tables = table_requirements(RegionalNetworkConfiguration())

    hive_dir = AEM_TEST_HIVE_DIR
    config = isempty(hive_dir) ? HiveConfiguration() : HiveConfiguration(hive_location = hive_dir, filesystem = "file")
    db = aem_connect(config)

    @testset "Table Requirements and Reading" begin
        map(
            required_tables
        ) do table
            if isempty(hive_dir)
                populate(db, table, Date(2025, 1, 1), Date(2025, 1, 1))
            end
            source = read_hive(db, table)
            df = AustralianElectricityMarkets._query(db, "SELECT * FROM $source LIMIT 5")
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

        # Interconnectors/Interfaces
        @test length(get_components(AreaInterchange, system)) == 6
    end

    @testset "ConstrainedNetworkConfiguration" begin
        start_date = DateTime(2025, 1, 1, 0, 0)
        date_range = start_date:Minute(5):(start_date + Hour(1))

        cnc_required_tables = table_requirements(ConstrainedNetworkConfiguration())
        @test :DISPATCH_FCAS_REQ in cnc_required_tables
        @test :DISPATCH_FCAS_REQ_CONSTRAINT in cnc_required_tables
        @test :DISPATCHCONSTRAINT in cnc_required_tables
        @test :GENCONDATA in cnc_required_tables
        @test :DISPATCHLOAD in cnc_required_tables
        @test :BIDPEROFFER_D in cnc_required_tables
        @test :SPDCONNECTIONPOINTCONSTRAINT in cnc_required_tables
        @test :SPDREGIONCONSTRAINT in cnc_required_tables
        @test :SPDINTERCONNECTORCONSTRAINT in cnc_required_tables

        sys = nem_system(db, ConstrainedNetworkConfiguration(); date_range = date_range)
        @test !isempty(collect(get_components(GenericConstraint, sys)))
        found = false
        for gen in get_components(Generator, sys)
            # has_time_series (not get_time_series + isnothing): get_time_series throws
            # ArgumentError, rather than returning nothing, for an owner with no metadata
            # registered at all - confirmed directly, same as "set_fcas_bids!" above. Series
            # name is "fcas_curve_<SERVICE>" per set_fcas_bids!, not "fcas_bid_<SERVICE>".
            has_time_series(gen, Deterministic, "fcas_curve_RAISE6SEC") || continue
            found = true
        end
        @test found

        # add_fcas_services! is wired in as ConstrainedNetworkConfiguration's third build
        # step - confirm it actually ran, not just that it's callable.
        @test !isempty(collect(get_components(FCASService, sys)))

        # attach_interconnector_losses! is wired in as the fourth build step - confirm at
        # least one AreaInterchange actually got its InterconnectorLossModel.
        has_loss_model = any(
            !isempty(get_supplemental_attributes(InterconnectorLossModel, ic))
                for ic in get_components(AreaInterchange, sys)
        )
        @test has_loss_model
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
