@testset "System build coverage and JSON round-trip" begin
    # The PSCB fixture's builder-call sequence (nem_system cannot build it), then a JSON round-trip of the result.
    db = aem_connect(HiveConfiguration(hive_location = AEM_TEST_PSCB_HIVE_DIR, filesystem = "file"))
    start_date = DateTime(2025, 1, 1, 0, 0)
    date_range = start_date:Minute(5):(start_date + Hour(2) + Minute(5))
    sys = nem_pscb_system()
    set_market_bids!(sys, db, date_range)
    build_constraints!(sys, db, date_range)
    attach_interconnector_losses!(sys, db, first(date_range))
    # One station shared by two generators, attached after the build.
    station = NEMStation(; station_id = "STN1", station_name = "Station One", postcode = "3000")
    for name in ("Alta", "Brighton")
        add_supplemental_attribute!(sys, get_component(Generator, sys, name), station)
    end

    path = joinpath(mktempdir(), "sys.json")
    to_json(sys, path; force = true)
    sys2 = System(path)

    # Terms compared field by field: a RegionTerm holds a device list that does not compare by identity.
    terms(gc) = [(typeof(t), (getfield(t, f) for f in fieldnames(typeof(t)))...) for t in get_terms(gc)]
    describe(gc) = (
        get_sense(gc), terms(gc), get_fcas_requirements(gc), _constraint_series(gc, :rhs), _constraint_series(gc, :invoked),
        get_constraint_weight(gc), get_ext(gc), get_gencon_id(gc), get_limit_type(gc), get_source(gc),
        get_effective_date(gc), get_version_no(gc),
    )
    constraints = sort!(collect(get_components(GenericConstraint, sys)); by = get_name)
    @test length(constraints) == 7
    @test sort!(get_name.(get_components(GenericConstraint, sys2))) == get_name.(constraints)
    @test all(gc -> length(_constraint_series(gc, :rhs)) == length(date_range) - 1, constraints)
    @test [describe(get_component(GenericConstraint, sys2, get_name(gc))) for gc in constraints] == describe.(constraints)
    region_term = only(filter(t -> t isa RegionTerm, get_terms(get_component(GenericConstraint, sys2, "F_R1_RAISE6SEC@2025-01-01#1"))))
    @test !isempty(get_devices(region_term))

    for name in ("1_RAISE6SEC", "2_LOWERREG")
        members(s) = sort!([get_name(d) for d in get_components(StaticInjection, s) if has_service(d, get_component(FCASService, s, name))])
        @test !isempty(members(sys))
        @test members(sys2) == members(sys)
    end

    # The loss model's demand coefficients keep their concrete type across the round-trip.
    model = only(get_supplemental_attributes(InterconnectorLossModel, get_component(AreaInterchange, sys2, "IC1")))
    @test model.interconnector == "IC1"
    @test model.demand_coefficients isa Dict{String, Float64}

    for name in ("Alta", "Brighton")
        stn = only(get_supplemental_attributes(NEMStation, get_component(Generator, sys2, name)))
        @test (stn.station_id, stn.station_name, stn.postcode) == ("STN1", "Station One", "3000")
    end
end
