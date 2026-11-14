using AustralianElectricityMarketsPortfolio
using AustralianElectricityMarketsData
using DataFrames
using Dates
using Test

const ISP_PROPERTY_FIXTURE_SOURCE = read_isp_source(
    write_isp_source_fixture(joinpath(mktempdir(), "isp.duckdb"));
    scenario = :step_change,
)

"""
    _build_xml_isp_source(; broken_timeslice::Bool = false)

Build the PLEXOS XML fixture into a fresh cache and read its `step_change` scenario.

# Arguments

- `broken_timeslice::Bool`: add the unresolvable `Mystery` timeslice to the fixture.

# Returns

- `ISPSourceData`: source data of the built cache.
"""
function _build_xml_isp_source(; broken_timeslice::Bool = false)
    root = mktempdir()
    model = joinpath(root, "model")
    scenario = joinpath(model, "2026 ISP Step Change")
    mkpath(scenario)
    write_isp_fixture(joinpath(scenario, "fixture.xml"); broken_timeslice = broken_timeslice)
    config = HiveConfiguration(; hive_location = joinpath(root, "cache"))
    build_isp_cache(config, model)
    return read_isp_source(config; scenario = :step_change)
end

@testset "resolve_properties precedence" begin
    source = _build_xml_isp_source()
    df = resolve_properties(source, "Generator", ["Max Capacity"], Date(2026, 7, 1))
    values = Dict(df.name .=> df[!, "Max Capacity"])

    # Latest date_from wins among overlapping open-ended records.
    @test values["GEN_SUPERSEDE"] == 250.0
    # Expired record, so the property default.
    @test values["GEN_EXPIRED"] == 42.0
    # Band 1 by default.
    @test values["GEN_BANDED"] == 10.0
    # Tagged to Summer (M1-3,11,12), which does not contain July, so the default.
    @test values["GEN_TAGGED"] == 42.0
    # Undated record applies.
    @test values["GEN_PLAIN"] == 77.0
    # Tagged to Winter (M4-10), which contains July, so the tagged value applies.
    @test values["GEN_TIMESLICE_MATCH"] == 88.0
    # A timeslice-matched record (33, dated 2020) beats an untagged one (500, dated 2026).
    @test values["GEN_SPECIFICITY"] == 33.0
    # Tagged to a non-month (day/hour) timeslice: never matches, never throws.
    @test values["GEN_ODD"] == 42.0
    # Tagged to M7, an active timeslice with no text expression, matched by name.
    @test values["GEN_SELF_MONTH"] == 66.0
    # Tagged to an inactive timeslice with no usable expression: excluded before any lookup.
    @test values["GEN_INACTIVE_TAG"] == 42.0

    # Every object of the class appears, even with no data of its own.
    @test nrow(df) == 10
    @test df.category[df.name .== "GEN_PLAIN"] == ["Black Coal NSW"]

    # Band selection is explicit.
    banded = resolve_properties(source, "Generator", ["Max Capacity"], Date(2026, 7, 1); band = 2)
    @test Dict(banded.name .=> banded[!, "Max Capacity"])["GEN_BANDED"] == 20.0

    # An unknown property is an error, not a silent column of defaults.
    @test_throws ArgumentError resolve_properties(
        source, "Generator", ["No Such Property"], Date(2026, 7, 1),
    )

    # Winter (M4-10) contains July; Summer (M1-3,11,12) and the day/hour timeslice Odd do not.
    matched = [t.name for t in isp_matching_timeslices(source, 7)]
    @test "Winter" in matched
    @test "M7" in matched
    @test !("Summer" in matched)
    @test !("Odd" in matched)
    @test !("Retired" in matched)

    # The five timeslices with their active flags and Include texts.
    @test length(source.timeslices) == 5
    flags = Dict(t.name => t.is_active for t in source.timeslices)
    @test flags == Dict("Summer" => true, "Winter" => true, "Odd" => true, "M7" => true, "Retired" => false)
    texts = Dict(t.name => t.include_texts for t in source.timeslices)
    @test texts == Dict(
        "Summer" => ["M1-3,11,12"],
        "Winter" => ["M4-10"],
        "Odd" => ["D1,H1; D15,H1"],
        "M7" => String[],
        "Retired" => String[],
    )
