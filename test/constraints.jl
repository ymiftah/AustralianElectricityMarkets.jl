@testset "Constraint types" begin
    using AustralianElectricityMarkets
    using PowerSystems
    using Dates

    @testset "_pad_to_grid carries the last known value forward" begin
        grid = [DateTime(2025, 1, 1, 0, 5 * i) for i in 0:3]
        values_by_time = Dict(grid[1] => 10.0, grid[3] => 30.0)
        series, invoked = AustralianElectricityMarkets._pad_to_grid(values_by_time, grid, 0.0)
        @test series == [10.0, 10.0, 30.0, 30.0]
        @test invoked == [1.0, 0.0, 1.0, 0.0]

        # A gap before the first known value falls back to initial_fill.
        values_by_time2 = Dict(grid[3] => 30.0)
        series2, invoked2 = AustralianElectricityMarkets._pad_to_grid(values_by_time2, grid, -1.0)
        @test series2 == [-1.0, -1.0, 30.0, 30.0]
        @test invoked2 == [0.0, 0.0, 1.0, 0.0]
    end

    @testset "ConstraintTerm construction and accessors" begin
        ut = UnitTerm("BW01", BidType.RAISE6SEC, 1.0)
        @test get_duid(ut) == "BW01"
        @test get_bid_type(ut) == BidType.RAISE6SEC
        @test get_factor(ut) == 1.0

        it = InterconnectorTerm("IC1", -0.5)
        @test get_interconnector(it) == "IC1"
        @test get_factor(it) == -0.5

        rt = RegionTerm("NSW1", BidType.ENERGY, 2.0)
        @test get_region(rt) == "NSW1"
        @test get_bid_type(rt) == BidType.ENERGY
        @test get_factor(rt) == 2.0
        @test get_devices(rt) == String[]  # sensible default: hand-authored terms still construct

        rt_with_devices = RegionTerm("NSW1", BidType.ENERGY, 2.0, ["BW01", "BW02"])
        @test get_devices(rt_with_devices) == ["BW01", "BW02"]
        rt_kw = RegionTerm(; region = "NSW1", bid_type = BidType.ENERGY, factor = 2.0, devices = ["BW01"])
        @test get_devices(rt_kw) == ["BW01"]

        req = FCASRequirement("NSW1", BidType.RAISEREG)
        @test get_region(req) == "NSW1"
        @test get_service(req) == BidType.RAISEREG
    end

    @testset "GenericConstraint construction and accessors" begin
        gc = GenericConstraint(;
            name = "F_TEST",
            sense = ConstraintSense.GE,
            rhs = 137.5,
            constraint_weight = 2.0,
            terms = ConstraintTerm[UnitTerm("BW01", BidType.RAISE6SEC, 1.0), InterconnectorTerm("IC1", -1.0)],
            fcas_requirements = FCASRequirement[FCASRequirement("TAS1", BidType.RAISE6SEC)],
        )
        @test get_name(gc) == "F_TEST"
        @test get_available(gc) == true
        @test get_sense(gc) == ConstraintSense.GE
        @test get_rhs(gc) == 137.5
        @test get_constraint_weight(gc) == 2.0
        @test length(get_terms(gc)) == 2
        @test length(get_fcas_requirements(gc)) == 1
        @test get_terms(gc)[1] isa UnitTerm

        set_available!(gc, false)
        @test get_available(gc) == false
        set_rhs!(gc, 10.0)
        @test get_rhs(gc) == 10.0
    end

    @testset "GenericConstraint hand-authored: description field, no AEMO provenance" begin
        gc = GenericConstraint(;
            name = "HAND_AUTHORED",
            sense = ConstraintSense.LE,
            rhs = 42.0,
        )
        @test get_description(gc) == ""
        @test get_limit_type(gc) === nothing
        @test get_source(gc) === nothing
        @test get_effective_date(gc) === nothing
        @test get_version_no(gc) === nothing
        @test isempty(get_ext(gc))

        set_description!(gc, "a hand-authored test constraint")
        @test get_description(gc) == "a hand-authored test constraint"
    end

    @testset "GenericConstraint JSON round-trip" begin
        sys = System(100.0)
        gc = GenericConstraint(;
            name = "F_ROUNDTRIP",
            sense = ConstraintSense.GE,
            rhs = 137.5,
            constraint_weight = 2.0,
            description = "test constraint",
            terms = ConstraintTerm[
                UnitTerm("BW01", BidType.RAISE6SEC, 1.0),
                InterconnectorTerm("IC1", -1.0),
                RegionTerm("NSW1", BidType.ENERGY, 0.5, ["BW01", "BW02"]),
            ],
            fcas_requirements = FCASRequirement[FCASRequirement("TAS1", BidType.RAISE6SEC), FCASRequirement("TAS1", BidType.RAISE5MIN)],
        )
        add_component!(sys, gc)

        mktpath = mktempdir()
        json_path = joinpath(mktpath, "sys.json")
        to_json(sys, json_path)
        sys2 = System(json_path)

        gc2 = get_component(GenericConstraint, sys2, "F_ROUNDTRIP")
        @test !isnothing(gc2)
        @test get_sense(gc2) == ConstraintSense.GE
        @test get_rhs(gc2) == 137.5
        @test get_constraint_weight(gc2) == 2.0
        @test get_description(gc2) == "test constraint"
        @test length(get_terms(gc2)) == 3
        @test length(get_fcas_requirements(gc2)) == 2

        unit_term = only(filter(t -> t isa UnitTerm, get_terms(gc2)))
        @test get_duid(unit_term) == "BW01"
        @test get_bid_type(unit_term) == BidType.RAISE6SEC
        ic_term = only(filter(t -> t isa InterconnectorTerm, get_terms(gc2)))
        @test get_interconnector(ic_term) == "IC1"
        region_term = only(filter(t -> t isa RegionTerm, get_terms(gc2)))
        @test get_region(region_term) == "NSW1"
        @test get_devices(region_term) == ["BW01", "BW02"]  # devices survives the JSON round trip

        @test all(r -> get_region(r) == "TAS1", get_fcas_requirements(gc2))
        @test Set(get_service.(get_fcas_requirements(gc2))) == Set([BidType.RAISE6SEC, BidType.RAISE5MIN])
    end
