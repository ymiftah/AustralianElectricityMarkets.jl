import AustralianElectricityMarkets as AEM
using Dates: DateTime, Minute
using TimeSeries: TimeArray

const _NW_IS = PowerSystems.IS

const _NW_STAMPS = collect(DateTime(2025, 1, 1):Minute(5):DateTime(2025, 1, 1, 1))
_nw_series(name) = SingleTimeSeries(; name, data = TimeArray(_NW_STAMPS, collect(1.0:length(_NW_STAMPS))))

_nw_key(name::String) = _NW_IS.StaticTimeSeriesKey(;
    time_series_type = PowerSystems.SingleTimeSeries, name,
    initial_timestamp = first(_NW_STAMPS), resolution = Minute(5), length = length(_NW_STAMPS),
    features = Dict{String, Any}(),
)

_nw_key(component, name::String) = only(k for k in _NW_IS.get_time_series_keys(component) if k.name == name)

_nw_interchange(name::String, from::Area, to::Area) = AreaInterchange(;
    name, available = true, active_power_flow = 0.0, from_area = from, to_area = to,
    flow_limits = (from_to = 100.0, to_from = 100.0),
)

@testset "NEM interconnector and MNSP attributes take static and key-backed values" begin
    limits = AEM.NEMInterconnectorLimits(; from_to_limit = 100, to_from_limit = 250)
    @test limits.from_to_limit === 100.0
    @test limits.to_from_limit === 250.0

    bid = AEM.NEMMNSPBid(;
        direction = AEM.MNSPDirection.REVERSE, offer_curves = PowerSystems.PiecewiseStepData([0.0, 10.0], [5.0]),
        max_avail = 80, ramp_up = 1.5, ramp_down = 2.5,
    )
    @test bid.direction == AEM.MNSPDirection.REVERSE
    @test bid.max_avail === 80.0
    @test isnothing(bid.fixed_load)

    @test AEM.NEMMNSPObservedState(; initial_flow = 12).initial_flow === 12.0
    @test AEM.NEMMNSPObservedState(; initial_flow = _nw_key("flow")).initial_flow isa _NW_IS.TimeSeriesKey
end

@testset "NEM interconnector and MNSP attributes survive a System JSON round-trip" begin
    sys = System(100.0)
    nsw = Area(; name = "NSW1")
    vic = Area(; name = "VIC1")
    add_components!(sys, [nsw, vic])
    ic = _nw_interchange("IC1", nsw, vic)
    mnsp = _nw_interchange("T-V-MNSP1", vic, nsw)
    add_components!(sys, [ic, mnsp])

    for name in ("from_to", "flow")
        add_time_series!(sys, ic, _nw_series(name))
    end
    add_time_series!(sys, mnsp, _nw_series("max_fwd"))
    add_time_series!(sys, mnsp, _nw_series("initial_flow"))

    limits = AEM.NEMInterconnectorLimits(; from_to_limit = _nw_key(ic, "from_to"), to_from_limit = 250.0)
    add_supplemental_attribute!(sys, ic, limits)
    add_supplemental_attribute!(
        sys, mnsp,
        AEM.NEMMNSPBid(;
            direction = AEM.MNSPDirection.FORWARD,
            offer_curves = PowerSystems.PiecewiseStepData([0.0, 10.0, 20.0], [5.0, 50.0]),
            max_avail = _nw_key(mnsp, "max_fwd"), ramp_up = 1.0, ramp_down = 2.0, fixed_load = nothing,
        ),
    )
    add_supplemental_attribute!(
        sys, mnsp, AEM.NEMMNSPObservedState(; initial_flow = _nw_key(mnsp, "initial_flow")),
    )

    mktempdir() do dir
        path = joinpath(dir, "sys.json")
        to_json(sys, path; force = true)
        restored = System(path)
        ic_back = get_component(AreaInterchange, restored, "IC1")
        mnsp_back = get_component(AreaInterchange, restored, "T-V-MNSP1")

        back_limits = only(get_supplemental_attributes(AEM.NEMInterconnectorLimits, ic_back))
        @test back_limits.to_from_limit === 250.0
        @test back_limits.from_to_limit isa _NW_IS.TimeSeriesKey
        resolved = _NW_IS.get_time_series_values(
            ic_back, back_limits.from_to_limit; start_time = first(_NW_STAMPS), len = length(_NW_STAMPS),
        )
        @test resolved == collect(1.0:length(_NW_STAMPS))

        back_bid = only(get_supplemental_attributes(AEM.NEMMNSPBid, mnsp_back))
        @test back_bid.direction == AEM.MNSPDirection.FORWARD
        @test back_bid.ramp_up === 1.0
        @test isnothing(back_bid.fixed_load)
        @test back_bid.offer_curves == PowerSystems.PiecewiseStepData([0.0, 10.0, 20.0], [5.0, 50.0])
        @test back_bid.max_avail isa _NW_IS.TimeSeriesKey
        @test _NW_IS.get_time_series_values(
            mnsp_back, back_bid.max_avail; start_time = first(_NW_STAMPS), len = 1,
        ) == [1.0]

        back_state = only(get_supplemental_attributes(AEM.NEMMNSPObservedState, mnsp_back))
        @test _NW_IS.get_time_series_values(
            mnsp_back, back_state.initial_flow; start_time = first(_NW_STAMPS), len = 1,
        ) == [1.0]
    end
end

