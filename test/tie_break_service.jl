@testset "EnergyTieBreak" begin
    @testset "JSON round-trip keeps the service and its contributors" begin
        sys = System(100.0)
        bus = ACBus(; number = 1, name = "b1", available = true, bustype = ACBusTypes.REF, angle = 0.0, magnitude = 1.0, voltage_limits = (min = 0.9, max = 1.1), base_voltage = 130.0)
        add_component!(sys, bus)
        for name in ("G1", "G2")
            gen = ThermalStandard(;
                name = name, available = true, status = true, bus = bus,
                active_power = 0.0, reactive_power = 0.0, rating = 1.0,
                active_power_limits = (min = 0.0, max = 1.0), reactive_power_limits = nothing,
                ramp_limits = nothing,
                operation_cost = ThermalGenerationCost(;
                    variable = CostCurve(LinearCurve(0.0)), fixed = 0.0, start_up = 0.0, shut_down = 0.0,
                ),
                base_power = 100.0, time_limits = nothing, must_run = false,
                prime_mover_type = PrimeMovers.ST, fuel = ThermalFuels.COAL,
            )
            add_component!(sys, gen)
        end
        add_service!(sys, EnergyTieBreak(; name = "energy_tie_break"), collect(get_components(ThermalStandard, sys)))

        json_path = joinpath(mktempdir(), "sys.json")
        to_json(sys, json_path)
        sys2 = System(json_path)

        service = get_component(EnergyTieBreak, sys2, "energy_tie_break")
        @test service isa EnergyTieBreak
        @test get_available(service)
        @test sort!(get_name.(get_contributing_devices(sys2, service))) == ["G1", "G2"]
    end

    @testset "set_tie_break_scales! output survives a JSON round-trip" begin
        sys = System(100.0)
        area = Area(; name = "NSW")
        add_component!(sys, area)
        bus = ACBus(; number = 1, name = "b1", available = true, bustype = ACBusTypes.REF, angle = 0.0, magnitude = 1.0, voltage_limits = (min = 0.9, max = 1.1), base_voltage = 130.0)
        add_component!(sys, bus)
        set_area!(bus, area)
        start = DateTime(2025, 1, 1)
        # Both units have a price-10 band and a price-20 band; the widths differ at price 10 (5 vs 2) and at 20 (10 vs 13).
        curves = Dict("G1" => PiecewiseStepData([0.0, 5.0, 15.0], [10.0, 20.0]), "G2" => PiecewiseStepData([0.0, 2.0, 15.0], [10.0, 20.0]))
        for (name, curve) in curves
            gen = ThermalStandard(;
                name = name, available = true, status = true, bus = bus,
                active_power = 0.0, reactive_power = 0.0, rating = 1.0,
                active_power_limits = (min = 0.0, max = 1.0), reactive_power_limits = nothing,
                ramp_limits = nothing,
                operation_cost = ThermalGenerationCost(;
                    variable = CostCurve(LinearCurve(0.0)), fixed = 0.0, start_up = 0.0, shut_down = 0.0,
                ),
                base_power = 100.0, time_limits = nothing, must_run = false,
                prime_mover_type = PrimeMovers.ST, fuel = ThermalFuels.COAL,
            )
            add_component!(sys, gen)
            # Whole-valued costs deserialise as integers and fail to rebuild the MarketBidCost.
            set_operation_cost!(gen, MarketBidCost(; no_load_cost = 0.5, start_up = (hot = 0.0, warm = 0.0, cold = 0.0), shut_down = 0.25))
            series = AustralianElectricityMarkets.single_series("variable_cost", start, fill(curve, 2), Minute(5))
            set_incremental_variable_cost!(sys, gen, series, UnitSystem.NATURAL_UNITS)
        end

        set_tie_break_scales!(sys)
        g1, g2 = get_component(ThermalStandard, sys, "G1"), get_component(ThermalStandard, sys, "G2")
        @test get_time_series_values(SingleTimeSeries, g1, "tie_break_scale_1") ≈ [1.0, 1.0]
        @test get_time_series_values(SingleTimeSeries, g2, "tie_break_scale_1") ≈ [0.4, 0.4]
        @test get_time_series_values(SingleTimeSeries, g1, "tie_break_scale_2") ≈ [10.0 / 13.0, 10.0 / 13.0]
        @test get_time_series_values(SingleTimeSeries, g2, "tie_break_scale_2") ≈ [1.0, 1.0]

        json_path = joinpath(mktempdir(), "sys.json")
        to_json(sys, json_path)
        sys2 = System(json_path)

        service = get_component(EnergyTieBreak, sys2, "energy_tie_break")
        @test sort!(get_name.(get_contributing_devices(sys2, service))) == ["G1", "G2"]
        @test get_time_series_values(SingleTimeSeries, get_component(ThermalStandard, sys2, "G2"), "tie_break_scale_1") ≈ [0.4, 0.4]
        @test get_time_series_values(SingleTimeSeries, get_component(ThermalStandard, sys2, "G1"), "tie_break_scale_2") ≈ [10.0 / 13.0, 10.0 / 13.0]
    end
end