end

@testset "Constraint readers against mock data" begin
    using AustralianElectricityMarkets
    using PowerSystems
    using Dates
    using DataFrames

    hive_dir = AEM_TEST_HIVE_DIR
    config = HiveConfiguration(hive_location = hive_dir, filesystem = "file")
    db = aem_connect(config)
    start_date = DateTime(2025, 1, 1, 0, 0)
    date_range = start_date:Minute(5):(start_date + Hour(1))

    @testset "read_invoked_constraints" begin
        invoked = read_invoked_constraints(db, date_range)
        @test !isempty(invoked)
        @test "N_BAYSW_THERMAL" in invoked.GENCONID
        @test "N_PHANTOM_TEST" in invoked.GENCONID
        f_raise6sec_nsw1 = subset(invoked, :GENCONID => ByRow(==("F_NSW1_RAISE6SEC")))
        sort!(f_raise6sec_nsw1, :SETTLEMENTDATE)
        # RHS = requirement_mw("RAISE6SEC") + 0.1*i = 50.0 + 0.1*i, i = 0..12 over this range
        @test isapprox(first(f_raise6sec_nsw1.RHS), 50.0; atol = 1.0e-9)
        @test issorted(f_raise6sec_nsw1.RHS)  # confirms the RHS actually varies per interval
        @test all(==(DateTime(2025, 1, 1)), f_raise6sec_nsw1.GENCONID_EFFECTIVEDATE)
        @test all(==(1), f_raise6sec_nsw1.GENCONID_VERSIONNO)
    end

    @testset "read_constraint_definitions" begin
        invoked = read_invoked_constraints(db, date_range)
        versions = unique(select(invoked, :GENCONID, :GENCONID_EFFECTIVEDATE, :GENCONID_VERSIONNO))
        defs = read_constraint_definitions(db, versions)
        @test !isempty(defs)
        thermal = only(subset(defs, :GENCONID => ByRow(==("N_BAYSW_THERMAL"))))
        @test thermal.CONSTRAINTTYPE == ">="
        @test thermal.GENERICCONSTRAINTWEIGHT == 1.0
        @test thermal.CONSTRAINTVALUE == 100.0
        raise6sec_nsw1 = only(subset(defs, :GENCONID => ByRow(==("F_NSW1_RAISE6SEC"))))
        @test raise6sec_nsw1.CONSTRAINTVALUE == 50.0
    end

    @testset "empty gencon_versions throws" begin
        empty_versions = DataFrame(GENCONID = String[], GENCONID_EFFECTIVEDATE = DateTime[], GENCONID_VERSIONNO = Int[])
        @test_throws ArgumentError read_constraint_definitions(db, empty_versions)
        @test_throws ArgumentError read_constraint_terms(db, empty_versions, date_range)
    end

    @testset "read_constraint_terms" begin
        invoked = read_invoked_constraints(db, date_range)
        versions = unique(select(invoked, :GENCONID, :GENCONID_EFFECTIVEDATE, :GENCONID_VERSIONNO))
        terms = read_constraint_terms(db, versions, date_range)
        @test !isempty(terms)

        # F_VIC1_RAISE6SEC expands to 4 UnitTerms - every DUID behind CP_BAYSW (BW01-04)
        vic1_terms = subset(terms, :GENCONID => ByRow(==("F_VIC1_RAISE6SEC")))
        @test nrow(vic1_terms) == 4
        @test Set(vic1_terms.KEY) == Set(["BW01", "BW02", "BW03", "BW04"])
        @test all(==("UNIT"), vic1_terms.TERM_KIND)
        @test all(==("RAISE6SEC"), vic1_terms.BIDTYPE)

        # N_PHANTOM_TEST's only term references PHANTOM1, a DUDETAILSUMMARY-only DUID
        phantom_terms = subset(terms, :GENCONID => ByRow(==("N_PHANTOM_TEST")))
        @test nrow(phantom_terms) == 1
        @test only(phantom_terms.KEY) == "PHANTOM1"

        # F_NSW1_RAISEREG has both a UNIT term (its own DUID) and a REGION term
        raisereg_terms = subset(terms, :GENCONID => ByRow(==("F_NSW1_RAISEREG")))
        @test "REGION" in raisereg_terms.TERM_KIND

        # F_NSW1_RAISE6SEC additionally nets IC1
        ic_terms = subset(terms, :GENCONID => ByRow(==("F_NSW1_RAISE6SEC")), :TERM_KIND => ByRow(==("INTERCONNECTOR")))
        @test nrow(ic_terms) == 1
        @test only(ic_terms.KEY) == "IC1"
        @test only(ic_terms.FACTOR) == -1.0
    end

    @testset "read_constraint_fcas_requirements" begin
        reqs = read_constraint_fcas_requirements(db, date_range)
        @test !isempty(reqs)
        @test "N_BAYSW_THERMAL" ∉ reqs.GENCONID  # pure network constraint
        @test "N_PHANTOM_TEST" ∉ reqs.GENCONID
        raise6sec_nsw1 = subset(reqs, :GENCONID => ByRow(==("F_NSW1_RAISE6SEC")))
        @test nrow(raise6sec_nsw1) == 1
        @test only(raise6sec_nsw1.REGIONID) == "NSW1"
        @test only(raise6sec_nsw1.BIDTYPE) == BidType.RAISE6SEC
    end

    @testset "read_constraint_fcas_requirements spans the DISPATCH_FCAS_REQ split" begin
        # AEMO retired DISPATCH_FCAS_REQ after the 2025-05 archive month, replacing it with
        # DISPATCH_FCAS_REQ_CONSTRAINT. The mock stops the old table at interval 24 and runs
        # the new one across all 49 (see mock_data.jl step 13), reproducing both the takeover
        # and the backfill overlap.
        overlap_range = start_date:Minute(5):(start_date + Minute(5 * 10))
        new_only_range = (start_date + Minute(5 * 30)):Minute(5):(start_date + Minute(5 * 40))

        # Old-table territory: unchanged behaviour.
        @test !isempty(read_constraint_fcas_requirements(db, overlap_range))

        # Past where the old table stops, attribution must still resolve - before the union
        # this returned empty, silently making every constraint look purely network-driven.
        new_only = read_constraint_fcas_requirements(db, new_only_range)
        @test !isempty(new_only)
        @test "F_NSW1_RAISE6SEC" in new_only.GENCONID
        @test "N_BAYSW_THERMAL" ∉ new_only.GENCONID

        # Overlap must dedup, not double-count: one row per (GENCONID, REGIONID, BIDTYPE).
        overlap = read_constraint_fcas_requirements(db, overlap_range)
        @test nrow(overlap) == nrow(unique(select(overlap, :GENCONID, :REGIONID, :BIDTYPE)))
        @test nrow(subset(overlap, :GENCONID => ByRow(==("F_NSW1_RAISE6SEC")))) == 1
    end

    @testset "read_constraint_fcas_requirements throws when neither FCAS_REQ table is cached" begin
        # Neither table needs anything else cached first - _fcas_req_union_sql only checks
        # _table_is_cached, so an entirely empty hive reproduces the missing-cache case.
        empty_db = aem_connect(HiveConfiguration(hive_location = mktempdir(), filesystem = "file"))
        err = try
            read_constraint_fcas_requirements(empty_db, date_range)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("DISPATCH_FCAS_REQ", err.msg)
        @test occursin("DISPATCH_FCAS_REQ_CONSTRAINT", err.msg)
    end
