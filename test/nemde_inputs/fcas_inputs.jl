# The inputs the FCAS effective-offer writer reads (scaled trapeziums, energy limits, storage fallback) over a window,
# checked against the raw bid, telemetry and AGC series. AEMSim is not loaded here.

# The FCAS writer's window over `horizon` intervals from `start`: the inputs are per-unit of the system base.
function _fcas_writer_window(device, start, horizon::Integer; resolution = Minute(5))
    AEM = AustralianElectricityMarkets
    stamps = [start + (i - 1) * resolution for i in 1:horizon]
    return AEM._fcas_window(device, stamps, resolution, AEM._fcas_system_base(device))
end

# The scaled FCAS trapeziums of `device`'s bid for `service`, per-unit of the system base, as the writer builds its offers.
function _scaled_pu(device, service::BidType, start, horizon::Integer; decremental::Bool = false, resolution = Minute(5))
    window = _fcas_writer_window(device, start, horizon; resolution)
    return AustralianElectricityMarkets._fcas_scaled_trapeziums(window, device, service, decremental)
end

# The same trapeziums in MW (the slope coefficients are dimensionless and stay as they are).
function _scaled_trapeziums(device, service::BidType, start, horizon::Integer; decremental::Bool = false, resolution = Minute(5))
    base = AustralianElectricityMarkets._fcas_system_base(device)
    return [
        AustralianElectricityMarkets.FCASTrapezium(;
            enablement_min = t.enablement_min * base, low_breakpoint = t.low_breakpoint * base,
            high_breakpoint = t.high_breakpoint * base, enablement_max = t.enablement_max * base, max_avail = t.max_avail * base,
        ) for t in _scaled_pu(device, service, start, horizon; decremental, resolution)
    ]
end

# The unscaled FCAS trapeziums of `device`'s bid for `service`, in MW, read from the bid series.
function _raw_trapeziums(device, service::BidType, start, horizon::Integer; decremental::Bool = false)
    AEM = AustralianElectricityMarkets
    bid = AEM._fcas_side_bid(device, service, AEM.offer_side(decremental))
    stamps = [start + (i - 1) * Minute(5) for i in 1:horizon]
    points = AEM._fcas_bid_window(device, bid.trapezium, :trapezium, stamps)
    max_avail = AEM._fcas_bid_window(device, bid.max_avail, :max_avail, stamps)
    return [
        AEM.FCASTrapezium(;
            enablement_min = Float64(p[1]), low_breakpoint = Float64(p[2]), high_breakpoint = Float64(p[3]),
            enablement_max = Float64(p[4]), max_avail = Float64(m),
        ) for (p, m) in zip(points, max_avail)
    ]
end

# Records an FCAS bid of `device` over `stamps` on the side of `decremental`: `trapeziums` are
# `(EnablementMin, LowBreakpoint, HighBreakpoint, EnablementMax, MaxAvail)` and `bands` the `(MW, price)` bands per stamp.
function _fi_add_fcas_offer!(sys, device, stamps, bid_type, trapeziums, bands; decremental = false)
    AEM = AustralianElectricityMarkets
    direction = decremental ? AEM.BidDirection.LOAD : AEM.BidDirection.GEN
    field(f::Symbol) = AEM.bid_series_name(bid_type, f, direction)
    resolution = Minute(5)
    curves = [PowerSystems.PiecewiseStepData([0.0; cumsum(first.(bs))], last.(bs)) for bs in bands]
    points = [(Float64(a), Float64(b), Float64(c), Float64(d)) for (a, b, c, d, _) in trapeziums]
    max_avail = [Float64(e) for (_, _, _, _, e) in trapeziums]
    replace_series_and_forecast!(sys, device, AEM.single_series(field(:offer_curves), stamps[1], curves, resolution))
    replace_series_and_forecast!(sys, device, AEM.single_series(field(:max_avail), stamps[1], max_avail, resolution))
    replace_series_and_forecast!(sys, device, AEM.single_series(field(:trapezium), stamps[1], points, resolution))
    bid = AEM.NEMFCASBid(;
        service = bid_type, direction, offer_curves = AEM._series_key(device, field(:offer_curves)),
        max_avail = AEM._series_key(device, field(:max_avail)), trapezium = AEM._series_key(device, field(:trapezium)),
    )
    AEM._set_fcas_bid!(AEM._nem_offer_cost(device), bid)
    return
end

