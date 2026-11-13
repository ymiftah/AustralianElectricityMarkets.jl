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

@testset "the written joint ramping limit equals the §6.1 rule on the observed state" begin
    AEM = AustralianElectricityMarkets
    sys = _fw_system()
    base = get_base_power(sys)
    inactive = FCAS_INACTIVE_LIMIT_MW / base
    active_rows = 0
    inactive_rows = 0
    for device in nem_dispatch_devices(sys), service in (BidType.RAISEREG, BidType.LOWERREG)
        name = fcas_ramping_series_name(service)
        has_time_series(device, SingleTimeSeries, name) || continue
        stamps = get_time_series_timestamps(SingleTimeSeries, device, name)
        window = AEM._fcas_window(device, stamps, Minute(5), AEM._fcas_system_base(device))
        caps = AEM._fcas_capability_values(
            AEM._fcas_agc_capability(window, device, AEM._fcas_ramp_rate_service(device, service)), length(stamps),
        )
        # The writer's own enablement is the non-state half of its ramping rule.
        direction = fcas_bid_direction(device, service)
        sides = Dict{Bool, AEM._FCASSide}(dec => AEM._fcas_side(window, device, service, dec) for dec in AEM.fcas_offer_sides(direction))
        enabled = AEM._fcas_regulation_enabled(window, device, service, direction, sides, AEM._fcas_energy_limits(window, device))
        upper = service == fcas_upper_regulation_service(device)
        written = [entry[1] for entry in _fw_written(device, name)]
        for i in eachindex(stamps)
            state = window.states[i]
            if AEM.fcas_ramping_active(caps[i], state) && enabled[i] && !AEM.fcas_joint_ramping_exempt(state, window.fast_start[i])
                @test AEM.fcas_ramping_limit(caps[i], upper, state) ≈ written[i] rtol = 1.0e-12
                active_rows += 1
            else
                @test written[i] ≈ (upper ? inactive : -inactive)
                inactive_rows += 1
            end
        end
    end
    @test active_rows > 0
    @test inactive_rows > 0
end

@testset "the written FCAS enablement equals the §5 pre-conditions and the stranded rule on the observed state" begin
    AEM = AustralianElectricityMarkets
    sys = _fw_system()
    # The §5 pre-conditions of one side other than the stranded one, per interval of `window`.
    function preconditions(window, device, service, decremental)
        side = AEM._fcas_side(window, device, service, decremental)
        energy = AEM._fcas_energy_limits(window, device)
        regulation = service in FCAS_REGULATION_MARKETS
        return map(eachindex(side.trapeziums)) do t
            AEM.fcas_preconditions_ok(
                side.trapeziums[t], side.total_width[t], energy.gen[t], energy.load[t], window.agc_status[t],
                regulation, decremental, device isa PowerSystems.Storage,
            )
        end
    end
    both_sides = 0
    one_side = 0
    for device in nem_dispatch_devices(sys)
        for service in unique(b.service for b in get_fcas_bids(AEM._nem_offer_cost(device)))
            direction = fcas_bid_direction(device, service)
            direction == FCASBidDirection.NONE && continue
            decremental = direction == FCASBidDirection.DECREMENTAL
            side = direction == FCASBidDirection.DECREMENTAL ? OfferSide.LOAD : OfferSide.GEN
            bid = AEM._fcas_side_bid(device, service, side)
            stamps = get_time_series_timestamps(SingleTimeSeries, device, PowerSystems.IS.get_name(bid.trapezium))
            has_time_series(device, SingleTimeSeries, fcas_effective_series_name(service, decremental)) || continue
            window = AEM._fcas_window(device, stamps, Minute(5), AEM._fcas_system_base(device))
            active(dec) = Bool[entry[1] > 0.0 for entry in _fw_written(device, fcas_effective_series_name(service, dec))]
            if direction == FCASBidDirection.BOTH
                gen_traps = AEM._fcas_side(window, device, service, false).trapeziums
                load_traps = AEM._fcas_side(window, device, service, true).trapeziums
                gen_ok = preconditions(window, device, service, false)
                load_ok = preconditions(window, device, service, true)
                derived = [
                    AEM.fcas_both_sides_stranded_ok(gen_traps[i], load_traps[i], gen_ok[i], load_ok[i], window.states[i])
                        for i in eachindex(stamps)
                ]
                @test [flag[1] for flag in derived] == active(false)
                @test [flag[2] for flag in derived] == active(true)
                both_sides += 1
            else
                traps = AEM._fcas_side(window, device, service, decremental).trapeziums
                ok = preconditions(window, device, service, decremental)
                derived = [
                    ok[i] && AEM.fcas_state_stranded_ok(traps[i], window.states[i], device isa PowerSystems.Storage)
                        for i in eachindex(stamps)
                ]
                @test derived == active(decremental)
                one_side += 1
            end
        end
    end
    @test one_side > 0
end

@testset "the FCAS writer refuses a missing bid, a static bid field and a device without telemetry" begin
    AEM = AustralianElectricityMarkets
    sys = _fw_system()
    # A generator bids its generation side only, so it has no load-side bid.
    generator = first(
        d for d in AEM._bidding_devices(sys)
            if d isa PowerSystems.ThermalStandard && fcas_bid_direction(d, BidType.RAISE6SEC) == FCASBidDirection.INCREMENTAL
    )
    window = AEM._fcas_window(generator, [DateTime(2025, 1, 1, 0, 5)], Minute(5), get_base_power(sys))
    err = try
        AEM._fcas_scaled_trapeziums(window, generator, BidType.RAISE6SEC, true)
        nothing
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin("has no FCAS bid for RAISE6SEC on LOAD", err.msg)
    @test occursin(get_name(generator), err.msg)
    @test_throws ArgumentError AEM._fcas_series_key(generator, 5.0, :trapezium)
    # A device with NEM unit data but no telemetry cannot supply its window inputs.
    bare = first(get_components(PowerSystems.ThermalStandard, first(nem_network(aem_connect(HiveConfiguration(hive_location = AEM_TEST_HIVE_DIR, filesystem = "file"))))))
    @test_throws ArgumentError AEM._fcas_window(bare, [DateTime(2025, 1, 1, 0, 5)], Minute(5), 100.0)
end

@testset "a curve with more bands than FCAS_BAND_COUNT is refused" begin
    curve = PowerSystems.PiecewiseStepData(collect(0.0:11.0), fill(10.0, 11))
    @test_throws ArgumentError AustralianElectricityMarkets._fcas_band_widths(curve, 100.0)
end
