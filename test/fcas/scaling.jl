@testset "FCAS trapezium scaling" begin
    using AustralianElectricityMarkets
    using Test

    "Round every field of an `FCASTrapezium` to `digits`, for exact-value assertions."
    trap_tuple(t::FCASTrapezium; digits::Int = 9) = (
        round(get_enablement_min(t); digits = digits), round(t.low_breakpoint; digits = digits),
        round(t.high_breakpoint; digits = digits), round(get_enablement_max(t); digits = digits),
        round(get_max_avail(t); digits = digits),
    )
    trap(emin, low, high, emax, avail; kwargs...) = FCASTrapezium(;
        enablement_min = emin, low_breakpoint = low, high_breakpoint = high, enablement_max = emax, max_avail = avail, kwargs...,
    )

    agc_bid = trap(20.0, 50.0, 70.0, 100.0, 30.0)
    ramp_bid = trap(20.0, 40.0, 80.0, 100.0, 20.0; ramp_up_rate = 60.0, ramp_down_rate = 30.0)
    uigf_bid = trap(0.0, 0.0, 80.0, 100.0, 20.0)
    load_bid = trap(-100.0, -70.0, -10.0, 0.0, 30.0)
    gen_bid = trap(0.0, 20.0, 80.0, 100.0, 20.0)

    # (bid, scaling inputs, expected trapezium): §4.1 AGC enablement and §4.2 AGC ramp narrow a regulation
    # trapezium, §4.3 UIGF narrows any; `nothing` expects the bid unchanged.
    cases = [
        # §4.1: more restrictive AGC limits move the enablement in.
        (agc_bid, (agc_enablement_min = 30.0, agc_enablement_max = 90.0, is_regulation = true), (30.0, 60.0, 60.0, 90.0, 30.0)),
        (load_bid, (agc_enablement_min = -80.0, agc_enablement_max = 90.0, is_regulation = true), (-80.0, -50.0, -10.0, 0.0, 30.0)),
        # §4.1 no impact: looser limits, a contingency service, absent limits, a zero limit read as absent.
        (agc_bid, (agc_enablement_min = -1.0, agc_enablement_max = 200.0, is_regulation = true), nothing),
        (agc_bid, (agc_enablement_min = 30.0, agc_enablement_max = 90.0, is_regulation = false), nothing),
        (agc_bid, (is_regulation = true,), nothing),
        (trap(-10.0, -5.0, 5.0, 10.0, 5.0), (agc_enablement_min = 0.0, is_regulation = true), nothing),
        # §4.2: a smaller AGC ramping capability lowers the plateau; looser, contingency or zero is no impact.
        (ramp_bid, (agc_max_avail = 10.0, is_regulation = true), (20.0, 30.0, 90.0, 100.0, 10.0)),
        (ramp_bid, (agc_max_avail = 100.0, is_regulation = true), nothing),
        (ramp_bid, (agc_max_avail = 10.0, is_regulation = false), nothing),
        (ramp_bid, (agc_max_avail = 0.0, is_regulation = true), nothing),
        # §4.3: UIGF slides EnablementMax and the high breakpoint in, for any service; a zero UIGF is a real
        # limit, and a squeezed trapezium keeps its slopes rather than clamping its breakpoints.
        (uigf_bid, (uigf = 90.0, is_regulation = false), (0.0, 0.0, 70.0, 90.0, 20.0)),
        (uigf_bid, (uigf = 90.0, is_regulation = true), (0.0, 0.0, 70.0, 90.0, 20.0)),
        (uigf_bid, (uigf = 150.0, is_regulation = false), nothing),
        (uigf_bid, (uigf = 0.0, is_regulation = false), (0.0, 0.0, -20.0, 0.0, 20.0)),
        (uigf_bid, (uigf = 10.0, is_regulation = false), (0.0, 0.0, -10.0, 10.0, 20.0)),
        # Combined §4.1 + §4.2 + §4.3.
        (
            trap(0.0, 10.0, 90.0, 100.0, 20.0),
            (agc_enablement_min = 5.0, agc_enablement_max = 95.0, agc_max_avail = 10.0, uigf = 80.0, is_regulation = true),
            (5.0, 10.0, 75.0, 80.0, 10.0),
        ),
        # An AGC window outside a side's own span raises EnablementMin past EnablementMax: no feasible FCAS,
        # which §5's EnablementMax >= EnablementMin pre-condition disables.
        (load_bid, (agc_enablement_min = 368.39502, agc_enablement_max = 0.0, is_regulation = true), (368.39502, 398.39502, -10.0, 0.0, 30.0)),
        (gen_bid, (agc_enablement_min = 368.39502, agc_enablement_max = 0.0, is_regulation = true), (368.39502, 388.39502, 80.0, 100.0, 20.0)),
    ]
    for (bid, inputs, expected) in cases
        eff = scale_fcas_trapezium(bid; inputs...)
        @test trap_tuple(eff) == something(expected, trap_tuple(bid))
        # Every scaling keeps both slopes and carries the ramp rates through unscaled.
        @test get_lower_slope_coeff(eff) ≈ get_lower_slope_coeff(bid) && get_upper_slope_coeff(eff) ≈ get_upper_slope_coeff(bid)
        @test isequal((get_ramp_up_rate(eff), get_ramp_down_rate(eff)), (get_ramp_up_rate(bid), get_ramp_down_rate(bid)))
    end
end
