# `set_fcas_effective_offers!` against the values the FCAS build reads over one-interval windows.

# A populated system over `date_range`, using the AEM setters for the preprocessing tests.
function fcas_replay_system(db, date_range)
    sys, _ = AustralianElectricityMarkets.RegionModel._constrained_system(db; date_range = date_range)
    set_demand!(sys, db, date_range; resolution = DISPATCH_INTERVAL)
    set_loss_demand_coefficients!(sys)
    set_market_bids!(sys, db, date_range; resolution = DISPATCH_INTERVAL)
    set_fcas_service_bids!(sys, db, date_range; resolution = DISPATCH_INTERVAL)
    set_fcas_scaling_inputs!(sys, db, date_range)
    set_nem_dispatch_limits!(sys, db, date_range)
    set_fcas_effective_offers!(sys)
    set_mnsp_offers!(sys, db, date_range)
    PSY.transform_single_time_series!(sys, DISPATCH_INTERVAL, DISPATCH_INTERVAL)
    return sys
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
        PSY.SingleTimeSeries, PSY.get_component(PSY.Device, sys, name), AustralianElectricityMarkets.fcas_ramping_series_name(bid_type),
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
