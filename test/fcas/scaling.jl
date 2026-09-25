@testset "FCAS trapezium scaling" begin
    using AustralianElectricityMarkets
    using Test

    "Round every field of an `FCASTrapezium` to `digits`, for exact-value assertions."
    trap_tuple(t::FCASTrapezium; digits::Int = 9) = (
        round(get_enablement_min(t); digits = digits), round(get_low_breakpoint(t); digits = digits),
        round(get_high_breakpoint(t); digits = digits), round(get_enablement_max(t); digits = digits),
        round(get_max_avail(t); digits = digits),
    )

    @testset "§4.1 AGC enablement limits (regulation only)" begin
        bid = FCASTrapezium(;
            enablement_min = 20.0, low_breakpoint = 50.0, high_breakpoint = 70.0,
            enablement_max = 100.0, max_avail = 30.0,
        )

        @testset "AGC limits more restrictive: enablement moves in, breakpoints preserve slope" begin
            eff = scale_fcas_trapezium(
                bid; agc_enablement_min = 30.0, agc_enablement_max = 90.0, is_regulation = true,
            )
            @test trap_tuple(eff) == (30.0, 60.0, 60.0, 90.0, 30.0)
            @test get_lower_slope_coeff(eff) == get_lower_slope_coeff(bid)
            @test get_upper_slope_coeff(eff) == get_upper_slope_coeff(bid)
        end

        @testset "AGC limits less restrictive than the bid: no impact" begin
            eff = scale_fcas_trapezium(
                bid; agc_enablement_min = 0.0 - 1.0, agc_enablement_max = 200.0, is_regulation = true,
            )
            @test trap_tuple(eff) == trap_tuple(bid)
        end

        @testset "contingency service: AGC enablement input is ignored" begin
            eff = scale_fcas_trapezium(
                bid; agc_enablement_min = 30.0, agc_enablement_max = 90.0, is_regulation = false,
            )
            @test trap_tuple(eff) == trap_tuple(bid)
        end

        @testset "zero AGC enablement limit is treated as absent, not as a genuine narrow value" begin
            negative_bid = FCASTrapezium(;
                enablement_min = -10.0, low_breakpoint = -5.0, high_breakpoint = 5.0,
                enablement_max = 10.0, max_avail = 5.0,
            )
            eff = scale_fcas_trapezium(negative_bid; agc_enablement_min = 0.0, is_regulation = true)
            @test trap_tuple(eff) == trap_tuple(negative_bid)
        end

        @testset "absent (nothing) AGC enablement limits: no impact" begin
            eff = scale_fcas_trapezium(bid; is_regulation = true)
            @test trap_tuple(eff) == trap_tuple(bid)
        end

        @testset "a load-side (negative net-MW axis) trapezium narrows like any other" begin
            load_bid = FCASTrapezium(;
                enablement_min = -100.0, low_breakpoint = -70.0, high_breakpoint = -10.0,
                enablement_max = 0.0, max_avail = 30.0,
            )
            eff = scale_fcas_trapezium(
                load_bid; agc_enablement_min = -80.0, agc_enablement_max = 90.0, is_regulation = true,
            )
            @test trap_tuple(eff) == (-80.0, -50.0, -10.0, 0.0, 30.0)
        end

        @testset "an AGC window that would invert a side's own span is not applied to either bound" begin
            load_bid = FCASTrapezium(;
                enablement_min = -100.0, low_breakpoint = -70.0, high_breakpoint = -10.0,
                enablement_max = 0.0, max_avail = 30.0,
            )
            gen_bid = FCASTrapezium(;
                enablement_min = 0.0, low_breakpoint = 20.0, high_breakpoint = 80.0,
                enablement_max = 100.0, max_avail = 20.0,
            )
            eff_load = scale_fcas_trapezium(
                load_bid; agc_enablement_min = 368.39502, agc_enablement_max = 0.0, is_regulation = true,
            )
            eff_gen = scale_fcas_trapezium(
                gen_bid; agc_enablement_min = 368.39502, agc_enablement_max = 0.0, is_regulation = true,
            )
            @test trap_tuple(eff_load) == trap_tuple(load_bid)
            @test trap_tuple(eff_gen) == trap_tuple(gen_bid)
        end
    end

    @testset "§4.2 AGC ramp rate (regulation only)" begin
        bid = FCASTrapezium(;
            enablement_min = 20.0, low_breakpoint = 40.0, high_breakpoint = 80.0,
            enablement_max = 100.0, max_avail = 20.0,
        )

        @testset "AGC ramping capability more restrictive: plateau and breakpoints narrow" begin
            eff = scale_fcas_trapezium(bid; agc_max_avail = 10.0, is_regulation = true)
            @test trap_tuple(eff) == (20.0, 30.0, 90.0, 100.0, 10.0)
            @test get_lower_slope_coeff(eff) == get_lower_slope_coeff(bid)
            @test get_upper_slope_coeff(eff) == get_upper_slope_coeff(bid)
        end

        @testset "AGC ramping capability less restrictive than the bid: no impact" begin
            eff = scale_fcas_trapezium(bid; agc_max_avail = 100.0, is_regulation = true)
            @test trap_tuple(eff) == trap_tuple(bid)
        end

        @testset "contingency service: AGC ramp input is ignored" begin
            eff = scale_fcas_trapezium(bid; agc_max_avail = 10.0, is_regulation = false)
            @test trap_tuple(eff) == trap_tuple(bid)
        end

        @testset "zero AGC ramping capability is treated as absent" begin
            eff = scale_fcas_trapezium(bid; agc_max_avail = 0.0, is_regulation = true)
            @test trap_tuple(eff) == trap_tuple(bid)
        end
    end

    @testset "§4.3 UIGF (all services, semi-scheduled units)" begin
        bid = FCASTrapezium(;
            enablement_min = 0.0, low_breakpoint = 0.0, high_breakpoint = 80.0,
            enablement_max = 100.0, max_avail = 20.0,
        )

        @testset "UIGF more restrictive than EnablementMax: high breakpoint slides in" begin
            eff = scale_fcas_trapezium(bid; uigf = 90.0, is_regulation = false)
            @test trap_tuple(eff) == (0.0, 0.0, 70.0, 90.0, 20.0)
            @test get_upper_slope_coeff(eff) == get_upper_slope_coeff(bid)
        end

        @testset "UIGF less restrictive than EnablementMax: no impact" begin
            eff = scale_fcas_trapezium(bid; uigf = 150.0, is_regulation = false)
            @test trap_tuple(eff) == trap_tuple(bid)
        end

        @testset "applies to a regulation trapezium too" begin
            eff = scale_fcas_trapezium(bid; uigf = 90.0, is_regulation = true)
            @test trap_tuple(eff) == (0.0, 0.0, 70.0, 90.0, 20.0)
        end

        @testset "zero UIGF is NOT treated as absent: clamps EnablementMax to zero" begin
            eff = scale_fcas_trapezium(bid; uigf = 0.0, is_regulation = false)
            @test get_enablement_max(eff) == 0.0
            @test get_high_breakpoint(eff) == 0.0
        end
    end

    @testset "combined §4.1 + §4.2 + §4.3 scaling" begin
        bid = FCASTrapezium(;
            enablement_min = 0.0, low_breakpoint = 10.0, high_breakpoint = 90.0,
            enablement_max = 100.0, max_avail = 20.0,
        )
        eff = scale_fcas_trapezium(
            bid;
            agc_enablement_min = 5.0, agc_enablement_max = 95.0, agc_max_avail = 10.0,
            uigf = 80.0, is_regulation = true,
        )
        @test trap_tuple(eff) == (5.0, 10.0, 75.0, 80.0, 10.0)
    end

    @testset "ramp rates carry through unscaled" begin
        bid = FCASTrapezium(;
            enablement_min = 20.0, low_breakpoint = 40.0, high_breakpoint = 80.0,
            enablement_max = 100.0, max_avail = 20.0, ramp_up_rate = 60.0, ramp_down_rate = 30.0,
        )
        eff = scale_fcas_trapezium(bid; agc_max_avail = 10.0, is_regulation = true)
        @test get_ramp_up_rate(eff) == 60.0
        @test get_ramp_down_rate(eff) == 30.0
    end
end
