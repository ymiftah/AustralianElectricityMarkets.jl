@testset "effective_ramp_limit takes the lesser of the bid and telemetered rates" begin
    @test effective_ramp_limit(5.0, 240.0) == 240.0
    @test effective_ramp_limit(3.0, 240.0) == 180.0
    @test effective_ramp_limit(NaN, 240.0) == 240.0
    @test isnan(effective_ramp_limit(3.0, NaN))
end

@testset "agc_ramp_rate takes the larger of the ramp and the availability per interval" begin
    @test agc_ramp_rate(1.2, 0.05, 1 / 12) == 1.2
    @test agc_ramp_rate(0.2, 0.05, 1 / 12) == 0.05 / (1 / 12)
    @test agc_ramp_rate(0.2, NaN, 1 / 12) == 0.2
    @test isnan(agc_ramp_rate(NaN, 0.05, 1 / 12))
end

@testset "effective_regulation_max_avail takes the lesser of the bid and telemetered values" begin
    @test effective_regulation_max_avail(50.0, 30.0) == 30.0
    @test effective_regulation_max_avail(20.0, 30.0) == 20.0
    @test effective_regulation_max_avail(NaN, 30.0) == 30.0
    @test isnan(effective_regulation_max_avail(50.0, NaN))
end

# A NEM replay System on the mock hive, with its replay inputs written by `nem_system`.
function _ramps_system()
    hive = mktempdir()
    create_mock_data(hive; complete_inputs = true)
    write_mock_interconnector_results(hive)
    db = aem_connect(HiveConfiguration(hive_location = hive))
    t = DateTime(2025, 1, 1, 0, 5)
    return nem_system(db, NEMDEConfiguration(); date_range = t:Minute(5):(t + Minute(20)))
end

# The stored values of `device`'s series `name`, without the scaling factor.
_ramps_raw(device, name::AbstractString) = get_time_series_values(SingleTimeSeries, device, name; ignore_scaling_factors = true)

# A bid's raw `ROCUP` or `ROCDOWN` on `direction`, MW/min, `NaN` where the device has no such series.
function _ramps_roc(device, field::Symbol, direction, n::Int)
    name = bid_series_name(BidType.ENERGY, field, direction)
    has_time_series(device, SingleTimeSeries, name) || return fill(NaN, n)
    return _ramps_raw(device, name)
end

# The expected ramp rate in per-unit of the base per minute: the lesser of the bid and telemetered
# rates, with a `NaN` telemetered rate or a `NaN` written as zero.
function _ramps_expected(bids, telemetry, base::Real)
    effective = [isnan(t) ? NaN : isnan(b) ? t : min(b * 60, t) for (b, t) in zip(bids, telemetry)]
    return replace(effective ./ 60 ./ base, NaN => 0.0)
end

# The expected rates of a battery bid on both sides: the composite cross-zero rate, capped by telemetry.
function _ramps_expected_storage(device, base::Real, n::Int)
    minutes = Dates.value(Millisecond(Minute(5))) / (1000 * 60 * 60) * 60
    sides = (
        (_ramps_roc(device, :roc_up, BidDirection.GEN, n), _ramps_roc(device, :roc_down, BidDirection.GEN, n)),
        (_ramps_roc(device, :roc_up, BidDirection.LOAD, n), _ramps_roc(device, :roc_down, BidDirection.LOAD, n)),
    )
    initial = _ramps_raw(device, NEM_OBSERVED_SERIES.initial_mw)
    rates = [
        composite_ramp_rates(sides[1][1][i], sides[1][2][i], sides[2][1][i], sides[2][2][i], minutes, NEMUnitState(initial[i], 0))
            for i in eachindex(initial)
    ]
    up = [effective_ramp_limit(rates[i][1], _ramps_raw(device, NEM_TELEMETRY_SERIES.ramp_up_limit)[i]) for i in eachindex(rates)]
    down = [effective_ramp_limit(rates[i][2], _ramps_raw(device, NEM_TELEMETRY_SERIES.ramp_down_limit)[i]) for i in eachindex(rates)]
    return replace(up ./ 60 ./ base, NaN => 0.0), replace(down ./ 60 ./ base, NaN => 0.0)
end

