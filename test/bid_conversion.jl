@testset "Bid conversion keeps offers as bid" begin
    using AustralianElectricityMarkets
    using PowerSystems
    using DataFrames
    using Dates

    AEM = AustralianElectricityMarkets
    function original_curve(row)
        prices, widths = copy(row.prices), copy(row.widths)
        if row.DIRECTION == "LOAD"
            reverse!(prices)
            reverse!(widths)
        end
        return PiecewiseStepData([zero(eltype(prices)); cumsum(widths)], prices)
    end

    for direction in ("GEN", "LOAD", "BIDIRECTIONAL")
        row = (DIRECTION = direction, prices = [-1000.0, 10.005, 20.015, 20300.0], widths = [0.0, 1.25, 0.0, 8.75])
        before = deepcopy(row)
        expected = original_curve(row)
        actual = offer_curve(row.prices, row.widths, direction)
        @test isequal(get_x_coords(actual), get_x_coords(expected))
        @test isequal(get_y_coords(actual), get_y_coords(expected))
        @test isequal(row, before)
        get_y_coords(actual)[1] = 999.0
        @test row.prices == before.prices
    end

    for direction in ("GEN", "LOAD", "BIDIRECTIONAL")
        row = (
            DUID = "EXAMPLE", DIRECTION = direction, INTERVAL_DATETIME = DateTime(2026, 1, 22, 4, 5),
            ENABLEMENTMIN = 0.0, LOWBREAKPOINT = 10.0, HIGHBREAKPOINT = 20.0,
            ENABLEMENTMAX = 30.0, MAXAVAIL = 5.0, ROCUP = missing, ROCDOWN = 2.0,
        )
        points = AEM._fcas_trapezium_points(row)
        @test points == AEM.FCASTrapeziumPoints((0.0, 10.0, 20.0, 30.0))
        invalid = merge(row, (LOWBREAKPOINT = 40.0,))
        error = (@test_throws ArgumentError AEM._fcas_trapezium_points(invalid)).value
        @test occursin("EXAMPLE ($direction) at 2026-01-22T04:05:00", error.msg) && occursin("LowBreakpoint = 40.0", error.msg)
    end
    for direction in ("GEN", "LOAD")
        row = (DIRECTION = direction, prices = zeros(2), widths = [0.0, 0.0])
        expected = original_curve(row)
        actual = offer_curve(row.prices, row.widths, direction)
        @test get_x_coords(actual) == get_x_coords(expected)
        @test get_y_coords(actual) == get_y_coords(expected)
        @test_throws BoundsError offer_curve([10.0], [0.0, 5.0], direction)
    end
end

@testset "FCAS validation evaluates context only for errors" begin
    AEM = AustralianElectricityMarkets
    valid = FCASTrapezium(; enablement_min = 0.0, low_breakpoint = 10.0, high_breakpoint = 20.0, enablement_max = 30.0, max_avail = 5.0)
    calls = Ref(0)
    context = () -> begin
        calls[] += 1
        return "DUID EXAMPLE at 2026-01-22T04:05:00"
    end
    @test AEM._validate_fcas_trapezium(valid, context) === valid
    @test calls[] == 0
    invalid = FCASTrapezium(; enablement_min = 0.0, low_breakpoint = 40.0, high_breakpoint = 20.0, enablement_max = 30.0, max_avail = 5.0)
    expected = (@test_throws ArgumentError AEM._validate_fcas_trapezium(invalid, "DUID EXAMPLE at 2026-01-22T04:05:00")).value
    @test_throws expected AEM._validate_fcas_trapezium(invalid, context)
    @test calls[] == 1
end

@testset "FCAS numeric extraction is inferred for each field" begin
    AEM = AustralianElectricityMarkets
    row = (DUID = "TYPED", MAXAVAIL = 12.5, ENABLEMENTMIN = 0.0, LOWBREAKPOINT = 1.0)
    @test @inferred(AEM._require_fcas_float(row, Val(:MAXAVAIL))) === 12.5
    @test @inferred(AEM._require_fcas_float(row, Val(:ENABLEMENTMIN))) === 0.0
    @test @inferred(AEM._require_fcas_float(merge(row, (MAXAVAIL = 12,)), Val(:MAXAVAIL))) === 12.0
    @test_throws r"MAXAVAIL is missing for DUID TYPED" AEM._require_fcas_float(merge(row, (MAXAVAIL = missing,)), Val(:MAXAVAIL))
end
