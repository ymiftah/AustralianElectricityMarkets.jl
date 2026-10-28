@testset "Bid conversion preserves values and ownership" begin
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

    for direction in ("GEN", "LOAD", "BIDIRECTIONAL"), keep in (false, true), factor in (nothing, 0.873, 0.5, 1.0), base in (nothing, 100.0)
        row = (DIRECTION = direction, PRICEBANDARRAY = [-1000.0, 10.005, 20.015, 20300.0], BANDAVAILARRAY = [0.0, 1.25, 0.0, 8.75])
        before = deepcopy(row)
        expected = original_curve(row; keep_empty_bands = keep)
        x = isnothing(base) ? get_x_coords(expected) : get_x_coords(expected) ./ base
        y = isnothing(factor) ? get_y_coords(expected) : round.(get_y_coords(expected) ./ factor; digits = 2)
        actual = AEM._extract_power_bids(row; keep_empty_bands = keep, price_factor = factor, base_power = base)
        @test isequal(get_x_coords(actual), x)
        @test isequal(get_y_coords(actual), y)
        @test isequal(row, before)
        get_y_coords(actual)[1] = 999.0
        @test row.PRICEBANDARRAY == before.PRICEBANDARRAY
    end

    for direction in ("GEN", "LOAD", "BIDIRECTIONAL"), base in (nothing, 100.0)
        row = (
            DUID = "EXAMPLE", DIRECTION = direction, INTERVAL_DATETIME = DateTime(2026, 1, 22, 4, 5),
            PRICEBANDARRAY = [-10.0, 20.0], BANDAVAILARRAY = [0.0, 5.0],
            ENABLEMENTMIN = 0.0, LOWBREAKPOINT = 10.0, HIGHBREAKPOINT = 20.0,
            ENABLEMENTMAX = 30.0, MAXAVAIL = 5.0, ROCUP = missing, ROCDOWN = 2.0,
        )
        curve, packed = AEM._extract_fcas_bid(row; base_power = base)
        expected = original_curve(row; keep_empty_bands = true)
        divisor = isnothing(base) ? 1.0 : base
        # The offer curve stays in MW; only the trapezium is per-unitised.
        @test get_x_coords(curve) == get_x_coords(expected)
        @test get_y_coords(curve) == get_y_coords(expected)
        @test isequal(packed, (0.0, 10.0, 20.0, 30.0, 5.0, NaN, 2.0) ./ divisor)
        invalid = merge(row, (LOWBREAKPOINT = 40.0,))
        error = try
            AEM._extract_fcas_bid(invalid; base_power = base)
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
            @test_throws ArgumentError AEM._extract_power_bids(row; keep_empty_bands = true, price_factor = 0.873, base_power = 100.0)
        else
            expected = original_curve(row; keep_empty_bands = true)
            actual = AEM._extract_power_bids(row; keep_empty_bands = true, price_factor = 0.873, base_power = 100.0)
            @test get_x_coords(actual) == get_x_coords(expected) ./ 100.0
            @test get_y_coords(actual) == get_y_coords(expected)
        end
    end
    for direction in ("GEN", "LOAD"), keep in (false, true)
        row = (DIRECTION = direction, PRICEBANDARRAY = [10.0], BANDAVAILARRAY = [0.0, 5.0])
        @test_throws BoundsError original_curve(row; keep_empty_bands = keep)
        @test_throws BoundsError AEM._extract_power_bids(row; keep_empty_bands = keep)
    end

    tiny = nextfloat(0.0)
    decreasing = (DIRECTION = "GEN", PRICEBANDARRAY = [10.0, 20.0], BANDAVAILARRAY = [2tiny, -tiny])
    @test_throws ArgumentError original_curve(decreasing; keep_empty_bands = true)
    @test_throws ArgumentError AEM._extract_power_bids(decreasing; keep_empty_bands = true, base_power = 100.0)

    bids = DataFrame(
        DUID = ["A", "A", "OUTSIDE"], DIRECTION = ["GEN", "LOAD", "GEN"],
        PRICEBANDARRAY = [[10.005, 20.015] for _ in 1:3],
        BANDAVAILARRAY = [[0.0, 10.0] for _ in 1:3],
    )
    factors = DataFrame(DUID = ["A"], GEN_LOSS_FACTOR = [0.873], LOAD_LOSS_FACTOR = [0.5])
    AEM._set_referred_bid_curves!(bids, factors; units = Set(["A"]))
    @test get_y_coords(bids.piecewise_step_data[1]) == round.([10.005, 20.015] ./ 0.873; digits = 2)
    @test get_y_coords(bids.piecewise_step_data[2]) == round.([20.015, 10.005] ./ 0.5; digits = 2)
    @test get_y_coords(bids.piecewise_step_data[3]) == [10.005, 20.015]
    @test_throws r"No DUDETAILSUMMARY loss factor.*OUTSIDE" AEM._set_referred_bid_curves!(bids, factors)
    malformed = deepcopy(bids)
    malformed.BANDAVAILARRAY[3] = [0.0, -1.0]
    @test_throws ArgumentError AEM._set_referred_bid_curves!(malformed, factors; units = Set(["A"]))
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

@testset "FCAS groups retain ordered directional bids without mutating inputs" begin
    AEM = AustralianElectricityMarkets
    raw = DataFrame(
        DUID = ["A", "A", "A", "B"], DIRECTION = ["LOAD", "GEN", "BIDIRECTIONAL", "GEN"],
        INTERVAL_DATETIME = [DateTime(2026, 1, 22, 4, 10), DateTime(2026, 1, 22, 4, 10), DateTime(2026, 1, 22, 4, 5), DateTime(2026, 1, 22, 4, 5)],
        PRICEBANDARRAY = [[10.0, 20.0] for _ in 1:4], BANDAVAILARRAY = [[0.0, 5.0] for _ in 1:4],
        ENABLEMENTMIN = zeros(4), LOWBREAKPOINT = fill(10.0, 4), HIGHBREAKPOINT = fill(20.0, 4),
        ENABLEMENTMAX = fill(30.0, 4), MAXAVAIL = fill(5.0, 4), ROCUP = fill(missing, 4), ROCDOWN = fill(2.0, 4),
    )
    before = deepcopy(raw)
    inc, dec = AEM._fcas_bid_groups(raw, 100.0)
    @test isequal(raw, before)
    @test inc[("A",)].DIRECTION == ["BIDIRECTIONAL", "GEN"]
    @test inc[("A",)].INTERVAL_DATETIME == sort(raw.INTERVAL_DATETIME[[2, 3]])
    @test dec[("A",)].DIRECTION == ["LOAD"]
    @test inc[("B",)].DIRECTION == ["GEN"]
    for group in (inc, dec), rows in group, row in eachrow(rows)
        original = only(eachrow(filter(r -> r.DUID == row.DUID && r.DIRECTION == row.DIRECTION, raw)))
        curve, packed = AEM._extract_fcas_bid(original; base_power = 100.0)
        @test isequal(get_x_coords(curve), get_x_coords(row.curve_data))
        @test isequal(get_y_coords(curve), get_y_coords(row.curve_data))
        @test isequal(packed, row.trapezium_row)
    end
    @test AEM._fcas_bid_groups(raw[1:1, :], 100.0)[1] === nothing
    @test AEM._fcas_bid_groups(raw[2:2, :], 100.0)[2] === nothing
end
