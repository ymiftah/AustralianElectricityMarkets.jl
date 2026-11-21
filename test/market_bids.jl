@testset "Market bids" begin
    using AustralianElectricityMarkets
    using PowerSystems
    using Dates
    using DataFrames
    AEM = AustralianElectricityMarkets

    db = aem_connect(HiveConfiguration(hive_location = AEM_TEST_HIVE_DIR, filesystem = "file"))
    interval = DateTime(2025, 1, 1, 0, 5):Minute(5):DateTime(2025, 1, 1, 0, 20)
    grid = collect(interval)[1:(end - 1)]
    series(device, name) = get_time_series_values(SingleTimeSeries, device, name; ignore_scaling_factors = true)
    energy_bid(device, direction) = only(b for b in AEM.get_energy_bids(AustralianElectricityMarkets._nem_offer_cost(device)) if b.direction == direction)
    # The `read_offers` rows of one unit, bid type and direction, keyed by interval stamp.
    function rows_by_stamp(offers, duid, bidtype::BidType, direction::AEM.BidDirection)
        keep = (offers.DUID .== duid) .& (offers.BIDTYPE .== Ref(bidtype)) .& (offers.DIRECTION .== string(direction))
        return Dict(r.INTERVAL_DATETIME => r for r in eachrow(offers[keep, :]))
    end
    _num(x) = ismissing(x) ? 0.0 : Float64(x)
    # A column of `by` on `grid`, zero where a stamp has no row or the value is NULL.
    on_grid(by, column::Symbol) = [haskey(by, t) ? _num(by[t][column]) : 0.0 for t in grid]
    # A column of `by` on `grid`, `NaN` where a stamp has no row or the value is NULL: the fixed load.
    nan_on_grid(by, column::Symbol) = [
        haskey(by, t) && !ismissing(by[t][column]) ? Float64(by[t][column]) : NaN for t in grid
    ]
    _matches(a, b) = length(a) == length(b) && all(isapprox.(a, b))
    # The offer curve of a row, with the bands of a LOAD row in reverse order (as AEMO lists them).
    function row_curve(row, direction::AEM.BidDirection)
        prices, widths = Float64.(row.PRICEBANDARRAY), Float64.(row.BANDAVAILARRAY)
        if direction == AEM.BidDirection.LOAD
            prices, widths = reverse(prices), reverse(widths)
        end
        return (x = [0.0; cumsum(widths)], y = prices)
    end
    # The offer curve on each stamp of `grid`: a zero-width curve on the earliest row's prices where there is no row.
    function expected_curves(by, direction::AEM.BidDirection)
        earliest = row_curve(by[minimum(keys(by))], direction)
        absent = (x = zeros(length(earliest.y) + 1), y = earliest.y)
        return [haskey(by, t) ? row_curve(by[t], direction) : absent for t in grid]
    end

    # One bid system shared by the read-only testsets; ASLOAD1 starts unavailable before the bids.
    bid_sys, _ = nem_network(db; date_range = interval)
    @test !get_available(get_component(InterruptiblePowerLoad, bid_sys, "ASLOAD1"))
    set_market_bids!(bid_sys, db, interval)

    @testset "every bid field equals its read_offers column, on the grid" begin
        offers = read_offers(db, interval)
        n = length(grid)
        mismatches = String[]
        check(ok, device, bid, field) = (ok || push!(mismatches, "$(get_name(device)) $(bid.direction) $field"); return)
        for device in get_components(Device, bid_sys)
            name = get_name(device)
            cost = AEM._nem_offer_cost(device)
            isnothing(cost) && continue
            for bid in AEM.get_energy_bids(cost)
                by = rows_by_stamp(offers, name, BidType.ENERGY, bid.direction)
                curves = bid_value(device, bid, :offer_curves, first(interval), n)
                expected = expected_curves(by, bid.direction)
                check(_matches(get_x_coords.(curves), [e.x for e in expected]), device, bid, :x)
                check(_matches(get_y_coords.(curves), [e.y for e in expected]), device, bid, :y)
                for (field, column) in (
                        (:max_avail, :MAXAVAIL), (:roc_up, :ROCUP), (:roc_down, :ROCDOWN), (:fixed_load, :FIXEDLOAD),
                        (:minimum_load, :MINIMUMLOAD), (:daily_energy_constraint, :DAILYENERGYCONSTRAINT), (:energy_limit, :ENERGYLIMIT),
                    )
                    ok = if isnothing(getfield(bid, field))
                        # FIXEDLOAD of zero is no fixed load, as set_market_bids! reads it.
                        all(r -> ismissing(r[column]) || (field == :fixed_load && iszero(r[column])), values(by))
                    elseif field == :fixed_load
                        isequal(bid_value(device, bid, field, first(interval), n), nan_on_grid(by, column))
                    else
                        _matches(bid_value(device, bid, field, first(interval), n), on_grid(by, column))
                    end
                    check(ok, device, bid, field)
                end
                if isnothing(bid.fast_start_profile)
                    check(all(r -> all(ismissing, (r.T1, r.T2, r.T3, r.T4)), values(by)), device, bid, :fast_start_profile)
                else
                    profile = [[_num(get(by, t, (T1 = missing, T2 = missing, T3 = missing, T4 = missing))[c]) for c in (:T1, :T2, :T3, :T4)] for t in grid]
                    check(_matches([collect(p) for p in bid_value(device, bid, :fast_start_profile, first(interval), n)], profile), device, bid, :fast_start_profile)
                end
                if isnothing(bid.normal_status)
                    check(all(r -> ismissing(r.NORMALSTATUS), values(by)), device, bid, :normal_status)
                else
                    normal = [haskey(by, t) && isequal(by[t].NORMALSTATUS, "ON") for t in grid]
                    check(bid_value(device, bid, :normal_status, first(interval), n) == normal, device, bid, :normal_status)
                end
            end
            for bid in AEM.get_fcas_bids(cost)
                by = rows_by_stamp(offers, name, bid.service, bid.direction)
                curves = bid_value(device, bid, :offer_curves, first(interval), n)
                expected = expected_curves(by, bid.direction)
                check(_matches(get_x_coords.(curves), [e.x for e in expected]), device, bid, :x)
                check(_matches(get_y_coords.(curves), [e.y for e in expected]), device, bid, :y)
                check(_matches(bid_value(device, bid, :max_avail, first(interval), n), on_grid(by, :MAXAVAIL)), device, bid, :max_avail)
                points = bid_value(device, bid, :trapezium, first(interval), n)
                trapezium = [
                    haskey(by, t) ? [_num(by[t][c]) for c in (:ENABLEMENTMIN, :LOWBREAKPOINT, :HIGHBREAKPOINT, :ENABLEMENTMAX)] : zeros(4)
                        for t in grid
                ]
                check(_matches([collect(p) for p in points], trapezium), device, bid, :trapezium)
            end
        end
        @test isempty(mismatches)
    end

    @testset "each bid's series keys are the keys the series were stored under" begin
        keys_checked = Tuple{Any, Any}[]
        for device in get_components(Generator, bid_sys)
            cost = AEM._nem_offer_cost(device)
            isnothing(cost) && continue
            for bid in AEM.get_energy_bids(cost), field in fieldnames(typeof(bid))
                key = getfield(bid, field)
                key isa PowerSystems.IS.StaticTimeSeriesKey || continue
                push!(keys_checked, (key, AEM._series_key(device, PowerSystems.IS.get_name(key))))
            end
        end
        @test !isempty(keys_checked)
        @test all(((key, stored),) -> typeof(key) == typeof(stored) && all(getfield(key, f) == getfield(stored, f) for f in fieldnames(typeof(key))), keys_checked)
    end

    @testset "a registered stamp without an energy row throws, naming the unit" begin
        # BW02's GEN energy and RAISE6SEC rows at 00:10 are removed from the cache, while BW02 is registered.
        gap_db = damaged_cache(
            AEM_TEST_HIVE_DIR, :BIDPEROFFER_D,
            "DELETE FROM input WHERE DUID = 'BW02' AND DIRECTION = 'GEN' AND BIDTYPE IN ('ENERGY', 'RAISE6SEC') AND INTERVAL_DATETIME = TIMESTAMP '2025-01-01 00:10:00'",
        )
        sys, _ = nem_network(gap_db; date_range = interval)
        @test_throws r"BW02 GEN has no energy offer at 2025-01-01T00:10" set_market_bids!(sys, gap_db, interval)
    end

    @testset "NULL fields are nothing when NULL throughout, and zero where NULL on some intervals" begin
        er01 = energy_bid(get_component(ThermalStandard, bid_sys, "ER01"), AEM.BidDirection.GEN)
        @test isnothing(er01.energy_limit)
        @test isnothing(er01.fixed_load)
        # BW02 carries a 50 MW fixed load at 00:10 and 00:15 only.
        @test series(get_component(Device, bid_sys, "BW02"), AEM.bid_series_name(BidType.ENERGY, :fixed_load, AEM.BidDirection.GEN)) == [0.0, 50.0, 50.0]
    end

    @testset "a fixed load is NaN at the intervals where FIXEDLOAD is NULL" begin
        # BW02 publishes 50 MW at 00:10 and 00:15; NULLing the 00:10 row leaves a NaN there.
        null_db = damaged_cache(
            AEM_TEST_HIVE_DIR, :BIDPEROFFER_D,
            "UPDATE input SET FIXEDLOAD = NULL WHERE DUID = 'BW02' AND DIRECTION = 'GEN' AND BIDTYPE = 'ENERGY' AND INTERVAL_DATETIME = TIMESTAMP '2025-01-01 00:10:00'",
        )
        sys, _ = nem_network(null_db; date_range = interval)
        set_market_bids!(sys, null_db, interval)
        bw02 = get_component(Device, sys, "BW02")
        name = AEM.bid_series_name(BidType.ENERGY, :fixed_load, AEM.BidDirection.GEN)
        @test isequal(series(bw02, name), [0.0, NaN, 50.0])
    end

    @testset "fast-start profile is stored as a NTuple and read back as a FastStartProfile" begin
        sys, _ = nem_network(db; date_range = interval, time_series_in_memory = false)
        set_market_bids!(sys, db, interval)
        bw04 = get_component(Device, sys, "BW04")
        bid = energy_bid(bw04, AEM.BidDirection.GEN)
        profile = AEM.bid_value(bw04, bid, :fast_start_profile, first(interval), 3)
        @test profile isa Vector{AEM.FastStartProfile}
        @test all(p -> p.t1 == 10.0, profile)
    end

    @testset "markets restrict the bids, series and services read" begin
        sys, _ = nem_network(db; date_range = interval)
        res = set_market_bids!(sys, db, interval; markets = (BidType.ENERGY, BidType.RAISE6SEC))
        lower = AEM.bid_series_name(BidType.LOWER6SEC, :offer_curves, AEM.BidDirection.GEN)
        @test !any(d -> has_time_series(d, SingleTimeSeries, lower), get_components(Device, sys))
        @test !any(s -> get_bid_type(s) == BidType.LOWER6SEC, get_components(FCASService, sys))
        @test isempty(filter(n -> endswith(n, "LOWER6SEC"), res.added))
        @test any(s -> get_bid_type(s) == BidType.RAISE6SEC, get_components(FCASService, sys))
    end

    @testset "a non-scheduled load with an FCAS bid ends available with a zero LOAD MAXAVAIL and no energy bid" begin
        asload = get_component(InterruptiblePowerLoad, bid_sys, "ASLOAD1")
        @test get_available(asload)
        @test !isempty(AEM.get_fcas_bids(AustralianElectricityMarkets._nem_offer_cost(asload)))
        @test isempty(AEM.get_energy_bids(AustralianElectricityMarkets._nem_offer_cost(asload)))
        max_avail = series(asload, AEM.bid_series_name(BidType.ENERGY, :max_avail, AEM.BidDirection.LOAD))
        @test !isempty(max_avail) && all(==(0.0), max_avail)
    end

    @testset "a regional system gets MarketBidCost curves referred by the loss factor and capped at MAXAVAIL" begin
        sys = nem_system(db, RegionalNetworkConfiguration(); date_range = mock_range_at(first(interval)))
        @test !AEM._is_nemde_system(sys)
        res = set_market_bids!(sys, db, interval)
        @test isempty(res.added) && isempty(res.excluded)
        @test isempty(get_components(FCASService, sys))
        offers = read_offers(db, interval)
        factors = Dict(r.DUID => r for r in eachrow(read_loss_factors(db, interval)))
        checked = 0
        mismatches = String[]
        for device in (d for T in (Generator, ControllableLoad, Storage) for d in get_components(T, sys))
            cost = get_operation_cost(device)
            cost isa MarketBidCost || continue
            name = get_name(device)
            for (direction, getter, factor) in (
                    (AEM.BidDirection.GEN, get_incremental_variable_cost, factors[name].GEN_LOSS_FACTOR),
                    (AEM.BidDirection.LOAD, get_decremental_variable_cost, factors[name].LOAD_LOSS_FACTOR),
                )
                by = rows_by_stamp(offers, name, BidType.ENERGY, direction)
                isempty(by) && continue
                stored = values(getter(device, cost; start_time = first(interval), len = length(grid)))
                stored_curves = [get_function_data(get_value_curve(c)) for c in stored]
                for (k, t) in enumerate(grid)
                    expected = expected_curves(by, direction)[k]
                    cap = haskey(by, t) ? _num(by[t].MAXAVAIL) : 0.0
                    _matches(get_x_coords(stored_curves[k]), min.(expected.x, cap)) || push!(mismatches, "$name $direction x $t")
                    _matches(get_y_coords(stored_curves[k]), expected.y ./ factor) || push!(mismatches, "$name $direction y $t")
                end
                checked += 1
            end
            get_available(device) || push!(mismatches, "$name unavailable")
        end
        @test checked > 0
        @test isempty(mismatches)
        # A regional unit with no GEN offer is set unavailable.
        @test all(d -> get_available(d) == (get_operation_cost(d) isa MarketBidCost), get_components(ThermalStandard, sys))
    end
end
