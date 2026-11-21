@testset "RegionModel common" begin
    db = aem_connect(HiveConfiguration(hive_location = AEM_TEST_HIVE_DIR, filesystem = "file"))

    @testset "get_bus_dataframe" begin
        df = AustralianElectricityMarkets.RegionModel.get_bus_dataframe(db, MOCK_DATE_RANGE)
        @test nrow(df) == 12 # 6 regions * 2 (Gen + Load)
        @test all(contains(AustralianElectricityMarkets.RegionModel.GEN_SUFFIX), df.name[1:6])
        @test all(contains(AustralianElectricityMarkets.RegionModel.LOAD_SUFFIX), df.name[7:12])
    end

    @testset "get_branch_dataframe" begin
        bus_df = AustralianElectricityMarkets.RegionModel.get_bus_dataframe(db, MOCK_DATE_RANGE)
        df = AustralianElectricityMarkets.RegionModel.get_branch_dataframe(bus_df, read_interconnectors(db, MOCK_DATE_RANGE))
        # 6 interconnectors + 6 gen-to-load internal branches = 12
        @test nrow(df) == 12
    end

    @testset "get_batteries_dataframe" begin
        bus_df = AustralianElectricityMarkets.RegionModel.get_bus_dataframe(db, MOCK_DATE_RANGE)
        df = AustralianElectricityMarkets.RegionModel.get_batteries_dataframe(bus_df, read_units(db, MOCK_DATE_RANGE))
        # Our mock data has 1 battery (BW01/GEN1)
        @test nrow(df) == 1
        @test df.name[1] == "BW01"
        @test df.storage_capacity[1] == 200.0
        @test df.base_power[1] == 100.0
    end

    @testset "generator unit of a battery registered as separate generator and load units" begin
        RM = AustralianElectricityMarkets.RegionModel
        bus_df = RM.get_bus_dataframe(db, MOCK_DATE_RANGE)
        units = read_units(db, MOCK_DATE_RANGE)
        # BW02 as the generator half of a split battery: a battery energy source, no storage data.
        units.CO2E_ENERGY_SOURCE = [d == "BW02" ? "Battery Storage" : s for (d, s) in zip(units.DUID, units.CO2E_ENERGY_SOURCE)]
        gen_df = RM.get_generators_dataframe(bus_df, units)
        @test gen_df.legacy_battery == (gen_df.name .== "BW02")
        for legacy_batteries in (false, true)
            sys = System(100.0)
            RM._add_buses!(sys, bus_df)
            RM._add_generation!(sys, gen_df; legacy_batteries)
            bw02 = get_component(Device, sys, "BW02")
            @test isnothing(bw02) == !legacy_batteries
            legacy_batteries && @test bw02 isa ThermalStandard && get_prime_mover_type(bw02) == PrimeMovers.BA
            @test isnothing(get_component(Device, sys, "BW01"))  # a bidirectional unit is a storage, not a generator
        end
    end

    @testset "read_units keeps units without a GENUNITS row" begin
        units = read_units(db, MOCK_DATE_RANGE)
        # PUMP2 is a scheduled load with no GENUNITS/DUALLOC row, so no technology or fuel.
        pump2 = only(eachrow(subset(units, :DUID => ByRow(==("PUMP2")))))
        @test pump2.DISPATCHTYPE == "LOAD"
        @test ismissing(pump2.CO2E_ENERGY_SOURCE)
        @test allunique(units.DUID)
    end

    @testset "read_units resolves a genset shared with a legacy DUALLOC DUID" begin
        # PUMP1's genset also maps to PUMP1_OLD, which sorts after it (as OSB01 after OSB-AG).
        pump1 = only(eachrow(subset(read_units(db, MOCK_DATE_RANGE), :DUID => ByRow(==("PUMP1")))))
        @test pump1.CO2E_ENERGY_SOURCE == "Hydro"
    end

    @testset "get_scheduled_loads_dataframe" begin
        bus_df = AustralianElectricityMarkets.RegionModel.get_bus_dataframe(db, MOCK_DATE_RANGE)
        df = AustralianElectricityMarkets.RegionModel.get_scheduled_loads_dataframe(bus_df, read_units(db, MOCK_DATE_RANGE))
        @test sort(df.name) == ["ASLOAD1", "ASLOAD2", "PUMP1", "PUMP2", "WDR1"]
        # Non-scheduled loads are built unavailable: they carry no energy bid and are only
        # switched on by an FCAS offer.
        @test Dict(df.name .=> df.scheduled) == Dict(
            "PUMP1" => true, "PUMP2" => true, "WDR1" => true, "ASLOAD1" => false, "ASLOAD2" => false,
        )
        @test df.available == df.scheduled
        @test all(==("NSW1"), df.region)
        @test all(==(100.0), df.base_power)
        @test all(==(1.0), df.max_active_power)
    end

    @testset "get_interfaces_dataframe" begin
        df = AustralianElectricityMarkets.RegionModel.get_interfaces_dataframe(read_interconnectors(db, MOCK_DATE_RANGE))
        @test nrow(df) == 6
        # Check Snowy availability logic
        snowy_rows = df[(df.from_area .== "SNOWY1") .| (df.to_area .== "SNOWY1"), :]
        @test all(snowy_rows.available .== false)
    end

    # One regional system, read-only for the two testsets below.
    regional = nem_system(db, RegionalNetworkConfiguration(); date_range = MOCK_DATE_RANGE)

    @testset "nem_system" begin
        system = regional

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
        @test length.(get_components.((ThermalStandard, HydroDispatch, EnergyReservoirStorage, RenewableDispatch), Ref(system))) == (2, 1, 1, 2)

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
        @test get_name(get_area(get_bus(pump))) == "NSW1"
        @test get_operation_cost(pump) isa LoadCost
        @test length(get_components(InterruptiblePowerLoad, system)) == 5
        asload = get_component(InterruptiblePowerLoad, system, "ASLOAD1")
        @test !get_available(asload)
        @test get_ext(asload)["non_scheduled"] === true
        @test !haskey(get_ext(pump), "non_scheduled")
        # A load with a GENUNITS row is not also a generator: its DUID names exactly one Device.
        @test get_component(Device, system, "PUMP1") isa InterruptiblePowerLoad
        @test !has_nem_unit_data(get_component(Device, system, "PUMP1"))

        # Interconnectors/Interfaces
        @test length(get_components(AreaInterchange, system)) == 6
    end

    @testset "regional system carries the ISP operating costs" begin
        # Values from the ISP cost fill on this mock data, captured before the network builder
        # was split from the cost fill. Units of the mock data: fuel in AUD/GJ, O&M in AUD/MWh.
        sys = regional
        thermal = get_operation_cost(get_component(ThermalStandard, sys, "ER01"))
        fuel = get_variable(thermal)
        @test get_proportional_term(get_value_curve(fuel)) ≈ 9.26
        @test get_constant_term(get_value_curve(fuel)) ≈ 648.0
        # ER01 keeps its station's own Eraring coal price (7.02 AUD/GJ, Step Change 2025-26), not a technology median.
        @test get_fuel_cost(fuel) ≈ 7.02
        @test get_proportional_term(get_vom_cost(fuel)) ≈ 8.0
        @test get_fixed(thermal) ≈ 319.634703196347
        @test get_start_up(thermal) == 100.0
        @test get_shut_down(thermal) == 100.0

        hydro = get_operation_cost(get_component(HydroDispatch, sys, "BW02"))
        @test get_proportional_term(get_value_curve(get_variable(hydro))) ≈ 8.0
        @test get_fixed(hydro) ≈ 319.634703196347

        renewable = get_operation_cost(get_component(RenewableDispatch, sys, "BW03"))
        @test get_proportional_term(get_value_curve(get_variable(renewable))) ≈ 8.0
        @test get_fixed(renewable) ≈ 319.634703196347
    end

    @testset "ISP technology coverage in PM_MAPPING" begin
        # The ISP readers return
        # raw isp_technology strings (that package does not depend on PowerSystems); the
        # PM_MAPPING lookup, used by RegionModel._map_primemover!, must have an entry for
        # every isp_technology value present in the bundled ISP2025 data.
        technologies = unique(vcat(read_isp_variable_opex().isp_technology, read_isp_fixed_opex().isp_technology))
        @test isempty(filter(!in(keys(AustralianElectricityMarkets.PM_MAPPING)), technologies))
    end

end
