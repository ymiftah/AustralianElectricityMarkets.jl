@testset "run requires complete inputs before model construction" begin
    sys = System(100.0; time_series_in_memory = true)
    set_build_report!(
        sys,
        NEMBuildReport(;
            skipped_constraints = [
                Dict{String, Any}(
                    "constraint" => "N_MISSING@2025-01-01#1", "reason" => "no_definition", "missing" => String[],
                ),
            ],
        ),
    )
    @test_throws r"incomplete.*N_MISSING" problem_template(sys)

    set_build_report!(
        sys,
        NEMBuildReport(;
            dropped_terms = [
                Dict{String, Any}(
                    "constraint" => "N_PARTIAL@2025-01-01#1", "kind" => "UNIT", "key" => "MISSING_DUID",
                    "bid_type" => "ENERGY", "factor" => 1.0,
                ),
            ],
        ),
    )
    @test_throws r"incomplete.*MISSING_DUID" problem_template(sys)

    set_build_report!(sys, NEMBuildReport(; defaulted_constraint_weights = ["N_NULL_WEIGHT@2025-01-01#1"]))
    @test_throws r"NULL GENERICCONSTRAINTWEIGHT: N_NULL_WEIGHT.*force_new = true" problem_template(sys)
end

@testset "a dispatch device without its dispatch-limit series cannot run" begin
    db = aem_connect(HiveConfiguration(hive_location = AEM_TEST_NEMDE_HIVE_DIR))
    interval = DateTime(2025, 1, 1, 0, 5):Minute(5):DateTime(2025, 1, 1, 0, 15)
    sys, _ = constrained_system(db; date_range = interval)
    @test_throws r"incomplete dispatch inputs for .*; build sys with nem_system" problem_template(sys)
end

# One regional system: read by the fixed-load test, then made unavailable by the MNSP test.
const _RI_REGIONAL = nem_system(aem_connect(HiveConfiguration(hive_location = AEM_TEST_HIVE_DIR)), RegionalNetworkConfiguration())

@testset "fixed loads retain the dispatch variable's direction" begin
    sys = _RI_REGIONAL
    t = DateTime(2025, 1, 1, 0, 5)
    rows = DataFrame(INTERVAL_DATETIME = [t, t], DUID = ["PUMP1", "BW01"], DIRECTION = ["LOAD", "LOAD"], FIXEDLOAD = [30.0, 5.0])
    targets = AustralianElectricityMarkets._fixed_load_series(sys, rows)
    by_key = Dict((r.DUID, r.INTERVAL_DATETIME) => r.TARGET for r in eachrow(targets))
    @test by_key[("PUMP1", t)] == 30.0
    @test by_key[("BW01", t)] == -5.0
    @test !haskey(by_key, ("PUMP1", t + Minute(5)))
end

@testset "an MNSP cannot enter the regulated formulation without its offers" begin
    sys = _RI_REGIONAL
    # With every dispatch device unavailable, the template reaches the MNSP check.
    foreach(d -> set_available!(d, false), AustralianElectricityMarkets.nem_dispatch_devices(sys))
    @test_throws r"IC2.*MNSP" problem_template(sys)
end

@testset "a cached table without the requested interval cannot be read" begin
    db = aem_connect(HiveConfiguration(hive_location = AEM_TEST_HIVE_DIR))
    later = DateTime(2030, 1, 1):Minute(5):DateTime(2030, 1, 1, 0, 10)
    @test_throws r"BIDPEROFFER_D has no cached partition for 2029-12, 2030-01" constrained_system(db; date_range = later)
end