# Removes the ramp and AGC ramp series of every dispatch unit of `sys`, so the writer can run again.
function _ramps_strip!(sys)
    AEM = AustralianElectricityMarkets
    names = (
        NEM_SERIES.ramp_up_rate, NEM_SERIES.ramp_down_rate,
        fcas_series_name("fcas_agc_ramp_rate", BidType.RAISEREG), fcas_series_name("fcas_agc_ramp_rate", BidType.LOWERREG),
    )
    AEM._foreach_nem_dispatch_device(sys) do device
        for name in names
            remove_single_series!(sys, device, name)
        end
    end
    return
end

@testset "the writer gives generators and batteries their ramp rates without AEMSim" begin
    sys = _ramps_system()
    base = get_base_power(sys)
    n = length(_ramps_raw(get_component(ThermalStandard, sys, "ER01"), NEM_TELEMETRY_SERIES.ramp_up_limit))
    for name in ("ER01", "ER02")
        device = get_component(ThermalStandard, sys, name)
        tel_up = _ramps_raw(device, NEM_TELEMETRY_SERIES.ramp_up_limit)
        tel_down = _ramps_raw(device, NEM_TELEMETRY_SERIES.ramp_down_limit)
        @test _ramps_raw(device, NEM_SERIES.ramp_up_rate) ≈ _ramps_expected(_ramps_roc(device, :roc_up, BidDirection.GEN, n), tel_up, base)
        @test _ramps_raw(device, NEM_SERIES.ramp_down_rate) ≈ _ramps_expected(_ramps_roc(device, :roc_down, BidDirection.GEN, n), tel_down, base)
    end
    battery = get_component(EnergyReservoirStorage, sys, "BW01")
    up, down = _ramps_expected_storage(battery, base, n)
    @test _ramps_raw(battery, NEM_SERIES.ramp_up_rate) ≈ up
    @test _ramps_raw(battery, NEM_SERIES.ramp_down_rate) ≈ down
end

@testset "a non-scheduled load is written zero ramp rates" begin
    sys = _ramps_system()
    asload = get_component(InterruptiblePowerLoad, sys, "ASLOAD1")
    @test AustralianElectricityMarkets.is_non_scheduled_load(asload)
    @test all(==(0.0), _ramps_raw(asload, NEM_SERIES.ramp_up_rate))
    @test all(==(0.0), _ramps_raw(asload, NEM_SERIES.ramp_down_rate))
end

@testset "a NaN telemetered ramp limit is written as a zero ramp rate" begin
    AEM = AustralianElectricityMarkets
    sys = _ramps_system()
    base = get_base_power(sys)
    device = get_component(ThermalStandard, sys, "ER01")
    stamps = get_time_series_timestamps(SingleTimeSeries, device, NEM_TELEMETRY_SERIES.ramp_up_limit)
    tel_up = _ramps_raw(device, NEM_TELEMETRY_SERIES.ramp_up_limit)
    tel_up[1] = NaN
    replace_single_series!(sys, device, single_series(NEM_TELEMETRY_SERIES.ramp_up_limit, first(stamps), tel_up, Minute(5)))
    _ramps_strip!(sys)
    AEM._set_dispatch_limits!(sys)
    written = _ramps_raw(device, NEM_SERIES.ramp_up_rate)
    @test written[1] == 0.0
    @test written[2:end] ≈ _ramps_expected(_ramps_roc(device, :roc_up, BidDirection.GEN, length(tel_up)), tel_up, base)[2:end]
end

@testset "a unit without telemetry gets no ramp series, and its telemetry accessor throws" begin
    AEM = AustralianElectricityMarkets
    sys = _ramps_system()
    device = get_component(ThermalStandard, sys, "ER01")
    _ramps_strip!(sys)
    set_telemetry!(device, nothing)
    AEM._set_dispatch_limits!(sys)
    @test !has_time_series(device, SingleTimeSeries, NEM_SERIES.ramp_up_rate)
    @test !has_time_series(device, SingleTimeSeries, NEM_SERIES.ramp_down_rate)
    other = get_component(ThermalStandard, sys, "ER02")
    @test has_time_series(other, SingleTimeSeries, NEM_SERIES.ramp_up_rate)
    err = try
        get_telemetry(device)
        nothing
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin("ER01 has no telemetry", sprint(showerror, err))
end
