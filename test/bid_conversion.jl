@testset "Bid conversion keeps offers as bid" begin
    using AustralianElectricityMarkets
    using PowerSystems
    using DataFrames
    using Dates

    AEM = AustralianElectricityMarkets
    function original_curve(row; keep_empty_bands)
        prices, widths = copy(row.PRICEBANDARRAY), copy(row.BANDAVAILARRAY)
        if row.DIRECTION == "LOAD"
            reverse!(prices)
            reverse!(widths)
        end
        kept = keep_empty_bands ? trues(length(widths)) : widths .> 0
        return PiecewiseStepData([zero(eltype(prices)); cumsum(widths[kept])], prices[kept])
    end

    for direction in ("GEN", "LOAD", "BIDIRECTIONAL"), keep in (false, true)
        row = (DIRECTION = direction, PRICEBANDARRAY = [-1000.0, 10.005, 20.015, 20300.0], BANDAVAILARRAY = [0.0, 1.25, 0.0, 8.75])
        before = deepcopy(row)
        expected = original_curve(row; keep_empty_bands = keep)
        actual = AEM._extract_power_bids(row; keep_empty_bands = keep)
        @test isequal(get_x_coords(actual), get_x_coords(expected))
        @test isequal(get_y_coords(actual), get_y_coords(expected))
        @test isequal(row, before)
        get_y_coords(actual)[1] = 999.0
        @test row.PRICEBANDARRAY == before.PRICEBANDARRAY
    end

    for direction in ("GEN", "LOAD", "BIDIRECTIONAL")
        row = (
            DUID = "EXAMPLE", DIRECTION = direction, INTERVAL_DATETIME = DateTime(2026, 1, 22, 4, 5),
            PRICEBANDARRAY = [-10.0, 20.0], BANDAVAILARRAY = [0.0, 5.0],
            ENABLEMENTMIN = 0.0, LOWBREAKPOINT = 10.0, HIGHBREAKPOINT = 20.0,
            ENABLEMENTMAX = 30.0, MAXAVAIL = 5.0, ROCUP = missing, ROCDOWN = 2.0,
        )
        points = AEM._fcas_trapezium_points(row)
        @test points == AEM.FCASTrapeziumPoints((0.0, 10.0, 20.0, 30.0))
        invalid = merge(row, (LOWBREAKPOINT = 40.0,))
        error = try
            AEM._fcas_trapezium_points(invalid)
        catch e
            e
        end
        @test error isa ArgumentError
        @test occursin("EXAMPLE ($direction) at 2026-01-22T04:05:00", error.msg)
        @test occursin("LowBreakpoint = 40.0", error.msg)
    end
    for direction in ("GEN", "LOAD"), widths in (Float64[], [0.0, 0.0])
        row = (DIRECTION = direction, PRICEBANDARRAY = zeros(length(widths)), BANDAVAILARRAY = widths)
        if isempty(widths)
            @test_throws ArgumentError original_curve(row; keep_empty_bands = true)
        else
            expected = original_curve(row; keep_empty_bands = true)
            actual = AEM._extract_power_bids(row; keep_empty_bands = true)
            @test get_x_coords(actual) == get_x_coords(expected)
            @test get_y_coords(actual) == get_y_coords(expected)
        end
    end
    for direction in ("GEN", "LOAD"), keep in (false, true)
        row = (DIRECTION = direction, PRICEBANDARRAY = [10.0], BANDAVAILARRAY = [0.0, 5.0])
        @test_throws BoundsError original_curve(row; keep_empty_bands = keep)
        @test_throws BoundsError AEM._extract_power_bids(row; keep_empty_bands = keep)
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
    expected = try
        AEM._validate_fcas_trapezium(invalid, "DUID EXAMPLE at 2026-01-22T04:05:00")
    catch e
        e
    end
    actual = try
        AEM._validate_fcas_trapezium(invalid, context)
    catch e
        e
    end
    @test calls[] == 1
    @test actual isa ArgumentError
    @test actual.msg == expected.msg
end

@testset "FCAS numeric extraction is inferred for each field" begin
    AEM = AustralianElectricityMarkets
    row = (DUID = "TYPED", MAXAVAIL = 12.5, ENABLEMENTMIN = 0.0, LOWBREAKPOINT = 1.0)
    @test @inferred(AEM._require_fcas_float(row, Val(:MAXAVAIL))) === 12.5
    @test @inferred(AEM._require_fcas_float(row, Val(:ENABLEMENTMIN))) === 0.0
    @test @inferred(AEM._require_fcas_float(merge(row, (MAXAVAIL = 12,)), Val(:MAXAVAIL))) === 12.0
    @test_throws r"MAXAVAIL is missing for DUID TYPED" AEM._require_fcas_float(merge(row, (MAXAVAIL = missing,)), Val(:MAXAVAIL))
end
