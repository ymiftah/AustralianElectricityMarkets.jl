using DataFrames: DataFrame, nrow

function _append_test_hive_rows(hive_root::String, table::Symbol, rows::DataFrame)
    conn = DuckDB.connect(DuckDB.DB())
    DuckDB.register_data_frame(conn, rows, "test_rows")
    table_dir = joinpath(hive_root, string(table))
    for archive_month in unique(rows.archive_month)
        partition_dir = joinpath(table_dir, "archive_month=$archive_month")
        mkpath(partition_dir)
        output_path = joinpath(partition_dir, "heywood_fixture.parquet")
        DuckDB.execute(
            conn,
            "COPY (SELECT * EXCLUDE (archive_month) FROM test_rows WHERE archive_month = '$archive_month') TO '$output_path' (FORMAT PARQUET)",
        )
    end
    DuckDB.unregister_table(conn, "test_rows")
    DuckDB.disconnect(conn)
    return nothing
end

# A hand-built model with realistic NEMDE magnitudes: LOSSCONSTANT is a loss *factor*, so it sits
# near 1.0, and the mock hive's 0.01 is deliberately not reused here - the closed forms below are
# checked against numbers a real interconnector would carry.
const TEST_LOSS_MODEL = InterconnectorLossModel(;
    interconnector = "IC_TEST", from_region = "VIC1", to_region = "NSW1",
    from_region_loss_share = 0.4, loss_constant = 1.02, loss_flow_coefficient = 2.0e-4,
    demand_coefficients = Dict("VIC1" => 1.0e-5, "NSW1" => -2.0e-5),
    breakpoints = [-500.0, -250.0, 0.0, 250.0, 500.0],
)
const TEST_DEMAND = Dict("VIC1" => 4000.0, "NSW1" => 7000.0)

@testset "AEM owns loss assumptions" begin
    for year in 2021:2026
        date = Date(year, 7, 1)
        assumptions = interconnector_loss_assumptions(date)
        @test assumptions.financial_year == year
        @test occursin("$(year)-", assumptions.report.url)
        @test assumptions.curve_reference == :zero_flow
        @test assumptions.directional_allocation == :sending_terminal
    end
    @test interconnector_loss_assumptions(Date(2022, 1, 1)).financial_year == 2021
    @test interconnector_loss_assumptions(Date(2022, 1, 1)).report !== nothing
    for year in 2022:2026
        @test interconnector_loss_assumptions(Date(year, 6, 30)).financial_year == year - 1
    end
    @test interconnector_loss_assumptions(Date(2025, 6, 30)).financial_year == 2024
    @test interconnector_loss_assumptions(Date(2027, 7, 1)).report === nothing
    @test isempty(interconnector_loss_assumptions(Date(2027, 7, 1)).corrections)
    @test length(interconnector_loss_assumptions(Date(2025, 7, 1)).corrections) == 1
    @test isempty(interconnector_loss_assumptions(Date(2026, 7, 1)).corrections)
    @test interconnector_loss_allocation(TEST_LOSS_MODEL) == :static_share
    @test interconnector_loss_allocation(TEST_LOSS_MODEL; directional_offers = true) == :sending_terminal
    @test isempty(get_loss_model_provenance(TEST_LOSS_MODEL))

    model = InterconnectorLossModel(;
        interconnector = "QNI", from_region = "NSW1", to_region = "QLD1",
        from_region_loss_share = 0.5, loss_constant = 1.0, loss_flow_coefficient = 0.00017965,
        demand_coefficients = Dict{String, Float64}(), breakpoints = [-17.0, 17.0],
    )
    @test loss_curve_vertex_values(model, Dict()) ≈ [0.0, 0.0] atol = 1.0e-12
end

@testset "loss_factor" begin
    # 1.02 + 2e-4 * flow + (1e-5 * 4000 + -2e-5 * 7000) = 1.02 + 2e-4 * flow - 0.1
    @test loss_factor(TEST_LOSS_MODEL, 0.0, TEST_DEMAND) ≈ 0.92
    @test loss_factor(TEST_LOSS_MODEL, 500.0, TEST_DEMAND) ≈ 1.02
    # A region with a coefficient but no demand entry contributes nothing rather than erroring.
    @test loss_factor(TEST_LOSS_MODEL, 0.0, Dict("VIC1" => 4000.0)) ≈ 1.06
