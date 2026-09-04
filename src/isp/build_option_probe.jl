"""
Probe type for `test/isp_supplemental_attribute_probe.jl`: does a `PSY.SupplementalAttribute`
subtype defined in this package's **top-level** module (like [`FCASTrapezium`](@ref)) round-trip
through `System` JSON? A prior attempt at supplemental-attribute wiring (r2x) misbehaved and was
reverted, and a first probe defined in a test script (module `Main`) failed to deserialize for a
reason unrelated to supplemental attributes — `IS.get_module` cannot resolve `Main` at all. This
type isolates the real question by living where `ISPBuildOption` (see the ISP 2026 ingestion
spec's "Build economics" section) actually would.
"""
struct ISPBuildOptionProbe <: PSY.SupplementalAttribute
    build_cost::Float64
    internal::IS.InfrastructureSystemsInternal
end

function ISPBuildOptionProbe(;
        build_cost::Float64,
        internal::IS.InfrastructureSystemsInternal = IS.InfrastructureSystemsInternal(),
    )
    return ISPBuildOptionProbe(build_cost, internal)
end

IS.get_internal(v::ISPBuildOptionProbe) = v.internal
