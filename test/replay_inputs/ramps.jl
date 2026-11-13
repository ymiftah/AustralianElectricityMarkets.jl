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

# A NEM replay System on the mock hive, with its replay inputs written by `nem_system` over `n` stamps from `start`.
function _ramps_system(start::DateTime = DateTime(2025, 1, 1, 0, 5), n::Int = 5)
    hive = mktempdir()
    create_mock_data(hive; complete_inputs = true)
    write_mock_interconnector_results(hive)
    db = aem_connect(HiveConfiguration(hive_location = hive))
    return nem_system(db, NEMDEConfiguration(); date_range = start:Minute(5):(start + Minute(5 * (n - 1))))
end

# The stored values of `device`'s series `name`, without the scaling factor.
_ramps_raw(device, name::AbstractString) = get_time_series_values(SingleTimeSeries, device, name; ignore_scaling_factors = true)

# Replaces the values of `device`'s series `name` on its own stamps; a scalar fills every stamp.
function _ramps_set_series!(sys, device, name::AbstractString, values)
    stamps = PowerSystems.get_time_series_timestamps(SingleTimeSeries, device, name)
    data = values isa Real ? fill(Float64(values), length(stamps)) : values
    replace_single_series!(sys, device, single_series(name, first(stamps), data, Minute(5)))
    return
end

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

# The raw FCAS `MAXAVAIL` of `device`'s bids for `service` that `keep` selects, summed per stamp; `NaN` when none.
function _ramps_bid_avail(device, service::BidType, n::Int, keep)
    AEM = AustralianElectricityMarkets
    cost = AEM._nem_offer_cost(device)
    bids = isnothing(cost) ? NEMFCASBid[] : [b for b in get_fcas_bids(cost) if b.service == service && keep(b)]
    isempty(bids) && return fill(NaN, n)
    series = [
        b.max_avail isa PowerSystems.IS.StaticTimeSeriesKey ? _ramps_raw(device, PowerSystems.IS.get_name(b.max_avail)) : fill(Float64(b.max_avail), n)
            for b in bids
    ]
    return reduce((a, b) -> a .+ b, series)
end

# The expected AGC ramp rates of `device` per unit of the base per hour, as `(RAISEREG, LOWERREG)`. A side is
# `nothing` where the writer writes no series, as its availability or rate is all `NaN`. A controllable load
# takes its raise regulation from the lower availability and the ramp-up rate, and the reverse for lower.
function _ramps_expected_agc(device, n::Int, base::Real; keep = _ -> true)
    hours = Dates.value(Millisecond(Minute(5))) / (1000 * 60 * 60)
    ramp_up = _ramps_raw(device, NEM_TELEMETRY_SERIES.ramp_up_limit) ./ base
    ramp_down = _ramps_raw(device, NEM_TELEMETRY_SERIES.ramp_down_limit) ./ base
    function availability(service, telemetry_name)
        bid = _ramps_bid_avail(device, service, n, keep)
        telemetry = _ramps_raw(device, telemetry_name)
        return [isnan(t) ? NaN : isnan(b) ? t : min(b, t) for (b, t) in zip(bid, telemetry)] ./ base
    end
    raise_availability = availability(BidType.RAISEREG, NEM_TELEMETRY_SERIES.raise_reg_max_avail)
    lower_availability = availability(BidType.LOWERREG, NEM_TELEMETRY_SERIES.lower_reg_max_avail)
    sides = device isa PowerSystems.ControllableLoad ?
        ((ramp_up, lower_availability), (ramp_down, raise_availability)) :
        ((ramp_up, raise_availability), (ramp_down, lower_availability))
    return map(sides) do (ramp, avail)
        all(isnan, avail) && return nothing
        values = [isnan(ramp[i]) ? NaN : isnan(avail[i]) ? ramp[i] : max(ramp[i], avail[i] / hours) for i in eachindex(ramp)]
        return all(isnan, values) ? nothing : values
    end
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

