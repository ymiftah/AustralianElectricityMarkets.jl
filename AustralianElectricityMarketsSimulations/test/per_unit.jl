import PowerSimulations as PSI
import PowerSystems as PSY
using Dates

@testset "mw_to_pu: 100 MVA base, 50 MW is exactly 0.5 pu on every path" begin
    @test mw_to_pu(50.0, 100.0) == 0.5

    sys = PSY.System(100.0)
    container = PSI.OptimizationContainer(
        sys, PSI.Settings(sys; horizon = Hour(1)), nothing, PSY.SingleTimeSeries,
    )
    @test mw_to_pu(container, 50.0) == 0.5
end

@testset "pu_to_mw: 100 MVA base, 0.5 pu is exactly 50 MW on every path" begin
    @test pu_to_mw(0.5, 100.0) == 50.0

    sys = PSY.System(100.0)
    container = PSI.OptimizationContainer(
        sys, PSI.Settings(sys; horizon = Hour(1)), nothing, PSY.SingleTimeSeries,
    )
    @test pu_to_mw(container, 0.5) == 50.0
end

@testset "pu -> mw -> pu round trip is exact" begin
    base_power = 180.0
    for pu in (0.0, 0.5, 1.0, 12345.6789)
        @test mw_to_pu(pu_to_mw(pu, base_power), base_power) ≈ pu
    end
end

@testset "dimensionless_factor leaves a factor unchanged" begin
    for factor in (-1.0, 0.0, 0.4, 1.0)
        @test dimensionless_factor(factor) === factor
    end
end

@testset "price_to_pu_coefficient preserves the five-minute dispatch interval" begin
    # $50/MWh at a 100 MVA base: a 1.0 pu dispatch variable is 100 MW, dispatched for
    # DISPATCH_INTERVAL_HOURS = 1/12 hour, so it earns/costs 50 * 100 * (1/12) = 416.666... $.
    price_per_mwh = 50.0
    base_power = 100.0
    expected = 50.0 * 100.0 * (1 / 12)
    @test price_to_pu_coefficient(price_per_mwh, base_power) ≈ expected
    @test DISPATCH_INTERVAL_HOURS == 1 / 12

    sys = PSY.System(base_power)
    container = PSI.OptimizationContainer(
        sys, PSI.Settings(sys; horizon = Hour(1)), nothing, PSY.SingleTimeSeries,
    )
    @test price_to_pu_coefficient(container, price_per_mwh) ≈ expected
end

@testset "base power is read from the container, not assumed to be 100" begin
    base_power = 250.0
    sys = PSY.System(base_power)
    container = PSI.OptimizationContainer(
        sys, PSI.Settings(sys; horizon = Hour(1)), nothing, PSY.SingleTimeSeries,
    )
    @test PSI.get_base_power(container) == base_power

    @test mw_to_pu(container, 50.0) == 50.0 / base_power
    @test pu_to_mw(container, 0.5) == 0.5 * base_power
    @test price_to_pu_coefficient(container, 50.0) ≈ 50.0 * base_power * DISPATCH_INTERVAL_HOURS

    # Same explicit-base_power path, tracking the non-100 base directly.
    @test mw_to_pu(50.0, base_power) == 50.0 / base_power
    @test pu_to_mw(0.5, base_power) == 0.5 * base_power
end