end

@testset "documented Heywood NSW demand coefficient" begin
    function coefficient_rows(; date = DateTime(2025, 7, 1), version = 1, regions = ["VIC1", "SA1"], values = [-1.4896e-5, 5.108e-5])
        return DataFrame(
            INTERCONNECTORID = fill("V-SA", length(regions)),
            EFFECTIVEDATE = fill(date, length(regions)),
            VERSIONNO = fill(version, length(regions)),
            REGIONID = regions,
            DEMANDCOEFFICIENT = values,
        )
    end

    function parameter_rows(; date = DateTime(2025, 7, 1), version = 1, interconnector = "V-SA", loss_constant = 0.9721, loss_flow_coefficient = 0.00026801)
        return DataFrame(
            INTERCONNECTORID = [interconnector], EFFECTIVEDATE = [date], VERSIONNO = [version],
            LOSSCONSTANT = [loss_constant], LOSSFLOWCOEFFICIENT = [loss_flow_coefficient],
        )
    end

    documented_coefficients = coefficient_rows()
    documented_parameters = parameter_rows()

    before_start = AustralianElectricityMarkets._interconnector_demand_coefficients_by_id(
        documented_coefficients,
        documented_parameters,
        Date(2025, 6, 30),
    )
    @test !haskey(before_start["V-SA"], "NSW1")

    at_start = AustralianElectricityMarkets._interconnector_demand_coefficients_by_id(
        documented_coefficients,
        documented_parameters,
        Date(2025, 7, 1),
    )
    @test at_start["V-SA"]["NSW1"] == 1.6981e-6

    at_start_instant = AustralianElectricityMarkets._interconnector_demand_coefficients_by_id(
        documented_coefficients,
        documented_parameters,
        DateTime(2025, 7, 1, 0, 0, 0),
    )
    @test at_start_instant["V-SA"]["NSW1"] == 1.6981e-6

    last_active_day = AustralianElectricityMarkets._interconnector_demand_coefficients_by_id(
        documented_coefficients,
        documented_parameters,
        Date(2026, 6, 30),
    )
    @test last_active_day["V-SA"]["NSW1"] == 1.6981e-6

    last_active_instant = AustralianElectricityMarkets._interconnector_demand_coefficients_by_id(
        documented_coefficients,
        documented_parameters,
        DateTime(2026, 6, 30, 23, 59, 59),
    )
    @test last_active_instant["V-SA"]["NSW1"] == 1.6981e-6

    stale_after_end = AustralianElectricityMarkets._interconnector_demand_coefficients_by_id(
        documented_coefficients,
        documented_parameters,
        Date(2026, 7, 1),
    )
    @test !haskey(stale_after_end["V-SA"], "NSW1")

    stale_at_end_instant = AustralianElectricityMarkets._interconnector_demand_coefficients_by_id(
        documented_coefficients,
        documented_parameters,
        DateTime(2026, 7, 1, 0, 0, 0),
    )
    @test !haskey(stale_at_end_instant["V-SA"], "NSW1")

    wrong_version = AustralianElectricityMarkets._interconnector_demand_coefficients_by_id(
        coefficient_rows(; version = 2),
        parameter_rows(; version = 2),
        Date(2025, 7, 1),
    )
    @test !haskey(wrong_version["V-SA"], "NSW1")

    wrong_parameter_version = AustralianElectricityMarkets._interconnector_demand_coefficients_by_id(
        documented_coefficients,
        parameter_rows(; version = 2),
        Date(2025, 7, 1),
    )
    @test !haskey(wrong_parameter_version["V-SA"], "NSW1")

    wrong_interconnector = AustralianElectricityMarkets._interconnector_demand_coefficients_by_id(
        DataFrame(
            INTERCONNECTORID = replace.(documented_coefficients.INTERCONNECTORID, "V-SA" => "OTHER"),
            EFFECTIVEDATE = documented_coefficients.EFFECTIVEDATE,
            VERSIONNO = documented_coefficients.VERSIONNO,
            REGIONID = documented_coefficients.REGIONID,
            DEMANDCOEFFICIENT = documented_coefficients.DEMANDCOEFFICIENT,
        ),
        parameter_rows(; interconnector = "OTHER"),
        Date(2025, 7, 1),
    )
    @test !haskey(wrong_interconnector["OTHER"], "NSW1")

    wrong_parameters = AustralianElectricityMarkets._interconnector_demand_coefficients_by_id(
        documented_coefficients,
        parameter_rows(; loss_constant = 0.9722),
        Date(2025, 7, 1),
    )
    @test !haskey(wrong_parameters["V-SA"], "NSW1")

    wrong_flow_coefficient = AustralianElectricityMarkets._interconnector_demand_coefficients_by_id(
        documented_coefficients,
        parameter_rows(; loss_flow_coefficient = 0.00026802),
        Date(2025, 7, 1),
    )
    @test !haskey(wrong_flow_coefficient["V-SA"], "NSW1")

    intraday_parameters = AustralianElectricityMarkets._interconnector_demand_coefficients_by_id(
        documented_coefficients,
        parameter_rows(; date = DateTime(2025, 7, 1, 0, 5, 0)),
        Date(2025, 7, 1),
    )
    @test !haskey(intraday_parameters["V-SA"], "NSW1")

    wrong_regional_coefficients = AustralianElectricityMarkets._interconnector_demand_coefficients_by_id(
        coefficient_rows(; values = [-1.0e-5, 5.108e-5]),
        documented_parameters,
        Date(2025, 7, 1),
    )
    @test !haskey(wrong_regional_coefficients["V-SA"], "NSW1")

    explicit_zero = AustralianElectricityMarkets._interconnector_demand_coefficients_by_id(
        coefficient_rows(; regions = ["VIC1", "SA1", "NSW1"], values = [-1.4896e-5, 5.108e-5, 0.0]),
        documented_parameters,
        Date(2025, 7, 1),
    )
    @test explicit_zero["V-SA"]["NSW1"] == 0.0

    explicit_value = AustralianElectricityMarkets._interconnector_demand_coefficients_by_id(
        coefficient_rows(; regions = ["VIC1", "SA1", "NSW1"], values = [-1.4896e-5, 5.108e-5, 7.5e-7]),
        documented_parameters,
        Date(2025, 7, 1),
    )
    @test explicit_value["V-SA"]["NSW1"] == 7.5e-7

    hive_root = mktempdir()
    create_mock_data(hive_root)
    _append_test_hive_rows(
        hive_root,
        :INTERCONNECTOR,
        DataFrame(
            INTERCONNECTORID = ["V-SA"], REGIONFROM = ["VIC1"], REGIONTO = ["SA1"],
            archive_month = ["2025-07"],
        ),
    )
    _append_test_hive_rows(
        hive_root,
        :INTERCONNECTORCONSTRAINT,
        DataFrame(
            INTERCONNECTORID = fill("V-SA", 3),
            EFFECTIVEDATE = [DateTime(2024, 7, 1), DateTime(2025, 7, 1), DateTime(2026, 7, 1)], VERSIONNO = [1, 1, 1],
            FROMREGIONLOSSSHARE = fill(0.8192, 3), LOSSCONSTANT = [0.9936, 0.9721, 0.9742],
            LOSSFLOWCOEFFICIENT = [0.00022992, 0.00026801, 0.000229], ICTYPE = fill("AC", 3),
            archive_month = ["2024-07", "2025-07", "2026-06"],
        ),
    )
    _append_test_hive_rows(
        hive_root,
        :LOSSMODEL,
        DataFrame(
            INTERCONNECTORID = fill("V-SA", 9),
            EFFECTIVEDATE = repeat([DateTime(2024, 7, 1), DateTime(2025, 7, 1), DateTime(2026, 7, 1)]; inner = 3),
            VERSIONNO = ones(Int, 9), LOSSSEGMENT = repeat(collect(1:3), 3),
            MWBREAKPOINT = repeat([-500.0, 0.0, 500.0], 3),
            archive_month = repeat(["2024-07", "2025-07", "2026-06"]; inner = 3),
        ),
    )
    _append_test_hive_rows(
        hive_root, :LOSSFACTORMODEL,
        DataFrame(
            INTERCONNECTORID = fill("V-SA", 2), EFFECTIVEDATE = fill(DateTime(2024, 7, 1), 2),
            VERSIONNO = ones(Int, 2), REGIONID = ["VIC1", "SA1"],
            DEMANDCOEFFICIENT = [-1.6267e-5, 6.2183e-5], archive_month = fill("2024-07", 2),
        ),
    )
    # Annual equations from AEMO's FY2021-22, FY2022-23 and FY2023-24 MLF reports, §3.
    historical_equations = (
        (2021, 1.0121, 3.5511e-4, -4.5341e-7, -6.1623e-6),
        (2022, 1.0181, 3.5925e-4, -3.4191e-6, 1.8182e-8),
        (2023, 1.0166, 3.4263e-4, -1.2753e-6, -1.5712e-6),
    )
    for (year, constant, flow, vic, sa) in historical_equations
        effective_date = DateTime(year, 7, 1)
        archive_month = "$(year)-07"
        _append_test_hive_rows(
            hive_root, :INTERCONNECTORCONSTRAINT,
            DataFrame(
                INTERCONNECTORID = ["V-SA"], EFFECTIVEDATE = [effective_date], VERSIONNO = [1],
                FROMREGIONLOSSSHARE = [0.8192], LOSSCONSTANT = [constant],
                LOSSFLOWCOEFFICIENT = [flow], ICTYPE = ["AC"], archive_month = [archive_month],
            ),
        )
        _append_test_hive_rows(
            hive_root, :LOSSMODEL,
            DataFrame(
                INTERCONNECTORID = fill("V-SA", 3), EFFECTIVEDATE = fill(effective_date, 3),
                VERSIONNO = ones(Int, 3), LOSSSEGMENT = collect(1:3),
                MWBREAKPOINT = [-500.0, 0.0, 500.0], archive_month = fill(archive_month, 3),
            ),
        )
        _append_test_hive_rows(
            hive_root, :LOSSFACTORMODEL,
            DataFrame(
                INTERCONNECTORID = fill("V-SA", 2), EFFECTIVEDATE = fill(effective_date, 2),
                VERSIONNO = ones(Int, 2), REGIONID = ["VIC1", "SA1"],
                DEMANDCOEFFICIENT = [vic, sa], archive_month = fill(archive_month, 2),
            ),
        )
    end
    vsa_2025_coefficients = copy(documented_coefficients)
    vsa_2025_coefficients.archive_month = fill("2025-07", nrow(vsa_2025_coefficients))
    _append_test_hive_rows(hive_root, :LOSSFACTORMODEL, vsa_2025_coefficients)
    _append_test_hive_rows(
        hive_root,
        :LOSSFACTORMODEL,
        DataFrame(
            INTERCONNECTORID = fill("V-SA", 3), EFFECTIVEDATE = fill(DateTime(2026, 7, 1), 3),
            VERSIONNO = ones(Int, 3), REGIONID = ["VIC1", "SA1", "NSW1"],
            DEMANDCOEFFICIENT = [-1.09e-5, 6.63e-5, -2.22e-6],
            archive_month = fill("2026-06", 3),
        ),
    )
    db = aem_connect(HiveConfiguration(hive_location = hive_root, filesystem = "file"))

    for (year, constant, flow, vic, sa) in historical_equations
        first_date = year == 2021 ? Date(2022, 1, 1) : Date(year, 7, 1)
        for date in (first_date, Date(year + 1, 6, 30))
            model = interconnector_loss_models(db, date)["V-SA"]
            @test model.loss_constant == constant
            @test model.loss_flow_coefficient == flow
            @test model.demand_coefficients == Dict("VIC1" => vic, "SA1" => sa)
            provenance = get_loss_model_provenance(model)
            @test provenance["financial_year"] == year
            @test isempty(provenance["corrections"])
            @test occursin("$(year)-", provenance["report"]["url"])
        end
    end

    model_2024 = interconnector_loss_models(db, Date(2024, 7, 1))["V-SA"]
    @test model_2024.loss_constant == 0.9936
    @test model_2024.loss_flow_coefficient == 0.00022992
    @test model_2024.demand_coefficients == Dict("VIC1" => -1.6267e-5, "SA1" => 6.2183e-5)
    @test isempty(get_loss_model_provenance(model_2024)["corrections"])
    @test interconnector_loss_models(db, Date(2025, 6, 30))["V-SA"].demand_coefficients == model_2024.demand_coefficients

    public_rows = read_interconnector_demand_coefficients(db, Date(2025, 7, 1))
    @test Set(names(public_rows)) == Set(["INTERCONNECTORID", "REGIONID", "DEMANDCOEFFICIENT"])
    @test !any((public_rows.INTERCONNECTORID .== "V-SA") .& (public_rows.REGIONID .== "NSW1"))

    model_2025 = interconnector_loss_models(db, Date(2025, 7, 1))["V-SA"]
    provenance = get_loss_model_provenance(model_2025)
    @test provenance["financial_year"] == 2025
    @test provenance["tables"]["LOSSFACTORMODEL"]["effective_date"] == "2025-07-01T00:00:00"
    @test provenance["tables"]["LOSSMODEL"]["version_no"] == 1
    @test only(provenance["corrections"])["region"] == "NSW1"
    @test only(provenance["corrections"])["value"] == 1.6981e-6
    @test occursin("2025-26", only(provenance["corrections"])["source"])
    pu_model = AustralianElectricityMarkets._to_pu(model_2025, 100.0)
    @test get_loss_model_provenance(pu_model) == provenance
    provenance["financial_year"] = 0
    @test get_loss_model_provenance(model_2025)["financial_year"] == 2025
    @test model_2025.loss_constant == 0.9721
    @test model_2025.loss_flow_coefficient == 0.00026801
    @test model_2025.demand_coefficients["NSW1"] == 1.6981e-6
    @test loss_factor(model_2025, 0.0, Dict("NSW1" => 10_000.0)) ≈ 0.9721 + 0.016981

    model_2026 = interconnector_loss_models(db, Date(2026, 7, 1))["V-SA"]
    @test isempty(get_loss_model_provenance(model_2026)["corrections"])
    @test model_2026.demand_coefficients["NSW1"] == -2.22e-6
    @test model_2026.loss_constant == 0.9742
    @test interconnector_loss_models(db, Date(2026, 10, 1))["V-SA"].loss_constant == 0.9742

    # This synthetic effective date deliberately differs from the report's anticipated October transition.
    transition = DateTime(2026, 11, 15)
    _append_test_hive_rows(
        hive_root, :INTERCONNECTORCONSTRAINT,
        DataFrame(
            INTERCONNECTORID = ["V-SA"], EFFECTIVEDATE = [transition], VERSIONNO = [2],
            FROMREGIONLOSSSHARE = [0.8192], LOSSCONSTANT = [1.0288], LOSSFLOWCOEFFICIENT = [0.000257],
            ICTYPE = ["AC"], archive_month = ["2026-11"],
        ),
    )
    _append_test_hive_rows(
        hive_root, :LOSSFACTORMODEL,
        DataFrame(
            INTERCONNECTORID = fill("V-SA", 3), EFFECTIVEDATE = fill(transition, 3), VERSIONNO = fill(2, 3),
            REGIONID = ["VIC1", "SA1", "NSW1"], DEMANDCOEFFICIENT = [-1.27e-5, 3.44e-5, 1.0e-7],
            archive_month = fill("2026-11", 3),
        ),
    )
    before_transition = interconnector_loss_models(db, transition - Second(1))["V-SA"]
    after_transition = interconnector_loss_models(db, transition)["V-SA"]
    @test before_transition.loss_constant == 0.9742
    @test after_transition.loss_constant == 1.0288
    @test after_transition.demand_coefficients["NSW1"] == 1.0e-7
    @test isempty(get_loss_model_provenance(after_transition)["corrections"])
    @test get_loss_model_provenance(after_transition)["tables"]["INTERCONNECTORCONSTRAINT"]["version_no"] == 2
    @test get_loss_model_provenance(after_transition)["tables"]["LOSSMODEL"]["version_no"] == 1