@testset "FCAS scaling inputs of the effective-offer writer" begin
    db = aem_connect(HiveConfiguration(hive_location = AEM_TEST_HIVE_DIR, filesystem = "file"))
    sys_base, _ = nem_network(db; date_range = MOCK_DATE_RANGE)
    resolution = Minute(5)
    start_date = DateTime(2025, 1, 1, 0, 0)
    date_range = start_date:resolution:(start_date + Hour(2))
    horizon = length(date_range) - 1

    # PUMP1 with regulation bids of `trap` on both services, its DISPATCHLOAD row edited by `update`.
    function pump_regulation(update, trap)
        rates_db = damaged_cache(AEM_TEST_HIVE_DIR, :DISPATCHLOAD, "UPDATE input SET $update, RAISEREGENABLEMENTMIN = 0, RAISEREGENABLEMENTMAX = 0, LOWERREGENABLEMENTMIN = 0, LOWERREGENABLEMENTMAX = 0 WHERE DUID = 'PUMP1'")
        sys = deepcopy(sys_base)
        set_market_bids!(sys, db, date_range; resolution = resolution)
        set_available!(get_component(ThermalStandard, sys, "ER02"), false)
        load = get_component(InterruptiblePowerLoad, sys, "PUMP1")
        stamps = [start_date + (i - 1) * resolution for i in 1:horizon]
        for service in (BidType.RAISEREG, BidType.LOWERREG)
            _fi_add_fcas_offer!(sys, load, stamps, service, fill(trap, horizon), fill([(20.0, 10.0)], horizon); decremental = true)
        end
        set_unit_conditions!(sys, rates_db, date_range)
        AustralianElectricityMarkets._set_nemde_inputs!(sys)
        return with_units_base(sys, "NATURAL_UNITS") do
            Dict(s => get_max_avail.(_scaled_trapeziums(load, s, start_date, horizon; decremental = true)) for s in (BidType.RAISEREG, BidType.LOWERREG))
        end
    end

    @testset "load regulation scaling uses consumption ramp direction" begin
        scaled = pump_regulation("RAMPUPRATE = 120, RAMPDOWNRATE = 60", (0.0, 10.0, 90.0, 100.0, 20.0))
        @test scaled[BidType.RAISEREG] ≈ fill(5.0, horizon)
        @test scaled[BidType.LOWERREG] ≈ fill(10.0, horizon)
    end

    @testset "load regulation availability pairs with its own service" begin
        # 60 MW per 5 minutes is LOWERREGAVAILABILITY; the up ramp rate alone would give 15.
        scaled = pump_regulation("RAMPUPRATE = 180, RAMPDOWNRATE = 720, RAISEREGAVAILABILITY = 0, LOWERREGAVAILABILITY = 60", (0.0, 10.0, 90.0, 100.0, 100.0))
        @test scaled[BidType.LOWERREG] ≈ fill(60.0, horizon)
        @test scaled[BidType.RAISEREG] ≈ fill(60.0, horizon)
    end

    @testset "the scaled FCAS trapezium skips scaling only at an absent interval" begin
        sys = deepcopy(sys_base)
        set_market_bids!(sys, db, date_range; resolution = resolution)
        set_unit_conditions!(sys, db, date_range)
        device = get_component(ThermalStandard, sys, "ER01")
        full_grid = collect(date_range)[1:(end - 1)]
        # 60 MW/h is a 5 MW AGC ramping capability over 5 minutes.
        ramp = [t == first(full_grid) ? NaN : 60.0 for t in full_grid]
        replace_series_and_forecast!(sys, device, single_series(AustralianElectricityMarkets.NEM_TELEMETRY_SERIES.ramp_up_limit, full_grid, ramp))
        AustralianElectricityMarkets._set_nemde_inputs!(sys)
        raw, scaled = with_units_base(sys, "NATURAL_UNITS") do
            (_raw_trapeziums(device, BidType.RAISEREG, start_date, horizon), _scaled_trapeziums(device, BidType.RAISEREG, start_date, horizon))
        end
        @test get_max_avail(raw[1]) > 5.0
        # Without a ramp rate at an interval, the ramp limit there is zero.
        @test get_time_series_values(SingleTimeSeries, device, "ramp_up_rate")[1] == 0.0
        @test isequal(get_max_avail(scaled[1]), get_max_avail(raw[1]))
        @test all(i -> isapprox(get_max_avail(scaled[i]), min(get_max_avail(raw[i]), 5.0)), 2:horizon)
    end

    sys = deepcopy(sys_base)
    set_market_bids!(sys, db, date_range; resolution = resolution)
    set_unit_conditions!(sys, db, date_range)
    AustralianElectricityMarkets._set_nemde_inputs!(sys)

    @testset "FCAS trapeziums are read from the bid series" begin
        device = get_component(ThermalStandard, sys, "ER01")
        raw = _raw_trapeziums(device, BidType.RAISEREG, start_date, horizon)
        bid(field) = AustralianElectricityMarkets.bid_series_name(BidType.RAISEREG, field, AustralianElectricityMarkets.BidDirection.GEN)
        points = get_time_series_values(SingleTimeSeries, device, bid(:trapezium); ignore_scaling_factors = true)
        max_avail = get_time_series_values(SingleTimeSeries, device, bid(:max_avail); ignore_scaling_factors = true)
        @test length(raw) == horizon
        @test all(i -> collect(Tuple(raw[i]))[1:5] == [Float64.(points[i])...; Float64(max_avail[i])], eachindex(raw))
    end

    @testset "the scaled FCAS trapezium matches the bid series on load-side and bidirectional bids" begin
        AEM = AustralianElectricityMarkets
        load_side_checks = 0
        bidirectional_checks = 0
        mismatched = String[]
        with_units_base(sys, "NATURAL_UNITS") do
            for device in nem_dispatch_devices(sys), service in AEM.FCAS_BID_TYPES
                is_regulation = service in AEM.FCAS_REGULATION_MARKETS
                telemetry = AEM.get_telemetry(device)
                direction = fcas_bid_direction(device, service)
                for side in (OfferSide.GEN, OfferSide.LOAD)
                    isnothing(AEM._fcas_side_bid(device, service, side)) && continue
                    decremental = side == OfferSide.LOAD
                    base = get_base_power(sys)
                    raw = [
                        AEM.FCASTrapezium(;
                            enablement_min = t.enablement_min / base, low_breakpoint = t.low_breakpoint / base,
                            high_breakpoint = t.high_breakpoint / base, enablement_max = t.enablement_max / base, max_avail = t.max_avail / base,
                        ) for t in _raw_trapeziums(device, service, start_date, horizon; decremental)
                    ]
                    window = _fcas_writer_window(device, start_date, horizon; resolution)
                    # The AGC and UIGF inputs of the writer, read from the same telemetry.
                    enablement = is_regulation ? AEM._fcas_pair_window(
                            device,
                            service == BidType.RAISEREG ? telemetry.raise_reg_enablement : telemetry.lower_reg_enablement,
                            window.stamps, window.base,
                        ) : (nothing, nothing)
                    agc_max = is_regulation ? AEM._fcas_agc_capability(window, device, AEM._fcas_ramp_rate_service(device, service)) : nothing
                    input_at(series, i) = (isnothing(series) || isnan(series[i])) ? nothing : series[i]
                    expected = [
                        AEM.scale_fcas_trapezium(
                            raw[i];
                            agc_enablement_min = is_regulation ? input_at(enablement[1], i) : nothing,
                            agc_enablement_max = is_regulation ? input_at(enablement[2], i) : nothing,
                            agc_max_avail = input_at(agc_max, i),
                            uigf = input_at(window.uigf, i),
                            is_regulation = is_regulation,
                        ) for i in 1:horizon
                    ]
                    scaled = _scaled_pu(device, service, start_date, horizon; decremental, resolution)
                    all(i -> isequal(Tuple(scaled[i]), Tuple(expected[i])), 1:horizon) || push!(mismatched, "$(get_name(device)) $service $side")
                    decremental && (load_side_checks += 1)
                    direction == FCASBidDirection.BOTH && (bidirectional_checks += 1)
                end
            end
        end
        @test isempty(mismatched)
        @test load_side_checks > 0
        @test bidirectional_checks > 0
    end

    @testset "the AGC ramping capability is the MW/h ramp rate times the interval length" begin
        device = get_component(ThermalStandard, sys, "ER01")
        rows = sort(subset(read_unit_conditions(db, date_range), :DUID => ByRow(==("ER01"))), :SETTLEMENTDATE)
        raw_mw = with_units_base(() -> get_max_avail.(_raw_trapeziums(device, BidType.RAISEREG, start_date, horizon)), sys, "NATURAL_UNITS")
        for (resolution_i, hours) in ((Minute(5), 5 / 60), (Minute(30), 0.5))
            scaled_i = with_units_base(sys, "NATURAL_UNITS") do
                _scaled_trapeziums(device, BidType.RAISEREG, start_date, horizon; resolution = resolution_i)
            end
            @test isapprox(
                get_max_avail.(scaled_i),
                min.(raw_mw, max.(rows.RAMPUPRATE, rows.RAISEREGAVAILABILITY .* 12) .* hours); atol = 1.0e-6,
            )
        end
    end