@testset "GenericConstraint rhs and invoked take static and key-backed values" begin
    gc = GenericConstraint(; name = "N_STATIC", sense = ConstraintSense.LE, rhs = 0)
    @test gc.rhs === 0.0
    @test gc.invoked === true
    @test AEM.get_rhs(gc, first(_NW_STAMPS)) === 0.0
    @test AEM.get_invoked(gc, first(_NW_STAMPS)) === true
end

@testset "GenericConstraint keyed rhs is read in MW with no unit conversion" begin
    # System base is 100 MW, so a per-unit read would return 1.0 and 1.1 instead.
    mw_values = [100.0 + 10.0 * (k - 1) for k in 1:length(_NW_STAMPS)]
    gc = GenericConstraint(; name = "N_MW", sense = ConstraintSense.LE, rhs = _nw_key("mw_rhs"))
    sys = System(100.0)
    add_component!(sys, gc)
    add_time_series!(sys, gc, AEM.single_series("mw_rhs", first(_NW_STAMPS), mw_values, Minute(5)))
    @test AEM.get_rhs(gc, _NW_STAMPS[1]) == 100.0
    @test AEM.get_rhs(gc, _NW_STAMPS[2]) == 110.0
    @test AEM.get_rhs(gc, _NW_STAMPS[2]) isa Float64
end

@testset "GenericConstraint keyed rhs and invoked read their series and survive JSON" begin
    rhs_key = _nw_key("rhs")
    invoked_key = _nw_key("invoked")
    gc = GenericConstraint(;
        name = "N_KEYED", sense = ConstraintSense.GE, rhs = rhs_key, invoked = invoked_key,
    )
    @test gc.rhs isa _NW_IS.TimeSeriesKey
    @test gc.invoked isa _NW_IS.TimeSeriesKey

    sys = System(100.0)
    add_component!(sys, gc)
    add_time_series!(sys, gc, _nw_series("rhs"))
    add_time_series!(
        sys, gc,
        AEM.single_series("invoked", first(_NW_STAMPS), [iseven(k) ? 1.0 : 0.0 for k in 1:length(_NW_STAMPS)], Minute(5)),
    )
    @test AEM.get_rhs(gc, _NW_STAMPS[3]) == 3.0
    @test AEM.get_invoked(gc, _NW_STAMPS[2]) === true
    @test AEM.get_invoked(gc, _NW_STAMPS[3]) === false

    mktempdir() do dir
        path = joinpath(dir, "sys.json")
        to_json(sys, path; force = true)
        back = get_component(GenericConstraint, System(path), "N_KEYED")
        @test back.rhs isa _NW_IS.TimeSeriesKey
        @test back.invoked isa _NW_IS.TimeSeriesKey
        @test AEM.get_rhs(back, _NW_STAMPS[3]) == 3.0
        @test AEM.get_invoked(back, _NW_STAMPS[3]) === false
        @test AEM.get_invoked(back, _NW_STAMPS[2]) === true
    end
end

@testset "NEMBuildReport is read back from a System after a JSON round-trip" begin
    sys = System(100.0)
    @test AEM.get_build_report(sys) == AEM.NEMBuildReport()
    @test isempty(AEM.get_skipped_constraints(sys))

    report = AEM.NEMBuildReport(;
        skipped_constraints = [
            Dict{String, Any}(
                "constraint" => "N_MISSING@2025-01-01#1", "reason" => "no_definition", "missing" => String[],
            ),
        ],
        missing_constraint_intervals = [DateTime(2025, 1, 1, 0, 5)],
        defaulted_constraint_weights = ["N_NULL@2025-01-01#1"],
        dropped_terms = [
            Dict{String, Any}(
                "constraint" => "N_PARTIAL@2025-01-01#1", "kind" => "UNIT", "key" => "GONE",
                "bid_type" => "ENERGY", "factor" => 1.5,
            ),
        ],
    )
    @test AEM.set_build_report!(sys, report) === report
    @test AEM.get_build_report(sys) == report

    mktempdir() do dir
        path = joinpath(dir, "sys.json")
        to_json(sys, path; force = true)
        restored = System(path)
        @test AEM.get_build_report(restored) == report
        @test AEM.get_skipped_constraints(restored).constraint == ["N_MISSING@2025-01-01#1"]
        @test AEM.get_dropped_terms(restored).factor == [1.5]
        @test AEM.get_missing_constraint_intervals(restored) == [DateTime(2025, 1, 1, 0, 5)]
        @test AEM.get_defaulted_constraint_weights(restored) == ["N_NULL@2025-01-01#1"]
    end
end

@testset "set_build_report! stores a copy and hash agrees with ==" begin
    sys = System(100.0)
    dropped() = Dict{String, Any}(
        "constraint" => "N", "kind" => "UNIT", "key" => "K", "bid_type" => "ENERGY", "factor" => 1.0,
    )
    report = AEM.NEMBuildReport(; defaulted_constraint_weights = ["N_W"], dropped_terms = [dropped()])
    AEM.set_build_report!(sys, report)

    push!(report.defaulted_constraint_weights, "LATE")
    report.dropped_terms[1]["key"] = "CHANGED"
    stored = AEM.get_build_report(sys)
    @test stored.defaulted_constraint_weights == ["N_W"]
    @test only(stored.dropped_terms)["key"] == "K"

    twin = AEM.NEMBuildReport(; defaulted_constraint_weights = ["N_W"], dropped_terms = [dropped()])
    @test stored == twin
    @test hash(stored) == hash(twin)
    @test hash(stored) != hash(AEM.NEMBuildReport())
end