end

@testset "interconnector_losses" begin
    # (loss_factor(0) - 1) * f + 0.5 * loss_flow_coefficient * f^2
    @test interconnector_losses(TEST_LOSS_MODEL, 0.0, TEST_DEMAND) ≈ 0.0
    @test interconnector_losses(TEST_LOSS_MODEL, 500.0, TEST_DEMAND) ≈
        -0.08 * 500.0 + 0.5 * 2.0e-4 * 500.0^2
    # Quadratic, so reverse flow is not the negative of forward flow.
    @test interconnector_losses(TEST_LOSS_MODEL, -500.0, TEST_DEMAND) ≉
        -interconnector_losses(TEST_LOSS_MODEL, 500.0, TEST_DEMAND)
end

@testset "loss_segments" begin
    segments = loss_segments(TEST_LOSS_MODEL, TEST_DEMAND)
    @test length(segments) == length(TEST_LOSS_MODEL.breakpoints) - 1
    @test first(segments).from_mw == -500.0
    @test last(segments).to_mw == 500.0
    # Contiguous: each segment starts where the previous ended.
    @test all(segments[i].to_mw == segments[i + 1].from_mw for i in 1:(length(segments) - 1))

    # The chord slopes are exact at every breakpoint: accumulating them from the first breakpoint
    # must reproduce the quadratic there, which is the property the LP relies on. `atol` because
    # one breakpoint sits at zero flow, where a bare `≈` carries no tolerance at all.
    accumulated = interconnector_losses(TEST_LOSS_MODEL, first(segments).from_mw, TEST_DEMAND)
    for seg in segments
        accumulated += seg.slope * (seg.to_mw - seg.from_mw)
        @test isapprox(
            accumulated,
            interconnector_losses(TEST_LOSS_MODEL, seg.to_mw, TEST_DEMAND);
            atol = 1.0e-9,
        )
    end

    # Convex curve, so the chord slopes increase monotonically - the ordering an LP needs to pick
    # segments cheapest-first without integer variables.
    @test issorted([seg.slope for seg in segments])

    # A single breakpoint defines no segment; returning an empty vector would silently present a
    # lossless interconnector as a modelled one.
    single = InterconnectorLossModel(;
        interconnector = "IC_ONE", from_region = "VIC1", to_region = "NSW1",
        from_region_loss_share = 0.5, loss_constant = 1.0, loss_flow_coefficient = 0.0,
        demand_coefficients = Dict{String, Float64}(), breakpoints = [0.0],
    )
    @test_throws ArgumentError loss_segments(single, TEST_DEMAND)

    # Two equal adjacent breakpoints would otherwise divide by zero and produce a silent NaN
    # slope, corrupting any downstream LP that consumes loss_segments' output.
    degenerate = InterconnectorLossModel(;
        interconnector = "IC_DEGENERATE", from_region = "VIC1", to_region = "NSW1",
        from_region_loss_share = 0.5, loss_constant = 1.0, loss_flow_coefficient = 0.0,
        demand_coefficients = Dict{String, Float64}(), breakpoints = [0.0, 0.0, 500.0],
    )
    @test_throws ArgumentError loss_segments(degenerate, TEST_DEMAND)