@testset "the AGC ramp rates follow the regulation availability, swapped on a controllable load" begin
    AEM = AustralianElectricityMarkets
    sys = _ramps_system()
    base = get_base_power(sys)
    n = length(_ramps_raw(get_component(ThermalStandard, sys, "ER01"), NEM_TELEMETRY_SERIES.ramp_up_limit))
    written = Dict(:swapped => 0, :plain => 0)
    for device in AEM.nem_dispatch_devices(sys)
        branch = device isa PowerSystems.ControllableLoad ? :swapped : :plain
        for (service, values) in zip((BidType.RAISEREG, BidType.LOWERREG), _ramps_expected_agc(device, n, base))
            name = fcas_series_name("fcas_agc_ramp_rate", service)
            if isnothing(values)
                @test !has_time_series(device, SingleTimeSeries, name)
            else
                @test isapprox(_ramps_raw(device, name), values; nans = true)
                written[branch] += 1
            end
        end
    end
    # Both branches of the swap are exercised: the controllable loads and the other dispatch units.
    @test written[:swapped] > 0
    @test written[:plain] > 0
end

@testset "a device bidding regulation on both sides has the summed bid max availability" begin
    AEM = AustralianElectricityMarkets
    sys = _ramps_system()
    base = get_base_power(sys)
    battery = get_component(EnergyReservoirStorage, sys, "BW01")
    n = length(_ramps_raw(battery, NEM_TELEMETRY_SERIES.ramp_up_limit))
    @test count(b -> b.service == BidType.RAISEREG, get_fcas_bids(AEM._nem_offer_cost(battery))) == 2
    # A telemetered availability above the combined bid leaves the bid sum binding.
    _ramps_set_series!(sys, battery, NEM_TELEMETRY_SERIES.raise_reg_max_avail, 1.0e6)
    _ramps_strip!(sys)
    AEM._set_dispatch_limits!(sys)
    name = fcas_series_name("fcas_agc_ramp_rate", BidType.RAISEREG)
    both = _ramps_expected_agc(battery, n, base)[1]
    one = _ramps_expected_agc(battery, n, base; keep = b -> get_direction(b) != BidDirection.LOAD)[1]
    @test isapprox(_ramps_raw(battery, name), both; nans = true)
    # The second side's bid raises the availability, so the sum changes the written rate.
    @test !isapprox(both, one; nans = true)
end

@testset "a bid rate binds on the side the unit bids, and telemetry binds otherwise" begin
    sys = _ramps_system()
    base = get_base_power(sys)
    er01 = get_component(ThermalStandard, sys, "ER01")
    pump = get_component(InterruptiblePowerLoad, sys, "PUMP1")
    gen_up = bid_series_name(BidType.ENERGY, :roc_up, BidDirection.GEN)
    load_up = bid_series_name(BidType.ENERGY, :roc_up, BidDirection.LOAD)
    load_down = bid_series_name(BidType.ENERGY, :roc_down, BidDirection.LOAD)
    # ER01 bids 0.01 MW/min up on GEN, 0.6 MW/h, below its telemetry. PUMP1 bids the same up on LOAD, and a
    # 100 MW/min down that telemetry binds.
    _ramps_set_series!(sys, er01, gen_up, 0.01)
    _ramps_set_series!(sys, pump, load_up, 0.01)
    _ramps_set_series!(sys, pump, load_down, 100.0)
    _ramps_strip!(sys)
    AustralianElectricityMarkets._set_dispatch_limits!(sys)
    n = length(_ramps_raw(er01, NEM_TELEMETRY_SERIES.ramp_up_limit))
    @test _ramps_raw(er01, NEM_SERIES.ramp_up_rate) ≈ fill(0.6 / 60 / base, n)
    @test _ramps_raw(pump, NEM_SERIES.ramp_up_rate) ≈ fill(0.6 / 60 / base, n)
    @test _ramps_raw(pump, NEM_SERIES.ramp_down_rate) ≈
        _ramps_expected(_ramps_roc(pump, :roc_down, BidDirection.LOAD, n), _ramps_raw(pump, NEM_TELEMETRY_SERIES.ramp_down_limit), base)
    @test _ramps_raw(er01, NEM_SERIES.ramp_down_rate) ≈
        _ramps_expected(_ramps_roc(er01, :roc_down, BidDirection.GEN, n), _ramps_raw(er01, NEM_TELEMETRY_SERIES.ramp_down_limit), base)