end

@testset "the storage energy limits fall back to the static ratings when a side has no energy bid" begin
    AEM = AustralianElectricityMarkets
    sys = deepcopy(_FW_SYS)
    battery = first(filter(AEM.has_nem_unit_data, collect(get_components(EnergyReservoirStorage, sys))))
    start = DateTime(2025, 1, 1, 0, 5)
    window = _fcas_writer_window(battery, start, 2)
    # With both energy bids the limits are the bids' MAXAVAIL series, MW per interval.
    bid_limits = AEM._fcas_energy_limits(window, battery)
    @test length(bid_limits.gen) == 2 && length(bid_limits.load) == 2
    # Dropping the load-side energy bid leaves a side with no MAXAVAIL: both sides read the static ratings, per-unit of the system base.
    cost = AEM._nem_offer_cost(battery)
    filter!(b -> AEM._energy_offer_side(b.direction) != OfferSide.LOAD, cost.energy)
    limits = AEM._fcas_energy_limits(window, battery)
    rating = with_units_base(sys, "NATURAL_UNITS") do
        (get_output_active_power_limits(battery).max, get_input_active_power_limits(battery).max)
    end
    @test limits.gen ≈ fill(rating[1] / get_base_power(sys), 2)
    @test limits.load ≈ fill(rating[2] / get_base_power(sys), 2)
