# The mock fixture's one `HydroDispatch` unit (`BW02`) has a static `MINCAPACITY` floor of 10 MW
# (`DUDETAIL`) that exceeds the ceiling `set_hydro_limits!` derives from its `BIDPEROFFER_D`
# `MAXAVAIL` for this interval — a genuine box-constraint contradiction (min > max) that makes
# every `HydroDispatchRunOfRiver`-templated interval infeasible regardless of tier. Lowering the
# floor to 0 here (fixture-local, not touching `mock_data.jl` or `src/parser.jl`) resolves it
# without changing what the rest of the suite exercises.
function _fix_hydro_floor!(sys)
    for hydro in get_components(HydroDispatch, sys)
        limits = get_active_power_limits(hydro)
        set_active_power_limits!(hydro, (min = 0.0, max = limits.max))
    end
    return
end

@testset "T0 copper plate solves via PowerSimulations.jl" begin
    db = aem_connect(HiveConfiguration(hive_location = AEM_TEST_HIVE_DIR, filesystem = "file"))
    sys = nem_system(db, RegionalNetworkConfiguration())
    _fix_hydro_floor!(sys)
    inputs = read_interval_inputs(db, DateTime(2025, 1, 1, 0, 5, 0))

    result = solve_interval(T0CopperPlate(), sys, db, inputs; optimizer = HiGHS.Optimizer)

    @test result.status == :optimal
    @test result.tier == "T0"
    @test !isempty(result.dispatch)
    @test !isempty(result.prices)
    @test all(isfinite, values(result.prices))
end

@testset "T1 interconnected solves with per-region prices" begin
    db = aem_connect(HiveConfiguration(hive_location = AEM_TEST_HIVE_DIR, filesystem = "file"))
    sys = nem_system(db, RegionalNetworkConfiguration())
    _fix_hydro_floor!(sys)
    inputs = read_interval_inputs(db, DateTime(2025, 1, 1, 0, 5, 0))

    result = solve_interval(T1Interconnected(), sys, db, inputs; optimizer = HiGHS.Optimizer)

    @test result.status == :optimal
    @test result.tier == "T1"
    @test length(result.prices) >= 1
    @test all(isfinite, values(result.prices))
end
