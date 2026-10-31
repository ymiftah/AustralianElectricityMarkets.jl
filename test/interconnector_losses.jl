using DataFrames: DataFrame, nrow

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
        df = read_interconnector_loss_breakpoints(db; as_of = as_of)
        @test Set(names(df)) == Set(["INTERCONNECTORID", "LOSSSEGMENT", "MWBREAKPOINT"])
        # IC6 has loss parameters but no LOSSMODEL rows at all.
        @test Set(df.INTERCONNECTORID) == Set("IC$i" for i in 1:5)
        # IC1's superseded 2024 version carries ±100 MW breakpoints; the 2025 one carries ±500.
        ic1 = df[df.INTERCONNECTORID .== "IC1", :]
        @test sort(ic1.MWBREAKPOINT) == [-500.0, -250.0, 0.0, 250.0, 500.0]

        # Resolving as of a date before the current version falls back to the superseded one.
        earlier = read_interconnector_loss_breakpoints(db; as_of = Date(2024, 6, 1))
        @test sort(earlier[earlier.INTERCONNECTORID .== "IC1", :].MWBREAKPOINT) ==
            [-100.0, -50.0, 0.0, 50.0, 100.0]
    end

    @testset "read_interconnector_demand_coefficients" begin
        df = read_interconnector_demand_coefficients(db; as_of = as_of)
        @test Set(names(df)) == Set(["INTERCONNECTORID", "REGIONID", "DEMANDCOEFFICIENT"])
        @test nrow(df) == 12
        @test all(!ismissing, df.DEMANDCOEFFICIENT)
    end

    @testset "read_interconnector_loss_parameters" begin
        df = read_interconnector_loss_parameters(db; as_of = as_of)
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
        # IC6 is skipped for want of breakpoints, not included as a lossless interconnector.
        @test Set(keys(models)) == Set("IC$i" for i in 1:5)

        ic1 = models["IC1"]
        @test ic1.from_region == "VIC1"
        @test ic1.to_region == "SNOWY1"
        @test ic1.from_region_loss_share ≈ 0.1
        @test ic1.breakpoints == [-500.0, -250.0, 0.0, 250.0, 500.0]
        @test Set(keys(ic1.demand_coefficients)) == Set(["VIC1", "SNOWY1"])
        # Assembled models feed the same math the pure-function tests above cover.
        @test length(loss_segments(ic1, Dict("VIC1" => 4000.0, "SNOWY1" => 100.0))) == 4
    end

    @testset "demand coefficient patch" begin
        patch = AustralianElectricityMarkets._apply_demand_coefficient_patches!
        fresh() = Dict("V-SA" => Dict("VIC1" => -1.0e-5, "SA1" => 5.0e-5))
        @test patch(fresh(), Date(2025, 7, 1))["V-SA"]["NSW1"] == 1.6981e-6
        @test patch(fresh(), DateTime(2026, 6, 30, 23, 55))["V-SA"]["NSW1"] == 1.6981e-6
        @test !haskey(patch(fresh(), Date(2025, 6, 30))["V-SA"], "NSW1")
        @test !haskey(patch(fresh(), Date(2026, 7, 1))["V-SA"], "NSW1")
        explicit = Dict("V-SA" => Dict("NSW1" => 0.0))
        @test patch(explicit, Date(2025, 8, 1))["V-SA"]["NSW1"] == 0.0
        @test isempty(patch(Dict{String, Dict{String, Float64}}(), Date(2025, 8, 1)))
    end

    @testset "uncached tables throw, never return empty" begin
        empty_db = aem_connect(
            HiveConfiguration(hive_location = mktempdir(), filesystem = "file"),
        )
        @test_throws ArgumentError read_interconnector_loss_breakpoints(empty_db; as_of = as_of)
        @test_throws ArgumentError read_interconnector_demand_coefficients(empty_db; as_of = as_of)
        @test_throws ArgumentError read_interconnector_loss_parameters(empty_db; as_of = as_of)
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

    @testset "set_loss_demand_coefficients! evaluates each loss model's demand term per interval" begin
        sys = nem_system(db, RegionalNetworkConfiguration())
        @test_logs (:warn, r"no resolvable loss model") match_mode = :any attach_interconnector_losses!(sys, db, as_of)
        # No demand series yet: nothing to evaluate the loss factor at.
        @test_throws r"no \"loss_demand\" series" set_loss_demand_coefficients!(sys)
        date_range = DateTime(2025, 1, 1, 0, 0):Minute(5):DateTime(2025, 1, 1, 1, 0)
        attach_demand!(sys, db, date_range; resolution = Minute(5))
        set_loss_demand_coefficients!(sys)
        base_power = get_base_power(sys)
        ic1 = get_component(AreaInterchange, sys, "IC1")
        model = only(get_supplemental_attributes(InterconnectorLossModel, ic1))
        loss_demand_mw(region) = with_units_base(sys, "NATURAL_UNITS") do
            get_time_series_values(SingleTimeSeries, get_component(PowerLoad, sys, "$region Load"), "loss_demand")
        end
        # Per-unit coefficient times per-unit demand equals the MW coefficient times MW demand.
        expected = sum(c / base_power .* loss_demand_mw(r) for (r, c) in model.demand_coefficients)
        coefficient = get_time_series_values(SingleTimeSeries, ic1, "loss_demand_coefficient")
        @test coefficient ≈ expected
        @test any(!iszero, coefficient)
        @test get_time_series_timestamps(SingleTimeSeries, ic1, "loss_demand_coefficient") ==
            get_time_series_timestamps(SingleTimeSeries, get_component(PowerLoad, sys, "VIC1 Load"), "loss_demand")
        @test !has_time_series(get_component(AreaInterchange, sys, "IC6"), SingleTimeSeries, "loss_demand_coefficient")

        # An unavailable load drops out of its region's demand, and re-running replaces the series.
        set_available!(get_component(PowerLoad, sys, "VIC1 Load"), false)
        set_loss_demand_coefficients!(sys)
        without_vic = sum(
            (c / base_power .* loss_demand_mw(r) for (r, c) in model.demand_coefficients if r != "VIC1");
            init = zeros(length(coefficient)),
        )
        @test get_time_series_values(SingleTimeSeries, ic1, "loss_demand_coefficient") ≈ without_vic
    end

    @testset "set_loss_demand_coefficients! rejects inconsistent loads" begin
        date_range = DateTime(2025, 1, 1, 0, 0):Minute(5):DateTime(2025, 1, 1, 1, 0)
        fresh() = begin
            sys = nem_system(db, RegionalNetworkConfiguration())
            @test_logs (:warn, r"no resolvable loss model") match_mode = :any attach_interconnector_losses!(sys, db, as_of)
            attach_demand!(sys, db, date_range; resolution = Minute(5))
            sys
        end

        sys = fresh()
        load = get_component(PowerLoad, sys, "VIC1 Load")
        set_area!(get_bus(load), nothing)
        @test_throws r"on a bus with no area" set_loss_demand_coefficients!(sys)

        sys = fresh()
        load = get_component(PowerLoad, sys, "VIC1 Load")
        original = get_time_series(SingleTimeSeries, load, "loss_demand")
        stamps = get_time_series_timestamps(SingleTimeSeries, load, "loss_demand")
        values = get_time_series_values(SingleTimeSeries, load, "loss_demand")
        remove_time_series!(sys, SingleTimeSeries, load, "loss_demand")
        add_time_series!(
            sys, load,
            AustralianElectricityMarkets.single_series("loss_demand", first(stamps) + Minute(5), values, get_resolution(original)),
        )
        @test_throws r"is not on the timestamps" set_loss_demand_coefficients!(sys)
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
