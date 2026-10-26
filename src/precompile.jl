using PrecompileTools: @compile_workload

function _precompile_workload()
    sys = PSY.System(100.0; time_series_in_memory = true, runchecks = false)
    bus = PSY.ACBus(;
        number = 1, name = "precompile_bus", available = true,
        bustype = PSY.ACBusTypes.REF, angle = 0.0, magnitude = 1.0,
        voltage_limits = (min = 0.9, max = 1.1), base_voltage = 220.0,
    )
    PSY.add_component!(sys, bus)
    generator = PSY.ThermalStandard(;
        name = "precompile_generator", available = true, status = true, bus,
        active_power = 0.0, reactive_power = 0.0, rating = 100.0,
        active_power_limits = (min = 0.0, max = 100.0), reactive_power_limits = nothing,
        ramp_limits = nothing, operation_cost = PSY.ThermalGenerationCost(nothing),
        base_power = 100.0,
    )
    PSY.add_component!(sys, generator)
    bids = DataFrame(;
        DUID = fill("precompile_generator", 2), DIRECTION = fill("GEN", 2),
        PRICEBANDARRAY = [collect(10.0:10.0:100.0) for _ in 1:2],
        BANDAVAILARRAY = [fill(10.0, 10) for _ in 1:2],
    )
    factors = DataFrame(;
        DUID = ["precompile_generator"], GEN_LOSS_FACTOR = [1.01], LOAD_LOSS_FACTOR = [1.02],
    )
    _set_referred_bid_curves!(bids, factors)
    _set_incremental_bid_cost!(sys, generator, bids, DateTime(2025, 1, 1), Minute(5))
    return get_energy_offer(generator, OfferSide.GEN)
end

# Exercise in-memory bid conversion and attachment only while creating the package cache.
@compile_workload begin
    _precompile_workload()
end