end

@testset "the composite blend branch runs for a battery below zero with both sides bid" begin
    # The mock's charging interval (initial output -30 MW at 04:00) has no regional demand after 04:00, so the
    # window stays at 00:05 to 00:25 and the second interval's initial output is set to -30 MW, the same arithmetic.
    sys = _ramps_system()
    base = get_base_power(sys)
    battery = get_component(EnergyReservoirStorage, sys, "BW01")
    n = length(_ramps_raw(battery, NEM_TELEMETRY_SERIES.ramp_up_limit))
    @test has_time_series(battery, SingleTimeSeries, bid_series_name(BidType.ENERGY, :roc_up, BidDirection.LOAD))
    @test has_time_series(battery, SingleTimeSeries, bid_series_name(BidType.ENERGY, :roc_down, BidDirection.LOAD))
    # GEN ROCUP 2 MW/min, LOAD ROCDOWN 10 MW/min and a 1000 MW/h telemetered limit, so the composite rate is written.
    _ramps_set_series!(sys, battery, bid_series_name(BidType.ENERGY, :roc_up, BidDirection.GEN), 2.0)
    _ramps_set_series!(sys, battery, bid_series_name(BidType.ENERGY, :roc_down, BidDirection.LOAD), 10.0)
    _ramps_set_series!(sys, battery, NEM_TELEMETRY_SERIES.ramp_up_limit, 1000.0)
    _ramps_set_series!(sys, battery, NEM_TELEMETRY_SERIES.ramp_down_limit, 1000.0)
    initial_start = fill(50.0, n)
    initial_start[2] = -30.0
    _ramps_set_series!(sys, battery, NEM_OBSERVED_SERIES.initial_mw, initial_start)
    _ramps_strip!(sys)
    AustralianElectricityMarkets._set_dispatch_limits!(sys)
    initial = _ramps_raw(battery, NEM_OBSERVED_SERIES.initial_mw)
    k = findfirst(<(0.0), initial)
    @test k == 2
    minutes = Dates.value(Millisecond(Minute(5))) / (1000 * 60 * 60) * 60
    gen_down = _ramps_roc(battery, :roc_down, BidDirection.GEN, n)
    load_up = _ramps_roc(battery, :roc_up, BidDirection.LOAD, n)
    load_down = _ramps_roc(battery, :roc_down, BidDirection.LOAD, n)
    both = composite_ramp_rates(2.0, gen_down[k], load_up[k], load_down[k], minutes, NEMUnitState(initial[k], 0))
    gen_only = composite_ramp_rates(2.0, gen_down[k], NaN, NaN, minutes, NEMUnitState(initial[k], 0))
    # The blend reaches zero inside the interval: 3 MW of the -30 MW start is ramped at the load rate.
    @test both[1] != gen_only[1]
    @test both[1] ≈ ((minutes - abs(initial[k] / load_down[k])) * 2.0 - initial[k]) / minutes
    written = _ramps_raw(battery, NEM_SERIES.ramp_up_rate)
    @test written[k] ≈ both[1] / base
    @test written[k] != gen_only[1] / base
end

@testset "the dispatch-limit writer writes no upper limit series" begin
    sys = _ramps_system()
    for device in AustralianElectricityMarkets.nem_dispatch_devices(sys)
        @test !has_time_series(device, SingleTimeSeries, NEM_SERIES.max_active_power)
    end
    device = get_component(ThermalStandard, sys, "ER01")
    @test has_time_series(device, SingleTimeSeries, NEM_SERIES.ramp_down_rate)
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