end

@testset "resolve_properties throws on an unresolvable active timeslice" begin
    # An active timeslice with neither a text expression nor a month-form name is a
    # genuine gap, so every resolution against the scenario must fail naming it.
    source = _build_xml_isp_source(; broken_timeslice = true)
    err = try
        resolve_properties(source, "Generator", ["Max Capacity"], Date(2026, 7, 1))
        nothing
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin("Mystery", err.msg)
end

@testset "Ambiguous property name" begin
    source = ISP_PROPERTY_FIXTURE_SOURCE
    err = try
        resolve_properties(source, "Generator", ["Max Capacity"], Date(2026, 7, 1))
        nothing
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin("\"1\"", err.msg)
    @test occursin("\"2\"", err.msg)

    by_collection = resolve_properties(
        source, "Generator", ["Max Capacity"], Date(2026, 7, 1); collection_id = "1",
    )
    @test by_collection.name == ["GEN_A", "GEN_B"]
    @test by_collection[!, "Max Capacity"] == [15.0, 20.0]

    # Property 2 has only a band-2 record, so both objects fall back to its default of 200.
    other = resolve_properties(
        source, "Generator", ["Max Capacity"], Date(2026, 7, 1); collection_id = "6",
    )
    @test other[!, "Max Capacity"] == [200.0, 200.0]
end

@testset "Later date wins" begin
    source = ISP_PROPERTY_FIXTURE_SOURCE
    df = resolve_property(source, "1", Date(2026, 7, 1))
    @test df.object_name == ["GEN_A", "GEN_B"]
    # GEN_A's record dated 2025-01-01 beats the one dated 2024-01-01.
    @test df.value == [15.0, 20.0]
    @test all(==(false), df.is_default)
    @test all(!ismissing, df.data_id)
end

@testset "Default fallback" begin
    source = ISP_PROPERTY_FIXTURE_SOURCE
    df = resolve_property(source, "4", Date(2026, 7, 1))
    @test df.object_name == ["VAR_A"]
    # The only record has no value and the property declares no default.
    @test ismissing(only(df.value))
    @test only(df.is_default)
    @test ismissing(only(df.data_id))
end

@testset "Band selection" begin
    source = ISP_PROPERTY_FIXTURE_SOURCE
    df = resolve_property(source, "1", Date(2026, 7, 1); band = 2)
    # Neither object has a band-2 record of property 1, so both take its default.
    @test df.value == [100.0, 100.0]
    @test all(df.is_default)
end

@testset "Unknown property id and name" begin
    source = ISP_PROPERTY_FIXTURE_SOURCE
    @test_throws ArgumentError resolve_property(source, "999", Date(2026, 7, 1))
    @test_throws ArgumentError resolve_properties(
        source, "Generator", ["No Such Property"], Date(2026, 7, 1),
    )
    @test_throws ArgumentError resolve_properties(source, "Generator", String[], Date(2026, 7, 1))
end

@testset "Property catalogue" begin
    source = ISP_PROPERTY_FIXTURE_SOURCE
    catalogue = isp_property_catalogue(source)
    @test nrow(catalogue) == 6
    row(id) = only(catalogue[catalogue.property_id .== id, :])

    @test row("1").class_name == "Generator"
    @test row("1").object_count == 2
    @test row("1").is_ambiguous
    @test row("2").class_name == "Generator"
    @test row("2").is_ambiguous

    @test row("3").class_name == "Constraint"
    @test row("3").object_count == 1
    @test !row("3").is_ambiguous

    @test row("4").class_name == "Variable"
    @test row("4").object_count == 1
    @test !row("4").is_ambiguous

    @test row("5").class_name == "Timeslice"
    @test row("6").class_name == "Data File"

    generators = isp_property_catalogue(source; class = "Generator")
    @test nrow(generators) == 2
    @test all(==("Generator"), generators.class_name)
    @test Set(generators.property_id) == Set(["1", "2"])
end