end

let
    config = HiveConfiguration(hive_location = AEM_TEST_HIVE_DIR, filesystem = "file")
    db = aem_connect(config)
    as_of = Date(2025, 1, 2)

    @testset "read_interconnector_loss_breakpoints" begin
        df = read_interconnector_loss_breakpoints(db, as_of)
        @test df isa DataFrame
        @test Set(names(df)) == Set(["INTERCONNECTORID", "LOSSSEGMENT", "MWBREAKPOINT"])
        # IC6 has loss parameters but no LOSSMODEL rows at all.
        @test Set(df.INTERCONNECTORID) == Set("IC$i" for i in 1:5)
        # IC1's superseded 2024 version carries ±100 MW breakpoints; the 2025 one carries ±500.
        ic1 = df[df.INTERCONNECTORID .== "IC1", :]
        @test sort(ic1.MWBREAKPOINT) == [-500.0, -250.0, 0.0, 250.0, 500.0]

        # Resolving as of a date before the current version falls back to the superseded one.
        earlier = read_interconnector_loss_breakpoints(db, Date(2024, 6, 1))
        @test sort(earlier[earlier.INTERCONNECTORID .== "IC1", :].MWBREAKPOINT) ==
            [-100.0, -50.0, 0.0, 50.0, 100.0]
    end

    @testset "read_interconnector_demand_coefficients" begin
        df = read_interconnector_demand_coefficients(db, as_of)
        @test Set(names(df)) == Set(["INTERCONNECTORID", "REGIONID", "DEMANDCOEFFICIENT"])
        @test nrow(df) == 12
        @test all(!ismissing, df.DEMANDCOEFFICIENT)
    end

    @testset "read_interconnector_loss_parameters" begin
        df = read_interconnector_loss_parameters(db, as_of)
        @test nrow(df) == 6
        @test "REGIONFROM" in names(df) && "REGIONTO" in names(df)
        @test all(df.LOSSCONSTANT .≈ 0.01)
        @test all(df.LOSSFLOWCOEFFICIENT .≈ 0.001)
        @test all(df.FROMREGIONLOSSSHARE .≈ 0.1)
    end

    @testset "interconnector_loss_models" begin
        models = @test_logs (:warn, r"no LOSSMODEL breakpoints") match_mode = :any begin
            interconnector_loss_models(db, as_of)
        end
        @test models isa Dict{String, InterconnectorLossModel}
        # IC6 is skipped for want of breakpoints, not included as a lossless interconnector.
        @test Set(keys(models)) == Set("IC$i" for i in 1:5)

        ic1 = models["IC1"]
        @test ic1.from_region == "VIC1"
        @test ic1.to_region == "SNOWY1"
        @test ic1.from_region_loss_share ≈ 0.1
        @test ic1.breakpoints == [-500.0, -250.0, 0.0, 250.0, 500.0]
        @test issorted(ic1.breakpoints)
        @test Set(keys(ic1.demand_coefficients)) == Set(["VIC1", "SNOWY1"])
        # Assembled models feed the same math the pure-function tests above cover.
        @test length(loss_segments(ic1, Dict("VIC1" => 4000.0, "SNOWY1" => 100.0))) == 4
    end

    @testset "uncached tables throw, never return empty" begin
        empty_db = aem_connect(
            HiveConfiguration(hive_location = mktempdir(), filesystem = "file"),
        )
        @test_throws ArgumentError read_interconnector_loss_breakpoints(empty_db, as_of)
        @test_throws ArgumentError read_interconnector_demand_coefficients(empty_db, as_of)
        @test_throws ArgumentError read_interconnector_loss_parameters(empty_db, as_of)
    end

    @testset "no model resolvable throws" begin
        # Every EFFECTIVEDATE postdates this, so nothing resolves - a real "nothing to model"
        # answer is indistinguishable from missing data here, so it must not be returned empty.
        @test_throws ArgumentError interconnector_loss_models(db, Date(2020, 1, 1))
    end

    @testset "attach_interconnector_losses!" begin
        sys = nem_system(db, RegionalNetworkConfiguration())
        base_power = get_base_power(sys)
        added, skipped = @test_logs (:warn, r"no resolvable loss model") match_mode = :any begin
            attach_interconnector_losses!(sys, db, as_of)
        end
        # IC6 has no LOSSMODEL breakpoints, same as interconnector_loss_models above.
        @test Set(added) == Set("IC$i" for i in 1:5)
        @test skipped == Dict("IC6" => :no_loss_model)

        ic1 = get_component(AreaInterchange, sys, "IC1")
        attached = only(get_supplemental_attributes(InterconnectorLossModel, ic1))
        @test attached.interconnector == "IC1"
        # Attached models are per-unitized to sys's base power - not the raw MW breakpoints
        # interconnector_loss_models itself returns (checked above).
        @test attached.breakpoints == [-500.0, -250.0, 0.0, 250.0, 500.0] ./ base_power
    end

    @testset "InterconnectorLossModel JSON round-trip" begin
        sys = nem_system(db, RegionalNetworkConfiguration())
        base_power = get_base_power(sys)
        attach_interconnector_losses!(sys, db, as_of)

        mktpath = mktempdir()
        json_path = joinpath(mktpath, "sys.json")
        to_json(sys, json_path)
        sys2 = System(json_path)

        ic1 = get_component(AreaInterchange, sys2, "IC1")
        model = only(get_supplemental_attributes(InterconnectorLossModel, ic1))
        @test model.interconnector == "IC1"
        @test model.from_region == "VIC1"
        @test model.to_region == "SNOWY1"
        @test model.breakpoints == [-500.0, -250.0, 0.0, 250.0, 500.0] ./ base_power
        @test model.demand_coefficients isa Dict{String, Float64}
        @test Set(keys(model.demand_coefficients)) == Set(["VIC1", "SNOWY1"])
        source_model = only(get_supplemental_attributes(InterconnectorLossModel, get_component(AreaInterchange, sys, "IC1")))
        @test get_loss_model_provenance(model) == get_loss_model_provenance(source_model)
    end

    @testset "per-unit conversion preserves physical losses" begin
        base_power = 100.0
        flow_mw = 300.0
        demand_mw = TEST_DEMAND
        loss_mw = interconnector_losses(TEST_LOSS_MODEL, flow_mw, demand_mw)

        pu_model = AustralianElectricityMarkets._to_pu(TEST_LOSS_MODEL, base_power)
        demand_pu = Dict(r => d / base_power for (r, d) in demand_mw)
        loss_pu = interconnector_losses(pu_model, flow_mw / base_power, demand_pu)
        @test loss_pu * base_power ≈ loss_mw

        segments_mw = loss_segments(TEST_LOSS_MODEL, demand_mw)
        segments_pu = loss_segments(pu_model, demand_pu)
        @test length(segments_mw) == length(segments_pu)
        for (mw, pu) in zip(segments_mw, segments_pu)
            @test pu.from_mw * base_power ≈ mw.from_mw
            @test pu.to_mw * base_power ≈ mw.to_mw
            @test pu.slope ≈ mw.slope
        end
    end
