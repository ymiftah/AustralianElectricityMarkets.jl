# The tie-break scales and the EnergyTieBreak service, written on the mock replay System (AEMSim not loaded).
# Writer tests strip their own family's series and the energy offers, write hand-built offers, and call
# `_set_tie_break!` directly.

const _TB_N = 4
const _TB_START = DateTime(2025, 1, 1, 0, 5)

# A NEM replay System on the mock hive, with its replay inputs written by `nem_system`.
function _tb_mock_system()
    hive = mktempdir()
    create_mock_data(hive; complete_inputs = true)
    write_mock_interconnector_results(hive)
    db = aem_connect(HiveConfiguration(hive_location = hive))
    return nem_system(db, NEMDEConfiguration(); date_range = _TB_START:Minute(5):(_TB_START + Minute(20)))
end

# The first `n` stamps of the offers written by the helpers below.
_tb_steps(n::Int) = collect(_TB_START .+ Minute.(5 .* (0:(n - 1))))

# Repeats the last of `curves` to the `_TB_N` stamps of the mock System, so every series has the same length.
_tb_pad(curves) = [curves; fill(last(curves), _TB_N - length(curves))]

# Removes the energy offers, the tie-break scales and the EnergyTieBreak service of `sys`, so the writer can run again.
function _tb_strip!(sys)
    AEM = AustralianElectricityMarkets
    for device in AEM._bidding_devices(sys), side in (AEM.OfferSide.GEN, AEM.OfferSide.LOAD)
        remove_series_and_forecast!(sys, device, AEM.energy_offer_series_name(side))
    end
    for device in PowerSystems.get_components(PowerSystems.StaticInjection, sys), key in collect(PowerSystems.get_time_series_keys(device))
        startswith(PowerSystems.IS.get_name(key), "tie_break_scale_") &&
            remove_series_and_forecast!(sys, device, PowerSystems.IS.get_name(key))
    end
    service = PowerSystems.get_component(EnergyTieBreak, sys, TIE_BREAK_SERVICE_NAME)
    isnothing(service) || PowerSystems.remove_component!(sys, service)
    return sys
end

# A price band list as a `PiecewiseStepData`: cumulative MW breakpoints from the widths.
_tb_curve(prices, widths = fill(50.0, length(prices))) = PowerSystems.PiecewiseStepData([0.0; cumsum(widths)], prices)

# Writes `curves` (one per stamp, `_TB_N` of them) as `device`'s energy offer series of `side`.
function _tb_write_offers!(sys, device, side, curves)
    AEM = AustralianElectricityMarkets
    series = AEM.single_series(AEM.energy_offer_series_name(side), _TB_START, collect(curves), Minute(5))
    PowerSystems.add_time_series!(sys, device, series)
    return
end

# The first `n` available units that carry an energy bid on `side`, moved onto the region of the first: the mock
# has one such unit per region, and a tie is only read within a region.
function _tb_units(sys, side, n::Int)
    AEM = AustralianElectricityMarkets
    candidates = PowerSystems.Component[]
    for device in AEM._bidding_devices(sys)
        PowerSystems.get_available(device) || continue
        cost = AEM._nem_offer_cost(device)
        isnothing(cost) && continue
        isnothing(AEM._energy_bid(cost, side)) && continue
        push!(candidates, device)
    end
    length(candidates) >= n || error("fewer than $n available units bid on $side")
    units = candidates[1:n]
    area = PowerSystems.get_area(PowerSystems.get_bus(first(units)))
    for device in units[2:end]
        PowerSystems.set_area!(PowerSystems.get_bus(device), area)
    end
    return units
end

# The scale series of `device` for band `k` on the GEN side (or the LOAD side when `decremental`), or `nothing`.
function _tb_scale(sys, device, k::Int; decremental::Bool = false)
    name = AustralianElectricityMarkets.tie_break_series_name(k, decremental)
    PowerSystems.has_time_series(device, PowerSystems.SingleTimeSeries, name) || return nothing
    return PowerSystems.get_time_series_values(PowerSystems.SingleTimeSeries, device, name; ignore_scaling_factors = true)
end

@testset "tie_break_scale is the band width over the widest band of its group" begin
    AEM = AustralianElectricityMarkets
    @test AEM.tie_break_scale(30.0, 60.0) == 0.5
    @test AEM.tie_break_scale(30.0, 0.0) == 0.0
