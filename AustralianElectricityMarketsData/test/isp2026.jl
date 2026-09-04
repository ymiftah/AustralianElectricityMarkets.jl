@testset "read_plexos_xml" begin
    path = joinpath(mktempdir(), "fixture.xml")
    write_isp_fixture(path)
    frames = read_plexos_xml(path)

    @test frames isa Dict{String, DataFrame}
    @test nrow(frames["t_object"]) == 7
    @test nrow(frames["t_data"]) == 7
    @test nrow(frames["t_date_from"]) == 3
    @test nrow(frames["t_band"]) == 1

    # Records with differing field sets union into one frame, absent => missing.
    obj = frames["t_object"]
    @test Set(names(obj)) == Set(["object_id", "class_id", "name", "category_id"])
    @test obj[obj.name .== "GEN_PLAIN", :object_id] == ["6"]

    # Every column is string-typed; numeric casting happens in SQL, not here.
    @test eltype(frames["t_data"].value) <: Union{String, Missing}
end

@testset "load_isp_xml!" begin
    path = joinpath(mktempdir(), "fixture.xml")
    write_isp_fixture(path)
    db = aem_connect()

    loaded = load_isp_xml!(db, path, :step_change)
    @test "t_object" in loaded
    @test "t_data" in loaded

    counted = AustralianElectricityMarketsData._query(db, "SELECT count(*) AS n FROM step_change.t_object")
    @test counted.n[1] == 7

    # A second scenario is isolated: same object_ids, different schema.
    load_isp_xml!(db, path, :slower_growth)
    both = AustralianElectricityMarketsData._query(
        db,
        """
        SELECT (SELECT count(*) FROM step_change.t_object) AS a,
               (SELECT count(*) FROM slower_growth.t_object) AS b
        """,
    )
    @test both.a[1] == 7
    @test both.b[1] == 7

    # Reloading the same scenario replaces rather than appends.
    load_isp_xml!(db, path, :step_change)
    again = AustralianElectricityMarketsData._query(db, "SELECT count(*) AS n FROM step_change.t_object")
    @test again.n[1] == 7

    @test_throws ArgumentError isp_scenario_schema(Symbol("drop table; --"))
end

@testset "resolve_properties precedence" begin
    path = joinpath(mktempdir(), "fixture.xml")
    write_isp_fixture(path)
    db = aem_connect()
    load_isp_xml!(db, path, :step_change)

    df = resolve_properties(db, :step_change, "Generator", ["Max Capacity"], Date(2026, 7, 1))
    values = Dict(df.name .=> df[!, "Max Capacity"])

    # Rule 2: latest date_from wins among overlapping open-ended records.
    @test values["GEN_SUPERSEDE"] == 250.0
    # Rule 5: expired record => property default.
    @test values["GEN_EXPIRED"] == 42.0
    # Rule 3: band 1 by default.
    @test values["GEN_BANDED"] == 10.0
    # Rule 4: timeslice-tagged rows are excluded from annual resolution => default.
    @test values["GEN_TAGGED"] == 42.0
    # Undated record applies.
    @test values["GEN_PLAIN"] == 77.0

    # Every object of the class appears, even with no data of its own.
    @test nrow(df) == 5
    @test df.category[df.name .== "GEN_PLAIN"] == ["Black Coal NSW"]

    # Band selection is explicit.
    banded = resolve_properties(db, :step_change, "Generator", ["Max Capacity"], Date(2026, 7, 1); band = 2)
    @test Dict(banded.name .=> banded[!, "Max Capacity"])["GEN_BANDED"] == 20.0

    # An unknown property is an error, not a silent column of defaults.
    @test_throws ArgumentError resolve_properties(
        db, :step_change, "Generator", ["No Such Property"], Date(2026, 7, 1),
    )
end
