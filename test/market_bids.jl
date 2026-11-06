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
    energy_bid(device, direction) = only(b for b in AEM.get_energy_bids(get_operation_cost(device)) if b.direction == direction)
    # The `read_offers` rows of one unit, bid type and direction, keyed by interval stamp.
    function rows_by_stamp(offers, duid, bidtype::BidType, direction::AEM.BidDirection)
        keep = (offers.DUID .== duid) .& (offers.BIDTYPE .== Ref(bidtype)) .& (offers.DIRECTION .== string(direction))
        return Dict(r.INTERVAL_DATETIME => r for r in eachrow(offers[keep, :]))
    end
    _num(x) = ismissing(x) ? 0.0 : Float64(x)
    # A column of `by` on `grid`, zero where a stamp has no row or the value is NULL.
    on_grid(by, column::Symbol) = [haskey(by, t) ? _num(by[t][column]) : 0.0 for t in grid]
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

    @testset "every bid field equals its read_offers column, on the grid" begin
        sys, _ = nem_network(db; as_of = first(interval), through = last(interval) - Minute(5))
        offers = read_offers(db, interval)
        set_market_bids!(sys, db, interval)
        n = length(grid)
        for device in get_components(Device, sys)
            name = get_name(device)
            cost = AEM._nem_offer_cost(device)
            isnothing(cost) && continue
            for bid in AEM.get_energy_bids(cost)
                by = rows_by_stamp(offers, name, BidType.ENERGY, bid.direction)
                curves = bid_value(device, bid, :offer_curves, first(interval), n)
                expected = expected_curves(by, bid.direction)
                @test _matches(get_x_coords.(curves), [e.x for e in expected])
                @test _matches(get_y_coords.(curves), [e.y for e in expected])
                for (field, column) in (
                        (:max_avail, :MAXAVAIL), (:roc_up, :ROCUP), (:roc_down, :ROCDOWN), (:fixed_load, :FIXEDLOAD),
                        (:minimum_load, :MINIMUMLOAD), (:daily_energy_constraint, :DAILYENERGYCONSTRAINT), (:energy_limit, :ENERGYLIMIT),
                    )
                    if isnothing(getfield(bid, field))
                        # FIXEDLOAD of zero is no fixed load, as set_market_bids! reads it.
                        @test all(r -> ismissing(r[column]) || (field == :fixed_load && iszero(r[column])), values(by))
                    else
                        @test _matches(bid_value(device, bid, field, first(interval), n), on_grid(by, column))
                    end
                end
                if isnothing(bid.fast_start_profile)
                    @test all(r -> all(ismissing, (r.T1, r.T2, r.T3, r.T4)), values(by))
                else
                    profile = [[_num(get(by, t, (T1 = missing, T2 = missing, T3 = missing, T4 = missing))[c]) for c in (:T1, :T2, :T3, :T4)] for t in grid]
                    @test _matches([collect(p) for p in bid_value(device, bid, :fast_start_profile, first(interval), n)], profile)
                end
                if isnothing(bid.normal_status)
                    @test all(r -> ismissing(r.NORMALSTATUS), values(by))
                else
                    normal = [haskey(by, t) && isequal(by[t].NORMALSTATUS, "ON") for t in grid]
                    @test bid_value(device, bid, :normal_status, first(interval), n) == normal
                end
            end
            for bid in AEM.get_fcas_bids(cost)
                by = rows_by_stamp(offers, name, bid.service, bid.direction)
                curves = bid_value(device, bid, :offer_curves, first(interval), n)
                expected = expected_curves(by, bid.direction)
                @test _matches(get_x_coords.(curves), [e.x for e in expected])
                @test _matches(get_y_coords.(curves), [e.y for e in expected])
                @test _matches(bid_value(device, bid, :max_avail, first(interval), n), on_grid(by, :MAXAVAIL))
                points = bid_value(device, bid, :trapezium, first(interval), n)
                trapezium = [
                    haskey(by, t) ? [_num(by[t][c]) for c in (:ENABLEMENTMIN, :LOWBREAKPOINT, :HIGHBREAKPOINT, :ENABLEMENTMAX)] : zeros(4)
                        for t in grid
                ]
                @test _matches([collect(p) for p in points], trapezium)
            end
        end
    end

    @testset "a LOAD offer curve is stored with its bands in reverse order" begin
        sys, _ = nem_network(db; as_of = first(interval), through = last(interval) - Minute(5))
        offers = read_offers(db, interval)
        set_market_bids!(sys, db, interval)
        pump = get_component(Device, sys, "PUMP1")
        row = rows_by_stamp(offers, "PUMP1", BidType.ENERGY, AEM.BidDirection.LOAD)[first(interval)]
        curve = first(bid_value(pump, energy_bid(pump, AEM.BidDirection.LOAD), :offer_curves, first(interval), 1))
        @test get_y_coords(curve) == reverse(Float64.(row.PRICEBANDARRAY))
        @test get_x_coords(curve) == [0.0; cumsum(reverse(Float64.(row.BANDAVAILARRAY)))]
    end

    @testset "a registered stamp without an energy row throws, naming the unit" begin
        # BW02's GEN energy and RAISE6SEC rows at 00:10 are removed from the cache, while BW02 is registered.
        gap_db = damaged_cache(
            AEM_TEST_HIVE_DIR, :BIDPEROFFER_D,
            "DELETE FROM input WHERE DUID = 'BW02' AND DIRECTION = 'GEN' AND BIDTYPE IN ('ENERGY', 'RAISE6SEC') AND INTERVAL_DATETIME = TIMESTAMP '2025-01-01 00:10:00'",
        )
        sys, _ = nem_network(gap_db; as_of = first(interval), through = last(interval) - Minute(5))
        @test_throws ArgumentError set_market_bids!(sys, gap_db, interval)
    end

    @testset "NULL fields are nothing when NULL throughout, and zero where NULL on some intervals" begin
        sys, _ = nem_network(db; as_of = first(interval), through = last(interval) - Minute(5))
        set_market_bids!(sys, db, interval)
        er01 = energy_bid(get_component(NEMThermalGen, sys, "ER01"), AEM.BidDirection.GEN)
        @test isnothing(er01.energy_limit)
        @test isnothing(er01.fixed_load)
        # BW02 carries a 50 MW fixed load at 00:10 and 00:15 only.
        @test series(get_component(Device, sys, "BW02"), AEM.bid_series_name(BidType.ENERGY, :fixed_load, AEM.BidDirection.GEN)) == [0.0, 50.0, 50.0]
    end

    @testset "fast-start profile is stored as a NTuple and read back as a FastStartProfile" begin
        sys, _ = nem_network(db; as_of = first(interval), through = last(interval) - Minute(5), time_series_in_memory = false)
        set_market_bids!(sys, db, interval)
        bw04 = get_component(Device, sys, "BW04")
        bid = energy_bid(bw04, AEM.BidDirection.GEN)
        profile = AEM.bid_value(bw04, bid, :fast_start_profile, first(interval), 3)
        @test profile isa Vector{AEM.FastStartProfile}
        @test all(p -> p.t1 == 10.0, profile)
    end

    @testset "markets restrict the bids, series and services read" begin
        sys, _ = nem_network(db; as_of = first(interval), through = last(interval) - Minute(5))
        res = set_market_bids!(sys, db, interval; markets = (BidType.ENERGY, BidType.RAISE6SEC))
        lower = AEM.bid_series_name(BidType.LOWER6SEC, :offer_curves, AEM.BidDirection.GEN)
        @test !any(d -> has_time_series(d, SingleTimeSeries, lower), get_components(Device, sys))
        @test !any(s -> get_bid_type(s) == BidType.LOWER6SEC, get_components(FCASService, sys))
        @test isempty(filter(n -> endswith(n, "LOWER6SEC"), res.added))
        @test any(s -> get_bid_type(s) == BidType.RAISE6SEC, get_components(FCASService, sys))
    end

    @testset "a registered unit without an energy offer at an interval throws, naming it" begin
        wide = DateTime(2025, 1, 1, 0, 5):Minute(5):DateTime(2025, 1, 1, 8)
        sys, _ = nem_network(db; as_of = first(wide), through = last(wide) - Minute(5))
        @test_throws r"\w+ (GEN|LOAD) has no energy offer at" set_market_bids!(sys, db, wide)
    end

    @testset "a non-scheduled load with an FCAS bid ends available and bids no energy" begin
        sys, _ = nem_network(db; as_of = first(interval), through = last(interval) - Minute(5))
        asload = get_component(NEMLoad, sys, "ASLOAD1")
        @test !get_available(asload)
        set_market_bids!(sys, db, interval)
        @test get_available(asload)
        @test !isempty(AEM.get_fcas_bids(get_operation_cost(asload)))
        @test isempty(AEM.get_energy_bids(get_operation_cost(asload)))
    end

    @testset "loss factors are kept in each bidding unit's registration" begin
        sys, _ = nem_network(db; as_of = first(interval), through = last(interval) - Minute(5))
        set_market_bids!(sys, db, interval)
        for storage in get_components(NEMStorage, sys)
            @test get_registration(storage).gen_loss_factor > 0.0
            @test get_registration(storage).load_loss_factor > 0.0
        end
    end
end