end

@testset "tie groups" begin
    AEM = AustralianElectricityMarkets
    band(price, name, band = 1) = (; price, name, band)
    tol = TIE_BREAK_CVP_FACTOR
    groups = AEM.tie_groups
    @test groups([band(5.0, "a"), band(5.0, "b"), band(5.0, "c")]) == [[1, 2, 3]]
    # A run of one unit's bands is no group; zero-width bands are grouped like any other.
    @test groups([band(5.0, "a", 1), band(5.0, "a", 2), band(7.0, "b")]) == Vector{Int}[]
    @test groups([band(5.0, "a", 2), band(5.0, "a", 1), band(5.0, "b")]) == [[2, 1, 3]]
    # Prices beyond the tolerance stay separate, within it they tie; a transitive chain throws.
    @test groups([band(5.0, "a"), band(5.0 + 2tol, "b")]) == Vector{Int}[]
    @test groups([band(5.0, "a"), band(5.0 + 0.5tol, "b")]) == [[1, 2]]
    @test_throws r"transitive ties are not supported" groups([band(5.0, "a"), band(5.0 + 0.8tol, "b"), band(5.0 + 1.6tol, "c")])
end

@testset "the writer scales the tied bands and attaches the service once" begin
    AEM = AustralianElectricityMarkets
    sys = _tb_strip!(_tb_mock_system())
    g1, g2 = _tb_units(sys, AEM.OfferSide.GEN, 2)
    # G1 and G2 tie at $10 and $20: widths 5 vs 2 at $10 and 10 vs 13 at $20.
    _tb_write_offers!(sys, g1, AEM.OfferSide.GEN, fill(_tb_curve([10.0, 20.0], [5.0, 10.0]), _TB_N))
    _tb_write_offers!(sys, g2, AEM.OfferSide.GEN, fill(_tb_curve([10.0, 20.0], [2.0, 13.0]), _TB_N))
    AEM._set_tie_break!(sys)

    @test _tb_scale(sys, g1, 1) ≈ fill(1.0, _TB_N)
    @test _tb_scale(sys, g2, 1) ≈ fill(0.4, _TB_N)
    @test _tb_scale(sys, g1, 2) ≈ fill(10.0 / 13.0, _TB_N)
    @test _tb_scale(sys, g2, 2) ≈ fill(1.0, _TB_N)

    services = collect(PowerSystems.get_components(EnergyTieBreak, sys))
    @test length(services) == 1
    service = only(services)
    has_bid(d) = !isnothing(AEM._nem_offer_cost(d)) && !isempty(AEM.get_energy_bids(AEM._nem_offer_cost(d)))
    expected = [
        PowerSystems.get_name(d) for d in PowerSystems.get_available_components(PowerSystems.StaticInjection, sys) if has_bid(d)
    ]
    @test [PowerSystems.get_name(d) for d in PowerSystems.get_contributing_devices(sys, service)] == expected
end

@testset "a system built by nem_system carries the tie-break service once" begin
    sys = _tb_mock_system()
    @test length(collect(PowerSystems.get_components(EnergyTieBreak, sys))) == 1
    @test !isempty(PowerSystems.get_contributing_devices(sys, only(PowerSystems.get_components(EnergyTieBreak, sys))))
end

@testset "the writer scales each band of a tied group over the widest band at its interval" begin
    AEM = AustralianElectricityMarkets
    sys = _tb_strip!(_tb_mock_system())
    cheap, expensive, third = _tb_units(sys, AEM.OfferSide.GEN, 3)
    _tb_write_offers!(sys, cheap, AEM.OfferSide.GEN, fill(_tb_curve([10.0], [168.0]), _TB_N))
    _tb_write_offers!(sys, expensive, AEM.OfferSide.GEN, fill(_tb_curve([10.0, 30.0], [46.0, 10.0]), _TB_N))
    _tb_write_offers!(sys, third, AEM.OfferSide.GEN, fill(_tb_curve([10.0], [122.0]), _TB_N))
    AEM._set_tie_break!(sys)
    @test _tb_scale(sys, cheap, 1) ≈ fill(1.0, _TB_N)
    @test _tb_scale(sys, expensive, 1) ≈ fill(46.0 / 168.0, _TB_N)
    @test _tb_scale(sys, third, 1) ≈ fill(122.0 / 168.0, _TB_N)
    # The $30 band of the expensive unit ties with no other unit, so it carries no scale.
    @test isnothing(_tb_scale(sys, expensive, 2))
