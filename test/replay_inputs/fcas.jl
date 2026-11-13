# The effective FCAS offers and regulation ramping limits that nem_system writes, read back against the
# raw bid, telemetry and observed series of the mock replay hive. AEMSim is not loaded here.

function _fw_system()
    hive = mktempdir()
    create_mock_data(hive; complete_inputs = true)
    write_mock_interconnector_results(hive)
    db = aem_connect(HiveConfiguration(hive_location = hive))
    t = DateTime(2025, 1, 1, 0, 5)
    return nem_system(db, NEMDEConfiguration(); date_range = t:Minute(5):(t + Minute(30)))
end

# The raw FCAS bid of `device` for `service` on `side`.
function _fw_bid(device, service::BidType, side::OfferSide)
    AEM = AustralianElectricityMarkets
    cost = AEM._nem_offer_cost(device)
    return only(b for b in get_fcas_bids(cost) if b.service == service && AEM._fcas_bid_side(device, b) == side)
end

_fw_written(device, name::String) = get_time_series_values(SingleTimeSeries, device, name; ignore_scaling_factors = true)

# The UIGF of `device` over `stamps` in MW, or `nothing` for a unit without one.
function _fw_uigf(device, stamps)
    uigf = get_telemetry(device).uigf
    isnothing(uigf) && return nothing
    uigf isa PowerSystems.IS.StaticTimeSeriesKey || return fill(Float64(uigf), length(stamps))
    return PowerSystems.IS.get_time_series_values(device, uigf; start_time = first(stamps), len = length(stamps))
end

@testset "nem_system writes the effective FCAS offers of contingency markets" begin
    AEM = AustralianElectricityMarkets
    sys = _fw_system()
    base = get_base_power(sys)
    inactive = FCAS_INACTIVE_LIMIT_MW / base
    checked = 0
    for device in AEM._bidding_devices(sys), bid_type in FCAS_CONTINGENCY_MARKETS, decremental in (false, true)
        name = fcas_effective_series_name(bid_type, decremental)
        has_time_series(device, SingleTimeSeries, name) || continue
        bid = _fw_bid(device, bid_type, offer_side(decremental))
        stamps = get_time_series_timestamps(SingleTimeSeries, device, PowerSystems.IS.get_name(bid.trapezium))
        n = length(stamps)
        written = _fw_written(device, name)
        @test length(written) == n
        points = PowerSystems.IS.get_time_series_values(device, bid.trapezium; start_time = first(stamps), len = n)
        max_avail = PowerSystems.IS.get_time_series_values(device, bid.max_avail; start_time = first(stamps), len = n)
        curves = PowerSystems.IS.get_time_series_values(device, bid.offer_curves; start_time = first(stamps), len = n)
        uigf = _fw_uigf(device, stamps)
        for t in 1:n
            entry = written[t]
            if iszero(entry[1])
                # A disabled offer has zero MaxAvail and no bands, and enablement limits at the inactive limit.
                @test entry[2] ≈ -inactive
                @test entry[3] ≈ inactive
                @test all(iszero, entry[4:15])
                continue
            end
            checked += 1
            # The effective trapezium of an enabled contingency offer is the bid's own, in per-unit of the base,
            # except that a semi-scheduled unit's EnablementMax is limited by its UIGF.
            @test entry[1] * base ≈ max_avail[t]
            @test entry[2] * base ≈ points[t][1]
            maximum_enablement = points[t][4]
            if !isnothing(uigf) && !isnan(uigf[t])
                maximum_enablement = min(maximum_enablement, uigf[t])
            end
            @test entry[3] * base ≈ maximum_enablement
            # The band widths are the offer curve's quantities in per-unit of the base, zero-padded.
            xs = get_x_coords(curves[t])
            @test sum(entry[6:15]) * base ≈ last(xs) - first(xs)
        end
    end
    @test checked > 0
end

@testset "nem_system writes the joint ramping limits of regulation markets" begin
    AEM = AustralianElectricityMarkets
    sys = _fw_system()
    inactive = FCAS_INACTIVE_LIMIT_MW / get_base_power(sys)
    written = 0
    for device in AEM._bidding_devices(sys), bid_type in FCAS_REGULATION_MARKETS
        name = fcas_ramping_series_name(bid_type)
        has_time_series(device, SingleTimeSeries, name) || continue
        written += 1
        for (joint, bdu) in _fw_written(device, name)
            # Each limit is a finite right-hand side or the inactive limit on its own form.
            @test isfinite(joint)
            @test isfinite(bdu)
            @test abs(joint) <= inactive
        end
    end
    @test written > 0
end

@testset "a curve with more bands than FCAS_BAND_COUNT is refused" begin
    curve = PowerSystems.PiecewiseStepData(collect(0.0:11.0), fill(10.0, 11))
    @test_throws ArgumentError AustralianElectricityMarkets._fcas_band_widths(curve, 100.0)
end
