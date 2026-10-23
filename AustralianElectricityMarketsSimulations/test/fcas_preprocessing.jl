# `set_fcas_effective_offers!` against the values the FCAS build reads over one-interval windows.

# The one-interval window FCASMarket reads at `t` under NEMReplayDispatch.
fcas_window(t) = AEMS._FCASWindow(t, 1, DISPATCH_INTERVAL, :dispatch)

# The effective offer FCASMarket builds for one offer at `t`: `(enabled, MaxAvail, EnablementMin,
# EnablementMax, UpperSlopeCoeff, LowerSlopeCoeff, widths)` from the build-time trapezium and masks.
function build_time_offer(device, bid_type, direction, decremental, t)
    w = fcas_window(t)
    enabled = if direction == FCASBidDirection.BOTH
        gen, load = AEMS._fcas_both_sides_enabled_mask(w, device, bid_type)
        only(decremental ? load : gen)
    else
        only(AEMS._fcas_enabled_mask(w, device, bid_type, decremental))
    end
    (; trapeziums, curves) = AEMS._fcas_offer(w, device, bid_type, offer_side(decremental))
    trap, widths = only(trapeziums), diff(PSY.get_x_coords(only(curves)))
    return (; enabled, trap, widths)
end

# A populated system over `date_range`, using the AEM setters for the preprocessing tests.
function fcas_replay_system(db, date_range)
    sys = nem_system(db, ConstrainedNetworkConfiguration(); date_range = date_range)
    set_demand!(sys, db, date_range; resolution = DISPATCH_INTERVAL)
    set_loss_demand_coefficients!(sys)
    set_market_bids!(sys, db, date_range; resolution = DISPATCH_INTERVAL)
    set_fcas_scaling_inputs!(sys, db, date_range)
    set_nem_dispatch_limits!(sys, db, date_range)
    set_fcas_effective_offers!(sys)
    set_mnsp_offers!(sys, db, date_range)
    PSY.transform_single_time_series!(sys, DISPATCH_INTERVAL, DISPATCH_INTERVAL)
    return sys
end

@testset "effective FCAS offers equal the build-time values on every mock interval" begin
    db = aem_connect(HiveConfiguration(hive_location = AEM_TEST_HIVE_DIR, filesystem = "file"))
    start = DateTime(2025, 1, 1, 0, 5)
    sys = fcas_replay_system(db, start:DISPATCH_INTERVAL:(start + 6 * DISPATCH_INTERVAL))
    inactive = FCAS_INACTIVE_LIMIT_MW / PSY.get_base_power(sys)
    counts = Dict(true => 0, false => 0)
    PSY.with_units_base(sys, "SYSTEM_BASE") do
        for svc in PSY.get_components(FCASService, sys), device in PSY.get_contributing_devices(sys, svc)
            bid_type = get_bid_type(svc)
            direction = AEMS._fcas_direction(device, bid_type)
            for decremental in AEMS._fcas_offer_sides(direction)
                name = AEMS._fcas_effective_series_name(bid_type, decremental)
                stamps = PSY.get_time_series_timestamps(PSY.SingleTimeSeries, device, name)
                values = PSY.get_time_series_values(PSY.SingleTimeSeries, device, name)
                @test length(stamps) == 6
                for (t, v) in zip(stamps, values)
                    ref = build_time_offer(device, bid_type, direction, decremental, t)
                    counts[ref.enabled] += 1
                    if ref.enabled
                        @test v[1:5] == (get_max_avail(ref.trap), get_enablement_min(ref.trap), get_enablement_max(ref.trap), get_upper_slope_coeff(ref.trap), get_lower_slope_coeff(ref.trap))
                        @test collect(v[6:15]) == [ref.widths; zeros(10 - length(ref.widths))]
                    else
                        @test v == (0.0, -inactive, inactive, 0.0, 0.0, ntuple(_ -> 0.0, 10)...)
                    end
                end
            end
            bid_type in FCAS_REGULATION_MARKETS || continue
            ramping = PSY.get_time_series_values(PSY.SingleTimeSeries, device, AEMS._fcas_ramping_series_name(bid_type))
            stamps = PSY.get_time_series_timestamps(PSY.SingleTimeSeries, device, AEMS._fcas_ramping_series_name(bid_type))
            for (t, v) in zip(stamps, ramping)
                @test v == only(AEMS._fcas_effective_ramping(fcas_window(t), device, bid_type, direction, inactive))
                caps = only(AEMS._fcas_agc_ramp_caps(fcas_window(t), device, AEMS._fcas_ramp_rate_service(device, bid_type)))
                mw = only(something(get_initial_mw(device, t, 1), [NaN]))
                enabled = only(AEMS._fcas_regulation_enabled_mask(fcas_window(t), device, bid_type, direction))
                upper = bid_type == AEMS._fcas_upper_regulation_service(device)
                active = !iszero(caps) && !isnan(mw) && enabled
                @test v[1] == (active ? (upper ? mw + caps : mw - caps) : (upper ? inactive : -inactive))
            end
        end
    end
    # The mock exercises both enabled and disabled offers.
    @test counts[true] > 0 && counts[false] > 0
