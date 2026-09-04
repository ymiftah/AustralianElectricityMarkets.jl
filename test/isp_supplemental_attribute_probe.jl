# Probe: can an externally-defined SupplementalAttribute subtype round-trip through
# System JSON? Decides how ISPBuildOption is stored (see the ISP 2026 ingestion spec).
#
# `test/runtests.jl` does only `using PowerSystems`, so the PSY/IS aliases this file needs
# are imported here rather than assumed.
import PowerSystems as PSY
import InfrastructureSystems as IS

struct _ProbeBuildOption <: PSY.SupplementalAttribute
    build_cost::Float64
    internal::IS.InfrastructureSystemsInternal
end

function _ProbeBuildOption(;
        build_cost::Float64,
        internal::IS.InfrastructureSystemsInternal = IS.InfrastructureSystemsInternal(),
    )
    return _ProbeBuildOption(build_cost, internal)
end

IS.get_internal(v::_ProbeBuildOption) = v.internal
IS.get_uuid(v::_ProbeBuildOption) = IS.get_uuid(v.internal)

@testset "SupplementalAttribute round-trip probe" begin
    sys = System(100.0)
    # Keyword form, matching `_add_buses!` in src/network_models/region_model.jl — the
    # positional field order is not part of PSY's public contract.
    bus = ACBus(;
        number = 1, name = "bus1", bustype = ACBusTypes.REF, angle = 0.0, magnitude = 1.0,
        voltage_limits = (min = 0.9, max = 1.1), base_voltage = 230.0, available = true,
    )
    add_component!(sys, bus)
    gen = ThermalStandard(;
        name = "gen1", available = true, status = true, bus = bus,
        active_power = 1.0, reactive_power = 0.0, rating = 1.0,
        active_power_limits = (min = 0.0, max = 1.0), reactive_power_limits = nothing,
        ramp_limits = nothing, operation_cost = ThermalGenerationCost(nothing),
        base_power = 100.0, time_limits = nothing,
    )
    add_component!(sys, gen)

    attr = _ProbeBuildOption(; build_cost = 1234.5)
    add_supplemental_attribute!(sys, gen, attr)

    path = joinpath(mktempdir(), "probe.json")
    to_json(sys, path)
    sys2 = System(path)
    gen2 = get_component(ThermalStandard, sys2, "gen1")
    attrs = get_supplemental_attributes(_ProbeBuildOption, sys2, gen2)

    @test length(attrs) == 1
    @test only(attrs).build_cost == 1234.5
end
