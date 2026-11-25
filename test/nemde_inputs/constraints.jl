# The unavailable GenericConstraints decided by the NEMDE inputs, on a mock NEM run System whose constraints
# are added by hand. The writer is called directly; AEM only, no AEMSim.

const _CS_START = DateTime(2025, 1, 1, 0, 5)

# A NEM run System on the mock hive: a date range of four series points, three of them dispatch intervals.
const _CS_SYS = nemde_test_system()

# Adds the constraint `name` on `device`, its invoked series holding `invoked` at each series point.
function _cs_add_constraint!(sys, name::AbstractString, device, invoked::Vector{Float64})
    AEM = AustralianElectricityMarkets
    gc = GenericConstraint(; name, sense = ConstraintSense.LE, rhs = 1.0)
    AEM._add_nem_service!(sys, gc, [device])
    PowerSystems.add_time_series!(
        sys, gc, AEM.single_series(AEM.NEM_CONSTRAINT_SERIES.invoked, _CS_START, invoked, Minute(5)),
    )
    gc.invoked = AEM._series_key(gc, AEM.NEM_CONSTRAINT_SERIES.invoked)
    return gc
end

# The recorded reason of the constraint `name`, or `nothing` when it is available.
function _cs_reason(sys, name::AbstractString)
    rows = AustralianElectricityMarkets.get_unavailable_constraints(sys)
    i = findfirst(==(name), rows.constraint)
    return isnothing(i) ? nothing : rows.reason[i]
end

@testset "constraint availability: never invoked, no available device, both, static flags and ordinary" begin
    AEM = AustralianElectricityMarkets
    sys = deepcopy(_CS_SYS)
    n = length(AEM._dispatch_interval_stamps(sys)) + 1
    units = [d for d in PowerSystems.get_components(PowerSystems.ThermalStandard, sys) if PowerSystems.get_available(d)]
    unit, other = units[1], units[2]
    before_last = [zeros(n - 1); 1.0]

    ordinary = _cs_add_constraint!(sys, "CS_ORDINARY", unit, fill(1.0, n))
    never = _cs_add_constraint!(sys, "CS_NEVER", unit, before_last)
    no_device = _cs_add_constraint!(sys, "CS_NO_DEVICE", other, fill(1.0, n))
    both = _cs_add_constraint!(sys, "CS_BOTH", other, before_last)
    # A static invoked flag decides never_invoked without a series.
    static_on = GenericConstraint(; name = "CS_STATIC_ON", sense = ConstraintSense.LE, rhs = 1.0, invoked = true)
    static_off = GenericConstraint(; name = "CS_STATIC_OFF", sense = ConstraintSense.LE, rhs = 1.0, invoked = false)
    foreach(gc -> AEM._add_nem_service!(sys, gc, [unit]), (static_on, static_off))
    PowerSystems.set_available!(other, false)

    AEM._set_constraint_availability!(sys)

    cases = (
        ordinary => nothing, never => :never_invoked, no_device => :no_available_device, both => :never_invoked,
        static_on => nothing, static_off => :never_invoked,
    )
    @test [_cs_reason(sys, PowerSystems.get_name(gc)) for (gc, _) in cases] == [reason for (_, reason) in cases]
    @test [PowerSystems.get_available(gc) for (gc, _) in cases] == [isnothing(reason) for (_, reason) in cases]
    @test issorted(AEM.get_unavailable_constraints(sys).constraint)

    # The unavailable constraints are recorded in the build report.
    recorded = AEM.get_build_report(sys).unavailable_constraints
    @test only(filter(:constraint => ==("CS_NEVER"), recorded).reason) == "never_invoked"
end

@testset "the contributing-device index matches get_contributing_devices for every constraint" begin
    sys = _CS_SYS
    index = AustralianElectricityMarkets._contributing_device_index(sys)
    constraints = collect(PowerSystems.get_components(GenericConstraint, sys))
    @test !isempty(constraints)
    @test all(constraints) do gc
        expected = Set(PowerSystems.get_name.(PowerSystems.get_contributing_devices(sys, gc)))
        return Set(PowerSystems.get_name.(get(index, PowerSystems.IS.get_uuid(gc), PowerSystems.Device[]))) == expected
    end
end