end

@testset "a band empty at the first interval but not later keeps its tie and a zero scale" begin
    AEM = AustralianElectricityMarkets
    sys = _tb_strip!(_tb_mock_system())
    cheap, expensive = _tb_units(sys, AEM.OfferSide.GEN, 2)
    cheap_first = _tb_curve([20.0, 50.0], [60.0, 0.0])
    cheap_later = _tb_curve([20.0, 50.0], [60.0, 30.0])
    _tb_write_offers!(sys, cheap, AEM.OfferSide.GEN, [cheap_first; fill(cheap_later, _TB_N - 1)])
    _tb_write_offers!(sys, expensive, AEM.OfferSide.GEN, fill(_tb_curve([20.0, 50.0], [40.0, 40.0]), _TB_N))
    AEM._set_tie_break!(sys)
    @test _tb_scale(sys, cheap, 2) ≈ [0.0; fill(30.0 / 40.0, _TB_N - 1)]
    @test _tb_scale(sys, expensive, 2) ≈ fill(1.0, _TB_N)
end

@testset "bands of a moved price pair fail the build and name the first differing interval" begin
    AEM = AustralianElectricityMarkets
    sys = _tb_strip!(_tb_mock_system())
    cheap, expensive = _tb_units(sys, AEM.OfferSide.GEN, 2)
    # The two bands tie at the first interval only.
    _tb_write_offers!(sys, cheap, AEM.OfferSide.GEN, [_tb_curve([20.0], [60.0]); fill(_tb_curve([25.0], [60.0]), _TB_N - 1)])
    _tb_write_offers!(sys, expensive, AEM.OfferSide.GEN, fill(_tb_curve([20.0], [40.0]), _TB_N))
    @test_throws r"differ from those at" AEM._set_tie_break!(sys)
end

@testset "the pair check reads the offer timestamps and rejects transitive ties" begin
    AEM = AustralianElectricityMarkets
    sys = _tb_strip!(_tb_mock_system())
    cheap, expensive = _tb_units(sys, AEM.OfferSide.GEN, 2)
    stamps = collect(_TB_START:Minute(5):(_TB_START + Minute(5 * (_TB_N - 1))))
    _tb_write_offers!(sys, cheap, AEM.OfferSide.GEN, fill(_tb_curve([20.0], [60.0]), _TB_N))
    _tb_write_offers!(sys, expensive, AEM.OfferSide.GEN, fill(_tb_curve([20.0], [40.0]), _TB_N))
    @test isnothing(AEM._check_tie_break_prices(sys, stamps[1:2]))
    @test_throws r"is not on the offer curve timestamps" AEM._check_tie_break_prices(sys, [_TB_START + Hour(5)])

    # Three units priced 0.8e-6 apart in a chain: the first and last are not tied, but each neighbour is.
    sys = _tb_strip!(sys)
    a, b, c = _tb_units(sys, AEM.OfferSide.GEN, 3)
    _tb_write_offers!(sys, a, AEM.OfferSide.GEN, fill(_tb_curve([20.0], [60.0]), _TB_N))
    _tb_write_offers!(sys, b, AEM.OfferSide.GEN, fill(_tb_curve([20.0 + 0.8e-6], [60.0]), _TB_N))
    _tb_write_offers!(sys, c, AEM.OfferSide.GEN, fill(_tb_curve([20.0 + 1.6e-6], [60.0]), _TB_N))
    @test_throws r"transitive ties are not supported" AEM._check_tie_break_prices(sys, stamps)
end

@testset "the decremental side is scaled by its own tie groups" begin
    AEM = AustralianElectricityMarkets
    sys = _tb_strip!(_tb_mock_system())
    pump, battery = _tb_units(sys, AEM.OfferSide.LOAD, 2)
    _tb_write_offers!(sys, pump, AEM.OfferSide.LOAD, fill(_tb_curve([20.0], [60.0]), _TB_N))
    _tb_write_offers!(sys, battery, AEM.OfferSide.LOAD, fill(_tb_curve([20.0], [40.0]), _TB_N))
    AEM._set_tie_break!(sys)
    @test _tb_scale(sys, pump, 1; decremental = true) ≈ fill(1.0, _TB_N)
    @test _tb_scale(sys, battery, 1; decremental = true) ≈ fill(40.0 / 60.0, _TB_N)
    @test isnothing(_tb_scale(sys, pump, 1))
