using PrecompileTools: @compile_workload

function _precompile_workload()
    sys = PSY.System(100.0; time_series_in_memory = true, runchecks = false)
    bus = PSY.ACBus(;
        number = 1, name = "precompile_bus", available = true,
        bustype = PSY.ACBusTypes.REF, angle = 0.0, magnitude = 1.0,
        voltage_limits = (min = 0.9, max = 1.1), base_voltage = 220.0,
    )
    PSY.add_component!(sys, bus)
    generator = NEMThermalGen(;
        name = "precompile_generator", available = true, status = true, bus,
        active_power = 0.0, reactive_power = 0.0, rating = 100.0,
        active_power_limits = (min = 0.0, max = 100.0), reactive_power_limits = nothing,
        ramp_limits = nothing, operation_cost = NEMOfferCost(),
        base_power = 100.0,
    )
    PSY.add_component!(sys, generator)
    stamps = [DateTime(2025, 1, 1, 0, 5), DateTime(2025, 1, 1, 0, 10)]
    rows = DataFrame(;
        DUID = fill("precompile_generator", 2), DIRECTION = fill("GEN", 2), INTERVAL_DATETIME = stamps,
        PRICEBANDARRAY = [collect(10.0:10.0:100.0) for _ in 1:2],
        BANDAVAILARRAY = [fill(10.0, 10) for _ in 1:2], MAXAVAIL = [100.0, 100.0],
        ROCUP = [1.0, 1.0], ROCDOWN = [1.0, 1.0], FIXEDLOAD = [missing, missing],
        MINIMUMLOAD = [0.0, 0.0], DAILYENERGYCONSTRAINT = [missing, missing],
        T1 = [missing, missing], T2 = [missing, missing], T3 = [missing, missing], T4 = [missing, missing],
        NORMALSTATUS = ["ON", "ON"], ENERGYLIMIT = [missing, missing],
    )
    grid = [DateTime(2025, 1, 1, 0, 5), DateTime(2025, 1, 1, 0, 10)]
    _write_energy_bid!(sys, generator, BidDirection.GEN, rows, grid, first(grid), Minute(5))
    return nothing
end

# Exercise in-memory bid conversion and attachment only while creating the package cache.
@compile_workload begin
    _precompile_workload()
end