end

@testset "add_nem_constraints!" begin
    hive_dir = AEM_TEST_HIVE_DIR
    config = HiveConfiguration(hive_location = hive_dir, filesystem = "file")
    db = aem_connect(config)
    start_date = DateTime(2025, 1, 1, 0, 0)
    date_range = start_date:Minute(5):(start_date + Hour(1))

    sys = nem_system(db, RegionalNetworkConfiguration())
    added, skipped = add_nem_constraints!(sys, db, date_range)

    # Every GENCONID in mock_data.jl has exactly one invoked GENCONDATA/SPD* version, always
    # EFFECTIVEDATE=2025-01-01, VERSIONNO=1. add_nem_constraints! names components by the full
    # versioned triple, so tests look
    # components up by this name rather than the bare GENCONID.
    vname(gencon_id, version = 1) = "$gencon_id@2025-01-01#$version"

    @test vname("F_VIC1_RAISE6SEC") in added
    @test vname("N_BAYSW_THERMAL") in added
    @test vname("N_PHANTOM_TEST") ∉ added
    @test skipped[vname("N_PHANTOM_TEST")] == :unknown_duid

    # N_PARTIAL_COVERAGE is only invoked in DISPATCHCONSTRAINT for every other interval
    # (6 of 12 rows over this date_range) - it is added anyway, with its "rhs"/"lhs" padded
    # to the full 12-interval grid (carrying the last known value forward) and an "invoked"
    # series recording which of those 12 were real, so it never silently drops a real-data
    # constraint that just wasn't invoked every interval (see add_nem_constraints! docstring).
    @test vname("N_PARTIAL_COVERAGE") in added
    partial_gc = get_component(GenericConstraint, sys, vname("N_PARTIAL_COVERAGE"))
    partial_rhs = first(values(get_data(get_time_series(Deterministic, partial_gc, "rhs"))))
    partial_invoked = first(values(get_data(get_time_series(Deterministic, partial_gc, "invoked"))))
    @test length(partial_rhs) == 12
    @test length(partial_rhs) == length(date_range) - 1  # grid spans date_range, not invocations
    @test all(==(150.0), partial_rhs)  # constant RHS - forward-fill is a no-op here
    @test partial_invoked == [isodd(i) ? 0.0 : 1.0 for i in 0:11]

    gc = get_component(GenericConstraint, sys, vname("F_VIC1_RAISE6SEC"))
    @test !isnothing(gc)
    @test get_sense(gc) == ConstraintSense.GE
    @test length(get_terms(gc)) == 4  # one UnitTerm per DUID behind CP_BAYSW
    @test length(get_fcas_requirements(gc)) == 1
    @test only(get_fcas_requirements(gc)) == FCASRequirement("VIC1", BidType.RAISE6SEC)

    @testset "AEMO provenance: description is a field, the rest live in ext via accessors" begin
        @test get_description(gc) isa String
        @test !haskey(get_ext(gc), "description")
        @test get_limit_type(gc) !== nothing
        @test get_source(gc) !== nothing
        @test get_effective_date(gc) !== nothing
        @test get_version_no(gc) !== nothing
        @test get_limit_type(gc) == get_ext(gc)["limit_type"]
        @test get_source(gc) == get_ext(gc)["source"]
        @test get_effective_date(gc) == get_ext(gc)["effective_date"]
        @test get_version_no(gc) == get_ext(gc)["version_no"]
    end

    network_gc = get_component(GenericConstraint, sys, vname("N_BAYSW_THERMAL"))
    @test isempty(get_fcas_requirements(network_gc))  # pure network constraint
    @test !isempty(get_terms(network_gc))

    nsw1_raise6sec = get_component(GenericConstraint, sys, vname("F_NSW1_RAISE6SEC"))
    @test any(t -> t isa InterconnectorTerm && get_interconnector(t) == "IC1", get_terms(nsw1_raise6sec))

    rhs_ts = get_time_series(Deterministic, gc, "rhs")
    @test !isnothing(rhs_ts)
    rhs_values = first(values(get_data(rhs_ts)))
    @test issorted(rhs_values)  # RHS = 50.0 + 0.1*i, confirmed time-varying in Task 8

    @test !has_time_series(gc, Deterministic, "lhs")  # include_solution defaults false

    added2, _ = add_nem_constraints!(nem_system(db, RegionalNetworkConfiguration()), db, date_range; include_solution = true)
    @test vname("F_VIC1_RAISE6SEC") in added2

    @testset "GenericConstraint attaches as a Service, not merely a Component" begin
        # UnitTerm: every term's own device carries the service.
        vic1_gc = get_component(GenericConstraint, sys, vname("F_VIC1_RAISE6SEC"))
        unit_terms = filter(t -> t isa UnitTerm, get_terms(vic1_gc))
        @test !isempty(unit_terms)
        for t in unit_terms
            device = get_component(Device, sys, get_duid(t))
            @test has_service(device, vic1_gc)
        end

        # RegionTerm: every Generator/Storage in that region carries the service, not just
        # the constraint's own UnitTerm device. And its `devices` field names exactly that set.
        nsw1_gc = get_component(GenericConstraint, sys, vname("F_NSW1_RAISEREG"))
        region_term = only(filter(t -> t isa RegionTerm, get_terms(nsw1_gc)))
        region_devices = AustralianElectricityMarkets._region_devices(sys, get_region(region_term))
        @test !isempty(region_devices)
        for d in region_devices
            @test has_service(d, nsw1_gc)
        end
        @test Set(get_devices(region_term)) == Set(get_name.(region_devices))
    end

    @testset "_region_devices" begin
        nsw1_devices = AustralianElectricityMarkets._region_devices(sys, "NSW1")
        all_devices = collect(Iterators.flatten((get_components(Generator, sys), get_components(Storage, sys))))
        expected = filter(d -> get_name(get_area(get_bus(d))) == "NSW1", all_devices)
        @test Set(get_name.(nsw1_devices)) == Set(get_name.(expected))
        @test all(d -> d isa Generator || d isa Storage, nsw1_devices)
    end

    @testset "resolve_term_devices" begin
        # UnitTerm: nothing for an unknown DUID, the DUID itself for a known one.
        @test isnothing(resolve_term_devices(sys, UnitTerm("NO_SUCH_DUID", BidType.RAISE6SEC, 1.0)))
        @test resolve_term_devices(sys, UnitTerm("BW01", BidType.RAISE6SEC, 1.0)) == ["BW01"]

        # InterconnectorTerm: nothing for an unknown interconnector, its name for a known one.
        @test isnothing(resolve_term_devices(sys, InterconnectorTerm("NO_SUCH_IC", 1.0)))
        @test resolve_term_devices(sys, InterconnectorTerm("IC1", 1.0)) == ["IC1"]

        # RegionTerm: nothing for an unknown region; a possibly-empty Vector{String} for a known
        # one - the empty-vs-nothing distinction is the entire contract.
        @test isnothing(resolve_term_devices(sys, RegionTerm("NO_SUCH_REGION", BidType.ENERGY, 1.0)))
        nsw1_names = resolve_term_devices(sys, RegionTerm("NSW1", BidType.ENERGY, 1.0))
        @test nsw1_names isa Vector{String}
        @test !isempty(nsw1_names)
        expected_nsw1 = get_name.(AustralianElectricityMarkets._region_devices(sys, "NSW1"))
        @test Set(nsw1_names) == Set(expected_nsw1)
    end

    @testset "empty RegionTerm devices: default throws, allow_empty_region_terms=true warns" begin
        # Relocating TAS1's only unit onto NSW1's bus leaves its UnitTerm resolvable, so this
        # exercises the empty-region-devices case independently of :unknown_duid/:unknown_region.
        sys_relocated = nem_system(db, RegionalNetworkConfiguration())
        er01 = get_component(Device, sys_relocated, "ER01")
        set_bus!(er01, get_bus(sys_relocated, "NSW1_GEN_BUS"))
        @test isempty(AustralianElectricityMarkets._region_devices(sys_relocated, "TAS1"))
        @test resolve_term_devices(sys_relocated, RegionTerm("TAS1", BidType.RAISEREG, 1.0)) == String[]

        err = try
            add_nem_constraints!(sys_relocated, db, date_range)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        # Names every affected GENCONID/region/bid_type in one aggregated message.
        @test occursin("F_TAS1_RAISEREG", err.msg)
        @test occursin("F_TAS1_LOWERREG", err.msg)
        @test occursin("TAS1", err.msg)
        @test occursin("RAISEREG", err.msg)
        @test occursin("LOWERREG", err.msg)
        @test occursin("allow_empty_region_terms", err.msg)

        # A fresh System: the default call above already threw after partially mutating
        # sys_relocated (the aggregated throw happens only after the whole build completes),
        # so reusing it here would double-add the constraints it did manage to attach.
        sys_relocated_ok = nem_system(db, RegionalNetworkConfiguration())
        er01_ok = get_component(Device, sys_relocated_ok, "ER01")
        set_bus!(er01_ok, get_bus(sys_relocated_ok, "NSW1_GEN_BUS"))

        added_w, skipped_w = nothing, nothing
        @test_logs (:warn, r"RegionTerm.*empty devices") match_mode = :any begin
            added_w, skipped_w = add_nem_constraints!(sys_relocated_ok, db, date_range; allow_empty_region_terms = true)
        end
        @test vname("F_TAS1_RAISEREG") in added_w
        @test vname("F_TAS1_LOWERREG") in added_w
        @test :no_region_devices ∉ values(skipped_w)  # the reason no longer exists at all
        tas1_gc = get_component(GenericConstraint, sys_relocated_ok, vname("F_TAS1_RAISEREG"))
        tas1_region_term = only(filter(t -> t isa RegionTerm, get_terms(tas1_gc)))
        @test isempty(get_devices(tas1_region_term))
        # A TAS1 constraint with no RegionTerm (a contingency market) is unaffected either way.
        @test vname("F_TAS1_RAISE6SEC") in added_w
    end

    @testset "rhs/invoked grid spans date_range, not just invoked SETTLEMENTDATEs" begin
        # Delete every DISPATCHCONSTRAINT row at one interval so no GENCONID is invoked
        # there, creating a genuine gap in unique(invoked.SETTLEMENTDATE).
        gap_hive = mktempdir()
        create_mock_data(gap_hive)
        gap_time = start_date + Minute(5 * 6)
        constraint_dir = joinpath(gap_hive, "DISPATCHCONSTRAINT")
        gap_conn = DuckDB.connect(DuckDB.DB())
        DuckDB.execute(gap_conn, "SET preserve_identifier_case=true")
        new_dir = constraint_dir * "_new"
        DuckDB.execute(
            gap_conn,
            "COPY (SELECT * FROM read_parquet('$(constraint_dir)/**/*.parquet', hive_partitioning=true) " *
                "WHERE SETTLEMENTDATE != TIMESTAMP '$(gap_time)') TO '$(new_dir)' (FORMAT 'PARQUET', PARTITION_BY (archive_month))",
        )
        rm(constraint_dir; recursive = true)
        mv(new_dir, constraint_dir)

        gap_db = aem_connect(HiveConfiguration(hive_location = gap_hive, filesystem = "file"))
        invoked_gap = read_invoked_constraints(gap_db, date_range)
        @test gap_time ∉ unique(invoked_gap.SETTLEMENTDATE)
        @test length(unique(invoked_gap.SETTLEMENTDATE)) == length(date_range) - 2

        gap_sys = nem_system(gap_db, RegionalNetworkConfiguration())
        add_nem_constraints!(gap_sys, gap_db, date_range)
        gap_gc = get_component(GenericConstraint, gap_sys, vname("N_BAYSW_THERMAL"))
        rhs_len = length(first(values(get_data(get_time_series(Deterministic, gap_gc, "rhs")))))
        @test rhs_len == length(date_range) - 1
        @test rhs_len != length(unique(invoked_gap.SETTLEMENTDATE))
    end

    @testset "resolution inference" begin
        # Multi-interval grid: the fixture is 5-minutely, so inference must read Minute(5) off
        # the data itself, not just happen to match a hardcoded default.
        sys_default = nem_system(db, RegionalNetworkConfiguration())
        add_nem_constraints!(sys_default, db, date_range)
        gc_default = get_component(GenericConstraint, sys_default, vname("N_BAYSW_THERMAL"))
        rhs_ts_default = get_time_series(Deterministic, gc_default, "rhs")
        @test get_resolution(rhs_ts_default) == Minute(5)

        # Explicit resolution is honoured as given, with no inference or validation.
        sys_explicit = nem_system(db, RegionalNetworkConfiguration())
        add_nem_constraints!(sys_explicit, db, date_range; resolution = Minute(30))
        gc_explicit = get_component(GenericConstraint, sys_explicit, vname("N_BAYSW_THERMAL"))
        rhs_ts_explicit = get_time_series(Deterministic, gc_explicit, "rhs")
        @test get_resolution(rhs_ts_explicit) == Minute(30)

        # A single-interval grid can't be exercised end-to-end through add_nem_constraints!:
        # PSY's Deterministic itself requires forecast arrays of length >= 2 (InfrastructureSystems
        # _check_forecast_data), independent of resolution - so a 1-point full_grid always errors
        # before resolution matters. _infer_resolution is unit-tested directly instead, contrasted
        # with the genuine multi-interval inference above (which is not just matching the fallback
        # by coincidence, since it uses a non-5-minute spacing).
        @test AustralianElectricityMarkets._infer_resolution(DateTime[]) == Minute(5)
        @test AustralianElectricityMarkets._infer_resolution([start_date]) == Minute(5)

        grid_30min = [start_date + Minute(30 * i) for i in 0:3]
        @test AustralianElectricityMarkets._infer_resolution(grid_30min) == Minute(30)

        # Irregular spacing warns (naming the distinct spacings) and falls back to the smallest
        # one rather than throwing - real, gappy caches still need a result.
        gappy_grid = [start_date, start_date + Minute(5), start_date + Minute(15)]
        inferred = nothing
        @test_logs (:warn, r"not uniform") match_mode = :any begin
            inferred = AustralianElectricityMarkets._infer_resolution(gappy_grid)
        end
        @test inferred == Minute(5)
    end

    @testset "throws when DISPATCHCONSTRAINT is not cached" begin
        empty_db = aem_connect(HiveConfiguration(hive_location = mktempdir(), filesystem = "file"))
        empty_sys = nem_system(db, RegionalNetworkConfiguration())
        err = try
            add_nem_constraints!(empty_sys, empty_db, date_range)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("DISPATCHCONSTRAINT", err.msg)
    end

    @testset "warns and returns empty when DISPATCHCONSTRAINT is cached but has no rows in range" begin
        # DISPATCHCONSTRAINT is cached (the fixture is 2025-01), just not for this range - a
        # real answer, not missing data, so this must warn rather than throw (contrast with
        # the "not cached at all" case above).
        far_future_range = DateTime(2030, 1, 1):Minute(5):(DateTime(2030, 1, 1) + Hour(1))
        far_sys = nem_system(db, RegionalNetworkConfiguration())
        added_far, skipped_far = nothing, nothing
        @test_logs (:warn, r"No constraints invoked") match_mode = :any begin
            added_far, skipped_far = add_nem_constraints!(far_sys, db, far_future_range)
        end
        @test added_far == String[]
        @test skipped_far == Dict{String, Symbol}()
    end
end
