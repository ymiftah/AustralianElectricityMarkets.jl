@testset "read_plexos_xml" begin
    path = joinpath(mktempdir(), "fixture.xml")
    write_isp_fixture(path)
    frames = read_plexos_xml(path)

    @test frames isa Dict{String, DataFrame}
    @test nrow(frames["t_object"]) == 16
    @test nrow(frames["t_data"]) == 18
    @test nrow(frames["t_date_from"]) == 5
    @test nrow(frames["t_band"]) == 1

    # Records with differing field sets union into one frame, absent => missing.
    obj = frames["t_object"]
    @test Set(names(obj)) == Set(["object_id", "class_id", "name", "category_id"])
    @test obj[obj.name .== "GEN_PLAIN", :object_id] == ["6"]

    # Every column is string-typed; numeric casting happens in SQL, not here.
    @test eltype(frames["t_data"].value) <: Union{String, Missing}
end

@testset "resolve_properties precedence" begin
    root = mktempdir()
    model = joinpath(root, "model")
    scenario = joinpath(model, "2026 ISP Step Change")
    mkpath(scenario)
    write_isp_fixture(joinpath(scenario, "fixture.xml"))
    config = HiveConfiguration(; hive_location = joinpath(root, "cache"))
    build_isp_cache(config, model)
    db = isp_cache(config; read_only = true)
    try
        df = resolve_properties(db, :step_change, "Generator", ["Max Capacity"], Date(2026, 7, 1))
        values = Dict(df.name .=> df[!, "Max Capacity"])

        # Rule 2: latest date_from wins among overlapping open-ended records.
        @test values["GEN_SUPERSEDE"] == 250.0
        # Rule 5: expired record => property default.
        @test values["GEN_EXPIRED"] == 42.0
        # Rule 3: band 1 by default.
        @test values["GEN_BANDED"] == 10.0
        # Rule 4: tagged to Summer (M1-3,11,12), which does not contain July => default.
        @test values["GEN_TAGGED"] == 42.0
        # Undated record applies.
        @test values["GEN_PLAIN"] == 77.0
        # Rule 4: tagged to Winter (M4-10), which contains July => the tagged value applies.
        @test values["GEN_TIMESLICE_MATCH"] == 88.0
        # Rule 4 specificity: a timeslice-matched record (33, dated 2020) beats an untagged
        # one (500, dated 2026) for the same property, despite being far older.
        @test values["GEN_SPECIFICITY"] == 33.0
        # Rule 4: tagged to a non-month (day/hour) timeslice; never matches, never throws.
        @test values["GEN_ODD"] == 42.0
        # Rule 4: tagged to M7, an active timeslice with no text expression, matched by name.
        @test values["GEN_SELF_MONTH"] == 66.0
        # Rule 4: tagged to Retired, an inactive (Include = 0) timeslice with neither a text
        # expression nor a month-form name; excluded by the flag before any lookup is
        # attempted, so this falls back to the default without throwing.
        @test values["GEN_INACTIVE_TAG"] == 42.0

        # Every object of the class appears, even with no data of its own.
        @test nrow(df) == 10
        @test df.category[df.name .== "GEN_PLAIN"] == ["Black Coal NSW"]

        # Band selection is explicit.
        banded = resolve_properties(db, :step_change, "Generator", ["Max Capacity"], Date(2026, 7, 1); band = 2)
        @test Dict(banded.name .=> banded[!, "Max Capacity"])["GEN_BANDED"] == 20.0

        # An unknown property is an error, not a silent column of defaults.
        @test_throws ArgumentError resolve_properties(
            db, :step_change, "Generator", ["No Such Property"], Date(2026, 7, 1),
        )

        # Direct check of the month-matching helper: Winter (M4-10) contains July, Summer
        # (M1-3,11,12) and the day/hour timeslice Odd do not.
        winter_id = only(
            AustralianElectricityMarketsData._isp_query(
                db, "SELECT object_id FROM step_change.t_object WHERE name = 'Winter'",
            ).object_id,
        )
        summer_id = only(
            AustralianElectricityMarketsData._isp_query(
                db, "SELECT object_id FROM step_change.t_object WHERE name = 'Summer'",
            ).object_id,
        )
        odd_id = only(
            AustralianElectricityMarketsData._isp_query(
                db, "SELECT object_id FROM step_change.t_object WHERE name = 'Odd'",
            ).object_id,
        )
        matched = AustralianElectricityMarketsData._matching_timeslice_ids(db, "step_change", 7)
        @test winter_id in matched
        @test !(summer_id in matched)
        @test !(odd_id in matched)
    finally
        DBInterface.close!(db.db)
    end
end

@testset "resolve_properties throws on an unresolvable active timeslice" begin
    # An active (Include = -1) timeslice with neither a text expression nor a
    # month-form name is a genuine parsing gap, not a silent non-match: it must fail
    # loudly rather than zero out every property tagged to it. This fixture variant is
    # isolated to its own scenario, since the throw fires on any resolve_properties call
    # against the schema, not just one touching the broken tag.
    root = mktempdir()
    model = joinpath(root, "model")
    scenario = joinpath(model, "2026 ISP Step Change")
    mkpath(scenario)
    write_isp_fixture(joinpath(scenario, "fixture.xml"); broken_timeslice = true)
    config = HiveConfiguration(; hive_location = joinpath(root, "cache"))
    build_isp_cache(config, model)
    db = isp_cache(config; read_only = true)
    try
        err = try
            resolve_properties(db, :step_change, "Generator", ["Max Capacity"], Date(2026, 7, 1))
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("Mystery", err.msg)
    finally
        DBInterface.close!(db.db)
    end
end