end

@testset "piecewise loss vertices are referenced to zero flow" begin
    function curve_model(; scale = 1.0, breakpoints = [-17.0, 17.0], b = 0.00017965, c = 1.0)
        return InterconnectorLossModel(
            ; interconnector = "TEST", from_region = "1", to_region = "2",
            from_region_loss_share = 0.4, loss_constant = c,
            loss_flow_coefficient = b * scale,
            demand_coefficients = Dict("2" => 0.0003 * scale),
            breakpoints = breakpoints ./ scale,
        )
    end

    demand = Dict("2" => 23.0)
    model = curve_model()
    corrected = loss_curve_vertex_values(model, demand)
    # Subtract the chord's zero-flow intercept from both vertices, preserving its slope.
    offset = 0.00017965 * 17.0^2 / 2
    expected = [interconnector_losses(model, bp, demand) - offset for bp in (-17.0, 17.0)]
    @test corrected ≈ expected atol = 1.0e-12
    @test corrected[1] < 0 < corrected[2]
    @test corrected[1] ≈ -corrected[2] atol = 1.0e-12
    @test only(diff(corrected)) / 34.0 ≈ loss_segments(model, demand)[1].slope atol = 1.0e-12

    # The nonzero demand changes the linear term, but cannot move the zero-flow reference.
    no_demand_model = curve_model(; c = 1.0)
    @test loss_curve_vertex_values(no_demand_model, Dict{String, Float64}()) .-
        loss_curve_vertex_values(no_demand_model, demand) ≈ [0.0003 * 23.0 * 17.0, -0.0003 * 23.0 * 17.0] atol = 1.0e-12

    # Attached models use per-unit values but represent the same physical curve.
    base = 100.0
    pu_model = curve_model(; scale = base, breakpoints = [-17.0, 17.0], b = 0.00017965)
    pu_values = loss_curve_vertex_values(pu_model, Dict("2" => 23.0 / base))
    @test pu_values .* base ≈ corrected atol = 1.0e-12

    # A zero breakpoint anchors the curve; one-sided ranges retain their existing values.
    with_zero = curve_model(; breakpoints = [-17.0, 0.0, 17.0])
    @test loss_curve_vertex_values(with_zero, demand) ≈
        [interconnector_losses(with_zero, bp, demand) for bp in with_zero.breakpoints] atol = 1.0e-12
    linear = curve_model(; b = 0.0)
    @test loss_curve_vertex_values(linear, demand) ≈
        [interconnector_losses(linear, bp, demand) for bp in linear.breakpoints] atol = 1.0e-12
    one_sided = curve_model(; breakpoints = [3.0, 17.0])
    @test loss_curve_vertex_values(one_sided, demand) ≈
        [interconnector_losses(one_sided, bp, demand) for bp in one_sided.breakpoints] atol = 1.0e-12
end
