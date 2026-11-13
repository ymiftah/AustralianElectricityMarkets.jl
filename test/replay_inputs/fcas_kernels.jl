# Scalar MW kernels of the FCAS enablement, offer and ramping rules, and the FCAS state rules.

_fk_span() = FCASTrapezium(;
    enablement_min = 0.0, low_breakpoint = 10.0, high_breakpoint = 90.0, enablement_max = 100.0,
    max_avail = 100.0,
)

_fk_negative() = FCASTrapezium(;
    enablement_min = -100.0, low_breakpoint = -90.0, high_breakpoint = -60.0, enablement_max = -50.0,
    max_avail = 100.0,
)

_fk_floor(min) = FCASTrapezium(;
    enablement_min = min, low_breakpoint = min + 10.0, high_breakpoint = 90.0, enablement_max = 100.0,
    max_avail = 100.0,
)

@testset "FCAS name functions and constants" begin
    @test FCAS_BAND_COUNT == 10
    @test FCAS_INACTIVE_LIMIT_MW == 1.0e5
    @test fcas_effective_series_name(BidType.RAISEREG, false) == "fcas_effective_RAISEREG"
    @test fcas_effective_series_name(BidType.LOWERREG, true) == "fcas_effective_LOWERREG_decremental"
    @test fcas_ramping_series_name(BidType.RAISEREG) == "fcas_ramping_limits_RAISEREG"
    @test fcas_offer_sides(FCASBidDirection.INCREMENTAL) == (false,)
    @test fcas_offer_sides(FCASBidDirection.DECREMENTAL) == (true,)
    @test fcas_offer_sides(FCASBidDirection.BOTH) == (false, true)
end

@testset "FCAS pre-conditions in MW" begin
    span = _fk_span()
    # A non-storage unit with an unknown energy availability and AGC status passes.
    @test fcas_preconditions_ok(span, 1.0, NaN, NaN, -1, false, false, false)
    unavailable = FCASTrapezium(; enablement_min = 0.0, low_breakpoint = 10.0, high_breakpoint = 90.0, enablement_max = 100.0, max_avail = 0.0)
    @test !fcas_preconditions_ok(unavailable, 1.0, NaN, NaN, -1, false, false, false)
    # At least one priced band with positive quantity.
    @test !fcas_preconditions_ok(span, 0.0, NaN, NaN, -1, false, false, false)
    # Sign pre-condition: a non-storage unit needs EnablementMax >= 0.
    @test !fcas_preconditions_ok(_fk_negative(), 1.0, NaN, NaN, -1, false, false, false)
    # Energy pre-condition for a non-storage unit: MaxAvail at or above EnablementMin.
    @test !fcas_preconditions_ok(_fk_floor(20.0), 1.0, 10.0, NaN, -1, false, false, false)
    @test fcas_preconditions_ok(_fk_floor(20.0), 1.0, 30.0, NaN, -1, false, false, false)
    # AGC status 0 disables a regulation service only.
    @test !fcas_preconditions_ok(span, 1.0, NaN, NaN, 0, true, false, false)
    @test fcas_preconditions_ok(span, 1.0, NaN, NaN, 1, true, false, false)
    @test fcas_preconditions_ok(span, 1.0, NaN, NaN, 0, false, false, false)
    # A storage device's regulation sign pre-condition is on its generation side, EnablementMax >= 0,
    # and on its load side, EnablementMin <= 0. Its contingency FCAS carries no sign requirement.
    @test !fcas_preconditions_ok(_fk_negative(), 1.0, 0.0, 60.0, -1, true, false, true)
    @test fcas_preconditions_ok(_fk_negative(), 1.0, 0.0, 60.0, -1, true, true, true)
    @test fcas_preconditions_ok(_fk_negative(), 1.0, 0.0, 60.0, -1, false, false, true)
    @test !fcas_preconditions_ok(_fk_negative(), 1.0, 0.0, 40.0, -1, false, false, true)
    # Storage energy pre-conditions: the generation side needs gen >= EnablementMin and the load side
    # needs -load <= EnablementMax. Regulation checks only its own side, contingency checks both.
    @test !fcas_preconditions_ok(span, 1.0, -5.0, 200.0, -1, true, false, true)
    @test fcas_preconditions_ok(span, 1.0, -5.0, 200.0, -1, true, true, true)
    @test !fcas_preconditions_ok(span, 1.0, -5.0, 200.0, -1, false, true, true)
    @test fcas_preconditions_ok(span, 1.0, 50.0, 200.0, -1, false, false, true)
