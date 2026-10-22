@testset "EnergyTieBreak" begin
    @testset "keyword constructor and accessors" begin
        service = EnergyTieBreak(; name = "energy_tie_break")
        @test get_name(service) == "energy_tie_break"
        @test get_available(service)
        @test isempty(get_ext(service))
        set_available!(service, false)
        @test !get_available(service)
        @test !PowerSystems.supports_time_series(service)
    end

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
end