end

@testset "set_fcas_effective_offers! masks each interval's offer by its own enablement" begin
    sys = fcas_toy_system(; alta_agc = [1, 0], park_initial = [40.0, 2.0], alta_reg_avail = [15.0, 8.0])
    inactive = FCAS_INACTIVE_LIMIT_MW / PSY.get_base_power(sys)
    values(device, name) = PSY.get_time_series_values(PSY.SingleTimeSeries, PSY.get_component(PSY.Device, sys, device), name)
    alta = values(TOY_CHEAP, "fcas_effective_RAISEREG")
    # Step 1: MaxAvail 15 MW, EnablementMax scaled to the 90 MW AGC limit, slopes (95 - 80) / 15 and (20 - 10) / 15.
    @test collect(alta[1][1:5] .* (1, 100, 100, 1, 1)) ≈ [0.15, 10.0, 90.0, 15 / 15, 10 / 15]
    @test alta[1][6:8] == (0.1, 0.1, 0.0)
    # Step 2: AGC status 0 disables Alta's RAISEREG.
    @test alta[2] == (0.0, -inactive, inactive, 0.0, 0.0, ntuple(_ -> 0.0, 10)...)
    park = values(TOY_EXPENSIVE, "fcas_effective_RAISE6SEC")
    @test park[1][1] ≈ 0.25 && park[2][1] == 0.0
    # The battery bids RAISEREG on both sides; both are enabled at 5 MW net.
    @test values(TOY_BATTERY, "fcas_effective_RAISEREG")[1][1] ≈ 0.1
    @test values(TOY_BATTERY, "fcas_effective_RAISEREG_decremental")[1][1] ≈ 0.1
    # Alta's §6.1 joint ramping limit is InitialMW + 20 MW in step 1 and inactive in step 2.
    ramping = values(TOY_CHEAP, "fcas_ramping_limits_RAISEREG")
    @test ramping[1] == (0.5 + 0.2, inactive) && ramping[2] == (inactive, inactive)
    # The battery's §6.4 limit is its 20 MW AGC ramping capability.
    @test last.(values(TOY_BATTERY, "fcas_ramping_limits_RAISEREG")) ≈ [0.2, 0.2]
end

@testset "joint and BDU ramping limits equal the hand-derived mock values" begin
    db = aem_connect(HiveConfiguration(hive_location = AEM_TEST_HIVE_DIR, filesystem = "file"))
    start = DateTime(2025, 1, 1, 0, 5)
    sys = fcas_replay_system(db, start:DISPATCH_INTERVAL:(start + 6 * DISPATCH_INTERVAL))
    ramping(name, bid_type) = PSY.get_time_series_values(
        PSY.SingleTimeSeries, PSY.get_component(PSY.Device, sys, name), AEMS._fcas_ramping_series_name(bid_type),
    )[1]
    # ER01 (ThermalStandard) RAISEREG at 00:05: InitialMW 45 MW and AGC ramp rate 9 MW/h. The §6.1 upper
    # form is 45 + 9 * 5/60 = 45.75 MW; a unit that is not a BDU has no §6.4 limit.
    @test ramping("ER01", BidType.RAISEREG) ≈ (45.75 / 100, FCAS_INACTIVE_LIMIT_MW / 100) atol = 1.0e-9
    # BW01 (storage) RAISEREG at 00:05: InitialMW 41 MW and AGC ramp rate 5 MW/h. The §6.1 upper form is
    # 41 + 5 * 5/60 MW; the §6.4 BDU limit is the AGC ramp capability, 5 * 5/60 MW.
    @test ramping("BW01", BidType.RAISEREG) ≈ ((41 + 5 * 5 / 60) / 100, (5 * 5 / 60) / 100) atol = 1.0e-9
    # ER01 LOWERREG at 00:05: AGC ramp rate 8 MW/h, so the lower form is 45 - 8 * 5/60 MW; not a BDU.
    @test ramping("ER01", BidType.LOWERREG) ≈ ((45 - 8 * 5 / 60) / 100, FCAS_INACTIVE_LIMIT_MW / 100) atol = 1.0e-9
end
