# Probe: can an externally-defined SupplementalAttribute subtype round-trip through
# System JSON? Decides how ISPBuildOption is stored (see the ISP 2026 ingestion spec).
#
# A first version of this probe defined its type locally in this test script (module `Main`)
# and failed to deserialize — but that failure was `IS.get_module` being unable to resolve
# `Main` at all, unrelated to supplemental attributes (see this repo's CLAUDE.md: "PSY
# component types that get serialized must live in the top-level module"). This probe instead
# uses `ISPBuildOptionProbe`, defined in `src/isp/build_option_probe.jl` inside the
# `AustralianElectricityMarkets` top-level module — the same place `FCASTrapezium` lives —
# which is the configuration that actually answers the question. `runtests.jl`'s `using
# AustralianElectricityMarkets` brings the exported `ISPBuildOptionProbe` into scope here.
#
# Each fallible step is asserted with `@test`/`@test_throws` rather than left as a bare
# statement: a bare exception inside a top-level `@testset` here would abort `Pkg.test()`
# before later testsets (e.g. Aqua) run, masking unrelated regressions on this branch.
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

    attr = ISPBuildOptionProbe(; build_cost = 1234.5)

    # (a) constructible and addable.
    @test begin
        add_supplemental_attribute!(sys, gen, attr)
        true
    end

    path = joinpath(mktempdir(), "probe.json")
    # (b) to_json.
    @test begin
        to_json(sys, path)
        true
    end

    # (c) deserialization, including the association back to its owning component.
    sys2 = nothing
    gen2 = nothing
    attrs = ISPBuildOptionProbe[]
    @test begin
        sys2 = System(path)
        gen2 = get_component(ThermalStandard, sys2, "gen1")
        # `get_supplemental_attributes(::Type{T}, component)` is the real 2-arg PSY/IS
        # signature — there is no 3-arg `(Type, System, component)` method.
        attrs = get_supplemental_attributes(ISPBuildOptionProbe, gen2)
        true
    end

    @test length(attrs) == 1
    @test only(attrs).build_cost == 1234.5
end