end

@testset "tie-pair validation preserves fallback and band eligibility" begin
    AEM = AustralianElectricityMarkets
    sys = _tb_mock_system()
    curve(prices, widths = fill(50.0, length(prices))) = _tb_curve(prices, widths)
    cases = [
        ([curve([20.0]), curve([25.0])], [curve([20.0]), curve([25.0])], true),
        ([curve([20.0]), curve([20.0], [0.0])], [curve([20.0]), curve([20.0], [25.0])], true),
        ([curve([20.0, 100.0], [50.0, 0.0]), curve([20.0, 200.0], [50.0, 0.0])], [curve([20.0]), curve([20.0])], true),
        ([curve([20.0, 30.0]), curve([20.0])], [curve([30.0]), curve([30.0])], false),
        ([curve([20.0]), curve([20.0, 30.0])], [curve([30.0]), curve([30.0])], false),
        ([curve([20.0]), curve([20.0, 100.0], [50.0, 0.0])], [curve([20.0]), curve([20.0])], true),
    ]
    for side in (AEM.OfferSide.GEN, AEM.OfferSide.LOAD)
        for (a, b, accepted) in cases
            _tb_strip!(sys)
            unit_a, unit_b = _tb_units(sys, side, 2)
            _tb_write_offers!(sys, unit_a, side, _tb_pad(a))
            _tb_write_offers!(sys, unit_b, side, _tb_pad(b))
            if accepted
                @test isnothing(AEM._check_tie_break_prices(sys, _tb_steps(2)))
            else
                @test_throws r"differ from those at" AEM._check_tie_break_prices(sys, _tb_steps(2))
            end
        end
        # The pair changes at the second and third stamps, and a stamp off the offer timestamps is refused.
        _tb_strip!(sys)
        unit_a, unit_b = _tb_units(sys, side, 2)
        _tb_write_offers!(sys, unit_a, side, _tb_pad([curve([20.0]), curve([30.0]), curve([30.0])]))
        _tb_write_offers!(sys, unit_b, side, fill(curve([30.0]), _TB_N))
        steps = _tb_steps(3)
        @test_throws r"differ from those at" AEM._check_tie_break_prices(sys, steps)
        @test_throws r"is not on the offer curve timestamps" AEM._check_tie_break_prices(sys, [first(steps), last(steps) + Hour(5)])
    end
end

@testset "an empty replay range checks nothing" begin
    AEM = AustralianElectricityMarkets
    sys = _tb_strip!(_tb_mock_system())
    unit_a, unit_b = _tb_units(sys, AEM.OfferSide.GEN, 2)
    _tb_write_offers!(sys, unit_a, AEM.OfferSide.GEN, fill(_tb_curve([20.0], [60.0]), _TB_N))
    _tb_write_offers!(sys, unit_b, AEM.OfferSide.GEN, fill(_tb_curve([20.0], [40.0]), _TB_N))
    @test isnothing(AEM._check_tie_break_prices(sys, DateTime[]))
end


@testset "unchanged prices do not allocate pair sets for every interval" begin
    AEM = AustralianElectricityMarkets
    sys = _tb_mock_system()
    # The 288 stamps of the offers are the only series of the System, so their length is not the mock's.
    PowerSystems.clear_time_series!(sys)
    unit_a, unit_b = _tb_units(sys, AEM.OfferSide.GEN, 2)
    stamps = _tb_steps(288)
    flat = PowerSystems.PiecewiseStepData(collect(0.0:10.0:100.0), fill(20.0, 10))
    _tb_write_offers!(sys, unit_a, AEM.OfferSide.GEN, fill(flat, length(stamps)))
    _tb_write_offers!(sys, unit_b, AEM.OfferSide.GEN, fill(flat, length(stamps)))
    AEM._check_tie_break_prices(sys, stamps[1:1])
    AEM._check_tie_break_prices(sys, stamps)
    short_bytes = @allocated AEM._check_tie_break_prices(sys, stamps[1:1])
    full_bytes = @allocated AEM._check_tie_break_prices(sys, stamps)
    @test full_bytes <= 3 * short_bytes + 256 * 1024
end
