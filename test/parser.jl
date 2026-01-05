using AustralianElectricityMarkets
using Test
using Mock
using Dates
using TidierDB
using DataFrames
using PowerSystems
using TimeSeries
using DuckDB
using Statistics

# Import internal functions for testing
using AustralianElectricityMarkets: _parse_hive_root, _filter_latest, _as_timearray, 
    _add_demand_ts_to_components!, _add_renewable_ts_to_components!, _extract_power_bids, _massage_bids

# Helper to setup mock DB
function setup_mock_db(dfs::Dict{Symbol, DataFrame})
    db = connect(DuckDB.DB())
    for (table_name, df) in dfs
        # Clean column names for DuckDB (no dots, etc if any, though here they should be fine)
        DuckDB.register_data_frame(db.handle, df, string(table_name))
    end
    return db
end

@testset "Parser Tests" begin

    @testset "Hive root parsing" begin
        local_config = AustralianElectricityMarkets.HiveConfiguration(hive_location = "/tmp/test", filesystem = "file")
        @test _parse_hive_root(local_config) == "/tmp/test"

        s3_config = AustralianElectricityMarkets.HiveConfiguration(hive_location = "my-bucket", filesystem = "s3")
        @test _parse_hive_root(s3_config) == "s3://my-bucket"
    end

    @testset "read_interconnectors" begin
        df_inter = DataFrame(
            INTERCONNECTORID = ["I1", "I1"],
            archive_month = [Date(2023, 1), Date(2023, 2)]
        )
        df_constraint = DataFrame(
            INTERCONNECTORID = ["I1", "I1", "I1"],
            EFFECTIVEDATE = [DateTime(2023, 1, 1), DateTime(2023, 1, 1), DateTime(2023, 2, 1)],
            VERSIONNO = [1, 2, 1],
            archive_month = [Date(2023, 1), Date(2023, 1), Date(2023, 2)],
            OTHER = ["A", "B", "C"]
        )
        
        db = setup_mock_db(Dict(:INTERCONNECTOR => df_inter, :INTERCONNECTORCONSTRAINT => df_constraint))
        
        mock_read_hive(db_conn, table_name; config=nothing) = TidierDB.dt(db_conn, string(table_name))
        
        with_mocked(read_hive => mock_read_hive) do
            res = read_interconnectors(db)
            @test nrow(res) == 1
            @test res.INTERCONNECTORID[1] == "I1"
            # Should pick latest archive_month (2023-02) then latest EFFECTIVEDATE and VERSIONNO
            # Wait, read_interconnectors filters latest archive_month for t_interconnector
            # then joins on INTERCONNECTORID and archive_month
            @test res.OTHER[1] == "C" 
        end
    end

    @testset "read_demand" begin
        df_demand = DataFrame(
            SETTLEMENTDATE = [DateTime(2023, 1, 1, 0, 1), DateTime(2023, 1, 1, 0, 2), DateTime(2023, 1, 1, 0, 6)],
            REGIONID = ["R1", "R1", "R1"],
            TOTALDEMAND = [10.0, 20.0, 30.0],
            SS_SOLAR_AVAILABILITY = [1.0, 2.0, 3.0],
            SS_WIND_AVAILABILITY = [4.0, 5.0, 6.0]
        )
        # Add a missing value to test dropmissing!
        push!(df_demand, [DateTime(2023, 1, 1, 0, 7), "R1", missing, 4.0, 7.0])
        
        db = setup_mock_db(Dict(:DISPATCHREGIONSUM => df_demand))
        mock_read_hive(db_conn, table_name; config=nothing) = TidierDB.dt(db_conn, string(table_name))
        
        with_mocked(read_hive => mock_read_hive) do
            # Default resolution 5 min
            res = read_demand(db)
            @test nrow(res) == 2 # 0:00-0:05 and 0:05-0:10
            @test res[res.SETTLEMENTDATE .== DateTime(2023, 1, 1, 0, 0), :TOTALDEMAND][1] == 15.0 # mean of 10 and 20
            @test res[res.SETTLEMENTDATE .== DateTime(2023, 1, 1, 0, 5), :TOTALDEMAND][1] == 30.0
        end
    end

    @testset "_filter_latest" begin
        df = DataFrame(ID = [1, 1, 2], val = [10, 20, 30], key = [Date(2023, 1), Date(2023, 2), Date(2023, 1)])
        db = setup_mock_db(Dict(:test_table => df))
        table = TidierDB.dt(db, "test_table")
        
        res = _filter_latest(table, :key) |> @collect
        @test nrow(res) == 1
        @test res.key[1] == Date(2023, 2)
        @test res.val[1] == 20
    end

    @testset "_as_timearray" begin
        df = DataFrame(
            time = [DateTime(2023, 1, 1), DateTime(2023, 1, 2)],
            name = ["A", "A"],
            val = [1.0, 2.0]
        )
        ta = _as_timearray(df, :time, :name, :val)
        @test ta isa TimeArray
        @test length(ta) == 2
        @test colnames(ta) == [:A]
    end

    @testset "read_units" begin
        df_dudetail = DataFrame(
            DUID = ["G1", "G1"],
            EFFECTIVEDATE = [DateTime(2023, 1, 1), DateTime(2023, 1, 1)],
            VERSIONNO = [1, 2],
            archive_month = [Date(2023, 1), Date(2023, 1)],
            STATIONID = ["S1", "S1"]
        )
        df_summary = DataFrame(
            DUID = ["G1"],
            START_DATE = [DateTime(2023, 1, 1)],
            END_DATE = [missing],
            archive_month = [Date(2023, 1)]
        )
        df_station = DataFrame(
            STATIONID = ["S1"],
            STATIONNAME = ["Station 1"],
            POSTCODE = ["1234"]
        )
        df_op_status = DataFrame(
            STATIONID = ["S1"],
            STATUS = ["COMMISSIONED"],
            EFFECTIVEDATE = [DateTime(2023, 1, 1)],
            VERSIONNO = [1],
            archive_month = [Date(2023, 1)]
        )
        df_genunits = DataFrame(
            GENSETID = ["GS1"],
            CO2E_ENERGY_SOURCE = ["Black coal"],
            CO2E_EMISSIONS_FACTOR = [0.9],
            archive_month = [Date(2023, 1)]
        )
        df_dualloc = DataFrame(
            DUID = ["G1"],
            GENSETID = ["GS1"],
            LASTCHANGED = [DateTime(2023, 1, 1)],
            VERSIONNO = [1],
            archive_month = [Date(2023, 1)]
        )
        
        db = setup_mock_db(Dict(
            :DUDETAIL => df_dudetail,
            :DUDETAILSUMMARY => df_summary,
            :STATION => df_station,
            :STATIONOPERATINGSTATUS => df_op_status,
            :GENUNITS => df_genunits,
            :DUALLOC => df_dualloc
        ))
        
        mock_read_hive(db_conn, table_name; config=nothing) = TidierDB.dt(db_conn, string(table_name))
        
        with_mocked(read_hive => mock_read_hive) do
            res = read_units(db)
            @test nrow(res) == 1
            @test res.DUID[1] == "G1"
            @test res.TECHNOLOGY[1] == PrimeMovers.ST
            @test res.FUELTYPE[1] == ThermalFuels.COAL
        end
    end

    @testset "set_demand!" begin
        # Create a mock system
        sys = System(100.0)
        area = Area("R1")
        add_component!(sys, area)
        bus = Bus(1, "Bus1", BusTypes.REF, nothing, nothing, nothing, area, nothing)
        add_component!(sys, bus)
        load = PowerLoad(name="R1 Load", available=true, bus=bus, model=LoadModels.ConstantPower, active_power=1.0, reactive_power=0.1, base_power=100.0, max_active_power=2.0, max_reactive_power=0.2)
        add_component!(sys, load)

        df_demand = DataFrame(
            SETTLEMENTDATE = [DateTime(2023, 1, 1, 0, 0), DateTime(2023, 1, 1, 0, 5)],
            REGIONID = ["R1", "R1"],
            TOTALDEMAND = [10.0, 20.0],
            SS_SOLAR_AVAILABILITY = [0.0, 0.0],
            SS_WIND_AVAILABILITY = [0.0, 0.0]
        )
        
        # We need to mock read_demand
        mock_read_demand(db; kwargs...) = df_demand
        
        with_mocked(read_demand => mock_read_demand) do
            set_demand!(sys, nothing, DateTime(2023, 1, 1, 0, 0):Minute(5):DateTime(2023, 1, 1, 0, 10))
            # Verify TS added
            @test has_time_series(load)
            ts = get_time_series_all(SingleTimeSeries, load)
            @test length(ts) == 1
        end
    end

    @testset "set_renewable_pv!" begin
        sys = System(100.0)
        area = Area("R1")
        add_component!(sys, area)
        bus = Bus(1, "Bus1", BusTypes.REF, nothing, nothing, nothing, area, nothing)
        add_component!(sys, bus)
        gen = RenewableDispatch(
            name="PV1",
            available=true,
            bus=bus,
            active_power=1.0,
            reactive_power=0.1,
            rating=2.0,
            prime_mover_type=PrimeMovers.PVe,
            base_power=100.0,
            max_active_power=2.0,
            max_reactive_power=0.2
        )
        add_component!(sys, gen)

        df_demand = DataFrame(
            SETTLEMENTDATE = [DateTime(2023, 1, 1, 0, 0), DateTime(2023, 1, 1, 0, 5)],
            REGIONID = ["R1", "R1"],
            TOTALDEMAND = [10.0, 20.0],
            SS_SOLAR_AVAILABILITY = [0.5, 1.0],
            SS_WIND_AVAILABILITY = [0.0, 0.0]
        )
        
        mock_read_demand(db; kwargs...) = df_demand
        
        with_mocked(read_demand => mock_read_demand) do
            set_renewable_pv!(sys, nothing, DateTime(2023, 1, 1, 0, 0):Minute(5):DateTime(2023, 1, 1, 0, 10))
            @test has_time_series(gen)
        end
    end

    @testset "set_renewable_wind!" begin
        sys = System(100.0)
        area = Area("R1")
        add_component!(sys, area)
        bus = Bus(1, "Bus1", BusTypes.REF, nothing, nothing, nothing, area, nothing)
        add_component!(sys, bus)
        gen = RenewableDispatch(
            name="Wind1",
            available=true,
            bus=bus,
            active_power=1.0,
            reactive_power=0.1,
            rating=2.0,
            prime_mover_type=PrimeMovers.WT,
            base_power=100.0,
            max_active_power=2.0,
            max_reactive_power=0.2
        )
        add_component!(sys, gen)

        df_demand = DataFrame(
            SETTLEMENTDATE = [DateTime(2023, 1, 1, 0, 0), DateTime(2023, 1, 1, 0, 5)],
            REGIONID = ["R1", "R1"],
            TOTALDEMAND = [10.0, 20.0],
            SS_SOLAR_AVAILABILITY = [0.0, 0.0],
            SS_WIND_AVAILABILITY = [0.5, 1.0]
        )
        
        mock_read_demand(db; kwargs...) = df_demand
        
        with_mocked(read_demand => mock_read_demand) do
            set_renewable_wind!(sys, nothing, DateTime(2023, 1, 1, 0, 0):Minute(5):DateTime(2023, 1, 1, 0, 10))
            @test has_time_series(gen)
        end
    end

    @testset "Bids Processing" begin
        df_energy = DataFrame(
            SETTLEMENTDATE = [DateTime(2023, 1, 1), DateTime(2023, 1, 1)],
            INTERVAL_DATETIME = [DateTime(2023, 1, 1, 0, 5), DateTime(2023, 1, 1, 0, 5)],
            DUID = ["G1", "G1"],
            DIRECTION = ["TRADE", "TRADE"],
            MAXAVAIL = [100.0, 100.0],
            VERSIONNO = [1, 2],
            BIDTYPE = ["ENERGY", "ENERGY"],
            BANDAVAIL1 = [10.0, 10.0],
            BANDAVAIL2 = [20.0, 20.0],
            BANDAVAIL3 = [0.0, 0.0],
            BANDAVAIL4 = [0.0, 0.0],
            BANDAVAIL5 = [0.0, 0.0],
            BANDAVAIL6 = [0.0, 0.0],
            BANDAVAIL7 = [0.0, 0.0],
            BANDAVAIL8 = [0.0, 0.0],
            BANDAVAIL9 = [0.0, 0.0],
            BANDAVAIL10 = [0.0, 0.0]
        )
        df_price = DataFrame(
            SETTLEMENTDATE = [DateTime(2023, 1, 1), DateTime(2023, 1, 1)],
            DUID = ["G1", "G1"],
            DIRECTION = ["TRADE", "TRADE"],
            VERSIONNO = [1, 2],
            BIDTYPE = ["ENERGY", "ENERGY"],
            MINIMUMLOAD = [0.0, 0.0],
            DAILYENERGYCONSTRAINT = [1000.0, 1000.0],
            PRICEBAND1 = [10.0, 11.0],
            PRICEBAND2 = [20.0, 21.0],
            PRICEBAND3 = [30.0, 31.0],
            PRICEBAND4 = [0.0, 0.0],
            PRICEBAND5 = [0.0, 0.0],
            PRICEBAND6 = [0.0, 0.0],
            PRICEBAND7 = [0.0, 0.0],
            PRICEBAND8 = [0.0, 0.0],
            PRICEBAND9 = [0.0, 0.0],
            PRICEBAND10 = [0.0, 0.0]
        )
        
        db = setup_mock_db(Dict(:BIDPEROFFER_D => df_energy, :BIDDAYOFFER_D => df_price))
        mock_read_hive(db_conn, table_name; kwargs...) = TidierDB.dt(db_conn, string(table_name))
        
        with_mocked(read_hive => mock_read_hive) do
            bids = _massage_bids(TidierDB.dt(db, "BIDPEROFFER_D"), TidierDB.dt(db, "BIDDAYOFFER_D"), DateTime(2023, 1, 1), DateTime(2023, 1, 1, 1))
            @test nrow(bids) == 1
            @test bids.VERSIONNO[1] == 2
            @test bids.PRICEBANDARRAY[1][1] == 11.0
            
            # Test set_market_bids!
            sys = System(100.0)
            bus = Bus(nothing)
            add_component!(sys, bus)
            gen = ThermalStandard(name="G1", available=true, bus=bus, active_power=1.0, reactive_power=0.1, rating=2.0, prime_mover_type=PrimeMovers.ST, fuel=ThermalFuels.COAL, base_power=100.0, active_power_limits=(min=0.0, max=2.0), reactive_power_limits=nothing, ramp_limits=nothing, time_limits=nothing, operation_cost=ThreePartCost(nothing))
            add_component!(sys, gen)
            
            set_market_bids!(sys, db, DateTime(2023, 1, 1):Minute(5):DateTime(2023, 1, 1, 0, 10))
            @test get_available(gen)
        end
    end

    @testset "_extract_power_bids" begin
        row = (
            PRICEBANDARRAY = [10.0, 20.0, 30.0],
            BANDAVAILARRAY = [100.0, 200.0, 0.0]
        )
        psd = _extract_power_bids(row)
        @test psd.x == [0.0, 100.0, 300.0]
        @test psd.y == [10.0, 20.0]
    end

    @testset "TS attachment helpers" begin
        sys = System(100.0)
        area = Area("R1")
        add_component!(sys, area)
        bus = Bus(1, "Bus1", BusTypes.REF, nothing, nothing, nothing, area, nothing)
        add_component!(sys, bus)
        load = PowerLoad(name="R1 Load", available=true, bus=bus, model=LoadModels.ConstantPower, active_power=1.0, reactive_power=0.1, base_power=100.0, max_active_power=2.0, max_reactive_power=0.2)
        add_component!(sys, load)

        ta = TimeArray([DateTime(2023, 1, 1)], [10.0], [:name])
        # Rename column to match load name
        ta = TimeArray(timestamp(ta), values(ta), [Symbol("R1 Load")])
        
        _add_demand_ts_to_components!(sys, ta, PowerLoad)
        @test has_time_series(load)
    end
end