end

@testset "a NaN energy availability is carried to the FCAS kernels" begin
    avail = AustralianElectricityMarkets.effective_energy_availability([NaN, 5.0], nothing, [60.0, 60.0], false)
    @test isnan(avail[1]) && avail[2] == 5.0
end

# The energy limits the FCAS writer reads for `device` over `horizon` intervals from `start`, in MW.
function _energy_limits_mw(device, start, horizon::Integer)
    window = _fcas_writer_window(device, start, horizon)
    limits = AustralianElectricityMarkets._fcas_energy_limits(window, device)
    return (; gen = limits.gen .* window.base, load = limits.load .* window.base)
end

@testset "the energy limits of the FCAS writer" begin
    AEM = AustralianElectricityMarkets
    db = aem_connect(HiveConfiguration(hive_location = AEM_TEST_HIVE_DIR, filesystem = "file"))
    start_date = DateTime(2025, 1, 1, 0, 0)
    date_range = start_date:Minute(5):(start_date + Hour(2))
    horizon = length(date_range) - 1
    BD = AEM.BidDirection
    bid_values(device, direction) = get_time_series_values(
        SingleTimeSeries, device, AEM.bid_series_name(BidType.ENERGY, :max_avail, direction);
        start_time = start_date, len = horizon, ignore_scaling_factors = true,
    )
    sys = first(nem_network(db; date_range = MOCK_DATE_RANGE))
    set_market_bids!(sys, db, date_range; resolution = Minute(5))
    set_available!(get_component(ThermalStandard, sys, "ER02"), false)
    set_available!(get_component(HydroDispatch, sys, "BW02"), false)
    set_unit_conditions!(sys, db, date_range)
    AEM._set_nemde_inputs!(sys)

    @testset "a storage device reads its MAXAVAIL on each side" begin
        for bat in get_components(EnergyReservoirStorage, sys)
            avail = _energy_limits_mw(bat, start_date, horizon)
            @test avail.gen ≈ bid_values(bat, BD.GEN) atol = 1.0e-9
            @test avail.load ≈ bid_values(bat, BD.LOAD) atol = 1.0e-9
        end
    end

    @testset "a semi-scheduled unit's availability is its MAXAVAIL limited by its UIGF" begin
        renewable = get_component(RenewableDispatch, sys, "BW03")
        uigf = get_time_series_values(SingleTimeSeries, renewable, get_name(get_telemetry(renewable).uigf); start_time = start_date, len = horizon)
        @test isapprox(_energy_limits_mw(renewable, start_date, horizon).gen, min.(bid_values(renewable, BD.GEN), uigf); atol = 1.0e-8)
    end

    @testset "a scheduled unit's availability is exactly its energy MAXAVAIL" begin
        device = get_component(ThermalStandard, sys, "ER01")
        @test _energy_limits_mw(device, start_date, horizon).gen ≈ bid_values(device, BD.GEN) atol = 1.0e-9
    end

    @testset "a non-scheduled load without an energy bid reads zero availability" begin
        asload = get_component(InterruptiblePowerLoad, sys, "ASLOAD1")
        @test AEM.is_non_scheduled_load(asload) && isempty(AEM.get_energy_bids(AEM._nem_offer_cost(asload)))
        @test all(==(0.0), _energy_limits_mw(asload, start_date, horizon).gen)
    end

    @testset "an interval with no DISPATCHLOAD row (NaN ramp) has zero availability" begin
        device = get_component(ThermalStandard, sys, "ER01")
        full_grid = collect(date_range)[1:(end - 1)]
        ramps = fill(60.0, length(full_grid))
        ramps[2] = NaN
        replace_series_and_forecast!(sys, device, single_series(NEM_TELEMETRY_SERIES.ramp_up_limit, full_grid, ramps))
        avail = _energy_limits_mw(device, start_date, horizon).gen
        @test avail[2] == 0.0
        @test avail[1] > 0.0
    end
end