end

@testset "FCAS state pre-conditions move with the starting output" begin
    span = _fk_span()
    @test fcas_state_stranded_ok(span, NEMUnitState(50.0, 4), false)
    @test !fcas_state_stranded_ok(span, NEMUnitState(150.0, 4), false)
    @test fcas_state_stranded_ok(span, NEMUnitState(-50.0, 4), false)
    @test !fcas_state_stranded_ok(span, NEMUnitState(-50.0, 4), true)
    # An unknown starting output fails the pre-condition rather than passing it.
    @test !fcas_state_stranded_ok(span, NEMUnitState(NaN, 4), false)
    @test !fcas_state_stranded_ok(span, NEMUnitState(NaN, 4), true)
    # A bidirectional unit's two regulation sides are gated together while both pass their
    # other pre-conditions.
    gen = FCASTrapezium(;
        enablement_min = 20.0, low_breakpoint = 30.0, high_breakpoint = 80.0, enablement_max = 100.0,
        max_avail = 100.0,
    )
    load = FCASTrapezium(;
        enablement_min = -100.0, low_breakpoint = -80.0, high_breakpoint = -30.0, enablement_max = -20.0,
        max_avail = 100.0,
    )
    @test fcas_both_sides_stranded_ok(gen, load, true, true, NEMUnitState(0.0, 4)) == (true, true)
    @test fcas_both_sides_stranded_ok(gen, load, true, true, NEMUnitState(110.0, 4)) == (false, false)
    @test fcas_both_sides_stranded_ok(gen, load, true, false, NEMUnitState(50.0, 4)) == (true, false)
    @test fcas_both_sides_stranded_ok(gen, load, true, true, NEMUnitState(NaN, 4)) == (false, false)
end

@testset "FCAS effective offer in MW" begin
    span = _fk_span()
    inactive = FCAS_INACTIVE_LIMIT_MW / 100.0
    widths = (0.1, 0.1, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
    @test fcas_effective_offer(span, widths, false, 1.0e5) == (0.0, -1.0e5, 1.0e5, 0.0, 0.0, ntuple(_ -> 0.0, 10)...)
    @test fcas_effective_offer(span, widths, false, inactive) == (0.0, -inactive, inactive, 0.0, 0.0, ntuple(_ -> 0.0, 10)...)
    @test fcas_effective_offer(span, widths, true, inactive) == (
        100.0, 0.0, 100.0, get_upper_slope_coeff(span), get_lower_slope_coeff(span), widths...,
    )
end

@testset "FCAS ramping limits in MW" begin
    state = NEMUnitState(50.0, 0)
    # An inactive regulation market is the inactive limit on each form, and an unknown BDU ramp is inactive.
    @test fcas_ramping_limits(0.0, 0.0, true, true, false, 1.0e5, state) == (1.0e5, 1.0e5)
    @test fcas_ramping_limits(0.0, 0.0, false, false, false, 1.0e5, state) == (-1.0e5, 1.0e5)
    # The §6.1 upper form is InitialMW plus the AGC capability, the lower form minus it.
    @test fcas_ramping_limits(10.0, 0.0, true, true, false, 1.0e5, state) == (60.0, 1.0e5)
    @test fcas_ramping_limits(10.0, 0.0, true, false, false, 1.0e5, state) == (40.0, 1.0e5)
    # A unit not enabled for the market is inactive on its form.
    @test fcas_ramping_limits(10.0, 0.0, false, true, false, 1.0e5, state) == (1.0e5, 1.0e5)
    # A fast-start unit starting in mode 1 is exempt from joint ramping.
    @test fcas_ramping_limits(10.0, 0.0, true, true, true, 1.0e5, NEMUnitState(50.0, 1)) == (1.0e5, 1.0e5)
    @test fcas_ramping_limits(10.0, 0.0, true, true, true, 1.0e5, NEMUnitState(50.0, 3)) == (60.0, 1.0e5)
    # An unknown starting output deactivates the joint row.
    @test fcas_ramping_limits(10.0, 0.0, true, true, false, 1.0e5, NEMUnitState(NaN, 4)) == (1.0e5, 1.0e5)
    # The §6.4 BDU limit is the AGC capability of a device bidding both sides.
    @test fcas_ramping_limits(10.0, 0.2, true, true, false, 1.0e5, state) == (60.0, 0.2)
end
