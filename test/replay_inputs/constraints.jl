# The unavailable GenericConstraints decided by the replay inputs, on a mock NEM replay System whose constraints
# are added by hand. The writer is called directly; AEM only, no AEMSim.

const _CS_START = DateTime(2025, 1, 1, 0, 5)

# A NEM replay System on the mock hive: a date range of four series points, three of them replay intervals.
function _cs_mock_system()
    hive = mktempdir()
    create_mock_data(hive; complete_inputs = true)
    write_mock_interconnector_results(hive)
    db = aem_connect(HiveConfiguration(hive_location = hive))
    return nem_system(db, NEMDEConfiguration(); date_range = _CS_START:Minute(5):(_CS_START + Minute(20)))
end

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

@testset "constraint availability: never invoked, no available device, both, and ordinary" begin
    AEM = AustralianElectricityMarkets
    sys = _cs_mock_system()
    n = length(AEM._replay_interval_stamps(sys)) + 1
    units = [d for d in PowerSystems.get_components(PowerSystems.ThermalStandard, sys) if PowerSystems.get_available(d)]
    unit, other = units[1], units[2]
    before_last = [zeros(n - 1); 1.0]

    ordinary = _cs_add_constraint!(sys, "CS_ORDINARY", unit, fill(1.0, n))
    never = _cs_add_constraint!(sys, "CS_NEVER", unit, before_last)
    no_device = _cs_add_constraint!(sys, "CS_NO_DEVICE", other, fill(1.0, n))
    both = _cs_add_constraint!(sys, "CS_BOTH", other, before_last)
    PowerSystems.set_available!(other, false)

    AEM._set_constraint_availability!(sys)

    @test PowerSystems.get_available(ordinary)
    @test isnothing(_cs_reason(sys, "CS_ORDINARY"))
    @test !PowerSystems.get_available(never)
    @test _cs_reason(sys, "CS_NEVER") == :never_invoked
    @test !PowerSystems.get_available(no_device)
    @test _cs_reason(sys, "CS_NO_DEVICE") == :no_available_device
    @test !PowerSystems.get_available(both)
    @test _cs_reason(sys, "CS_BOTH") == :never_invoked
end

@testset "get_unavailable_constraints lists the rows sorted by name with their reasons" begin
    AEM = AustralianElectricityMarkets
    sys = _cs_mock_system()
    n = length(AEM._replay_interval_stamps(sys)) + 1
    unit = first(PowerSystems.get_components(PowerSystems.ThermalStandard, sys))
    _cs_add_constraint!(sys, "CS_B_NEVER", unit, [zeros(n - 1); 1.0])
    _cs_add_constraint!(sys, "CS_A_NEVER", unit, [zeros(n - 1); 1.0])
    AEM._set_constraint_availability!(sys)
    rows = AEM.get_unavailable_constraints(sys)
    names = rows.constraint
    @test issorted(names)
    @test all(c -> c in names, ["CS_A_NEVER", "CS_B_NEVER"])
    @test rows.reason[findfirst(==("CS_A_NEVER"), names)] == :never_invoked
    @test AEM.get_unavailable_constraints(sys) == rows
end

@testset "the unavailable constraints survive set_build_report! and get_build_report" begin
    AEM = AustralianElectricityMarkets
    sys = _cs_mock_system()
    n = length(AEM._replay_interval_stamps(sys)) + 1
    unit = first(PowerSystems.get_components(PowerSystems.ThermalStandard, sys))
    _cs_add_constraint!(sys, "CS_STORED", unit, [zeros(n - 1); 1.0])
    AEM._set_constraint_availability!(sys)
    report = AEM.get_build_report(sys)
    @test Dict{String, Any}("constraint" => "CS_STORED", "reason" => "never_invoked") in report.unavailable_constraints
    AEM.set_build_report!(sys, report)
    @test AEM.get_build_report(sys) == report
    @test AEM.NEMBuildReport(; unavailable_constraints = report.unavailable_constraints) != AEM.NEMBuildReport()
end