@testset "a unit registered mid-chunk passes the problem template" begin
    # BW02 is registered from 00:10 of the NEMDE hive, so it is built for the whole chunk.
    t = "TIMESTAMP '2025-01-01 00:10:00'"
    hive = AEM_TEST_NEMDE_HIVE_DIR
    for (table, query) in [
            (:DUDETAILSUMMARY, "UPDATE input SET START_DATE = $t WHERE DUID = 'BW02'"),
            (:DUDETAIL, "UPDATE input SET EFFECTIVEDATE = $t WHERE DUID = 'BW02'"),
            (:BIDPEROFFER_D, "DELETE FROM input WHERE DUID = 'BW02' AND INTERVAL_DATETIME <= $t"),
            (:DISPATCHLOAD, "DELETE FROM input WHERE DUID = 'BW02' AND SETTLEMENTDATE <= $t"),
        ]
        hive = damaged_cache(hive, table, query).config.hive_location
    end
    db = aem_connect(HiveConfiguration(hive_location = hive))
    interval = DateTime(2025, 1, 1, 0, 5):Minute(5):DateTime(2025, 1, 1, 0, 20)
    sys = nem_system(db, NEMDEConfiguration(); date_range = interval)
    @test !isnothing(get_component(Generator, sys, "BW02"))
    @test_nowarn problem_template(sys)
end

@testset "a vacuous constraint's dropped term fails the NEMDE inputs check only for a registered unit" begin
    constraint = "N_VACUOUS@2025-01-01#1"
    term(registered::Bool) = Dict{String, Any}(
        "constraint" => constraint, "kind" => "UNIT", "key" => "GONE_DUID", "bid_type" => "ENERGY",
        "factor" => 1.0, "registered" => registered,
    )
    skipped = [Dict{String, Any}("constraint" => constraint, "reason" => "vacuous_unknown_duid", "missing" => ["GONE_DUID"])]
    sys = System(100.0; time_series_in_memory = true)
    set_build_report!(sys, NEMBuildReport(; skipped_constraints = skipped, dropped_terms = [term(true)]))
    err = try
        AEMS._check_nemde_constraint_inputs(sys)
        nothing
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin(constraint, err.msg) && occursin("GONE_DUID", err.msg)
    set_build_report!(sys, NEMBuildReport(; skipped_constraints = skipped, dropped_terms = [term(false)]))
    @test isnothing(AEMS._check_nemde_constraint_inputs(sys))
end

@testset "constraint-build records are judged only for the constraints in the template's scope" begin
    # `N_ENERGY` is energy-only, so `template_fcas` leaves it out and `template_nemde` judges it.
    sys = fcas_toy_system(;
        extra! = (sys, stamps) -> begin
            gc = GenericConstraint(; name = "N_ENERGY", sense = ConstraintSense.LE, rhs = 50.0, terms = ConstraintTerm[UnitTerm(TOY_CHEAP, BidType.ENERGY, 1.0)])
            PSY.add_service!(sys, gc, [PSY.get_component(ThermalStandard, sys, TOY_CHEAP)])
            add_toy_constraint_series!(sys, gc, stamps, fill(50.0, length(stamps)), fill(1.0, length(stamps)))
            return
        end,
    )
    dropped = Dict{String, Any}(
        "constraint" => "N_ENERGY", "kind" => "UNIT", "key" => "GONE_DUID", "bid_type" => "ENERGY",
        "factor" => 1.0, "registered" => true,
    )
    set_build_report!(sys, NEMBuildReport(; dropped_terms = [dropped]))
    @test problem_template(sys; template = template_fcas()) isa PSI.ProblemTemplate
    @test_throws r"incomplete constraint terms: N_ENERGY.*GONE_DUID" problem_template(sys; template = template_nemde())
    @test_throws r"incomplete constraint terms: N_ENERGY.*GONE_DUID" AEMS._check_nemde_constraint_inputs(sys)

    set_build_report!(sys, NEMBuildReport(; defaulted_constraint_weights = ["N_ENERGY"]))
    @test problem_template(sys; template = template_fcas()) isa PSI.ProblemTemplate
    @test_throws r"NULL GENERICCONSTRAINTWEIGHT: N_ENERGY" problem_template(sys; template = template_nemde())
end
