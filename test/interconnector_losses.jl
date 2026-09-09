using DataFrames: DataFrame, nrow

# A hand-built model with realistic NEMDE magnitudes: LOSSCONSTANT is a loss *factor*, so it sits
# near 1.0, and the mock hive's 0.01 is deliberately not reused here - the closed forms below are
# checked against numbers a real interconnector would carry.
const TEST_LOSS_MODEL = InterconnectorLossModel(
    "IC_TEST", "VIC1", "NSW1", 0.4, 1.02, 2.0e-4,
    Dict("VIC1" => 1.0e-5, "NSW1" => -2.0e-5),
    [-500.0, -250.0, 0.0, 250.0, 500.0],
)
const TEST_DEMAND = Dict("VIC1" => 4000.0, "NSW1" => 7000.0)

@testset "loss_factor" begin
    # 1.02 + 2e-4 * flow + (1e-5 * 4000 + -2e-5 * 7000) = 1.02 + 2e-4 * flow - 0.1
    @test loss_factor(TEST_LOSS_MODEL, 0.0, TEST_DEMAND) ≈ 0.92
    @test loss_factor(TEST_LOSS_MODEL, 500.0, TEST_DEMAND) ≈ 1.02
    # A region with a coefficient but no demand entry contributes nothing rather than erroring.
    @test loss_factor(TEST_LOSS_MODEL, 0.0, Dict("VIC1" => 4000.0)) ≈ 1.06
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
    single = InterconnectorLossModel(
        "IC_ONE", "VIC1", "NSW1", 0.5, 1.0, 0.0, Dict{String, Float64}(), [0.0],
    )
    @test_throws ArgumentError loss_segments(single, TEST_DEMAND)
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
end
