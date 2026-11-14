using AustralianElectricityMarketsPortfolio
using AustralianElectricityMarketsCache: HiveConfiguration
using DataFrames
using Dates
using Test

const ISP_SOURCE_DIR = mktempdir()
const ISP_SOURCE_PATH = write_isp_source_fixture(joinpath(ISP_SOURCE_DIR, "isp.duckdb"))
const ISP_SOURCE = read_isp_source(ISP_SOURCE_PATH; scenario = :step_change)

_record(source, data_id::AbstractString) = only(filter(r -> r.data_id == data_id, source.records))

@testset "Scenario isolation" begin
    source = ISP_SOURCE
    @test source.scenario == :step_change
    @test all(r -> r.scenario == :step_change, source.records)
    @test "GEN_A" in source.objects.name
    @test !("GEN_A_OLD" in source.objects.name)

    old = read_isp_source(ISP_SOURCE_PATH; scenario = :slower_growth)
    @test "GEN_A_OLD" in old.objects.name
    @test !("GEN_A" in old.objects.name)
    @test all(r -> r.scenario == :slower_growth, old.records)
    @test _record(old, "1").value == 99.0
    @test _record(source, "1").value == 10.0
end

@testset "Same property name in different collections" begin
    source = ISP_SOURCE
    max_capacity = filter(r -> r.name == "Max Capacity", source.properties)
    @test nrow(max_capacity) == 2
    @test sort(max_capacity.property_id) == ["1", "2"]
    @test only(max_capacity[max_capacity.property_id .== "1", :collection_id]) == "1"
    @test only(max_capacity[max_capacity.property_id .== "2", :collection_id]) == "6"
    @test only(max_capacity[max_capacity.property_id .== "1", :default_value]) == "100"
    @test only(max_capacity[max_capacity.property_id .== "2", :default_value]) == "200"
    @test count(r -> r.property_name == "Max Capacity" && r.property_id == "1", source.records) == 4
    @test count(r -> r.property_name == "Max Capacity" && r.property_id == "2", source.records) == 1
end

@testset "Multiple memberships" begin
    source = ISP_SOURCE
    memberships = filter(r -> r.child_object_id == "3" && r.collection_id == "1", source.memberships)
    @test sort(memberships.membership_id) == ["2", "3"]
    gen_b = filter(r -> r.object_id == "3", source.records)
    @test sort(unique([r.membership_id for r in gen_b])) == ["2", "3"]
    @test all(r -> r.object_name == "GEN_B", gen_b)
end

@testset "Missing values" begin
    source = ISP_SOURCE
    row8 = _record(source, "8")
    @test row8.value === missing
    @test row8.raw_value === missing
    row6 = _record(source, "6")
    @test row6.value === missing
    @test row6.raw_value === missing
    @test row6.text_value == "Traces/solar/FIXTURE.csv"
end

@testset "Overlapping dates" begin
    source = ISP_SOURCE
    @test _record(source, "1").date_from == DateTime(2024, 1, 1)
    @test _record(source, "2").date_from == DateTime(2026, 1, 1)
    @test _record(source, "9").date_from == DateTime(2025, 1, 1)

    gen_a = filter(r -> r.object_id == "2" && r.property_id == "1", source.records)
    @test length(gen_a) == 2
    @test all(r -> r.object_name == "GEN_A", gen_a)
    @test all(r -> ismissing(r.date_to), gen_a)
end

@testset "Bands" begin
    source = ISP_SOURCE
    @test _record(source, "3").band == 2
    @test all(r -> r.band == 1, filter(r -> r.data_id != "3", source.records))
end

@testset "Tags" begin
    source = ISP_SOURCE
    tags = _record(source, "4").tags
    @test length(tags) == 1
    @test tags[1].class_name == "Variable"
    @test tags[1].object_name == "VAR_A"
    @test tags[1].action_id == "1"
    @test isempty(_record(source, "1").tags)
end

@testset "Timeslices" begin
    source = ISP_SOURCE
    @test length(source.timeslices) == 1
    slice = only(source.timeslices)
    @test slice.name == "Summer"
    @test slice.object_id == "7"
    @test slice.is_active
    @test slice.include_values == ["-1"]
    @test slice.include_texts == ["M1-3,11,12"]
end

@testset "Indirect Variable reference" begin
    source = ISP_SOURCE
    file_a = only(source.trace_handles)
    @test file_a.data_file_object_name == "FILE_A"
    @test source.trace_by_data_id["5"] == file_a
    @test source.trace_by_data_id["4"] == file_a
    @test source.trace_by_data_id["6"] == file_a
    @test isp_trace_handle(source, "5") == file_a
    @test isp_trace_handle(source, "1") === nothing
    @test !haskey(source.trace_by_data_id, "1")
end

@testset "Lazy traces" begin
    source = ISP_SOURCE
    handle = source.trace_by_data_id["5"]
    trace = read_isp_trace(ISP_SOURCE_PATH, handle)
    @test nrow(trace) == 2
    @test all(c -> c in names(trace), ["Year", "Month", "Day", "01"])
    @test trace[!, "01"] == ["1.5", "2.5"]
end

@testset "Read only" begin
    before = read(ISP_SOURCE_PATH)
    read_isp_source(ISP_SOURCE_PATH; scenario = :step_change)
    read_isp_source(ISP_SOURCE_PATH; scenario = :slower_growth)
    isp_scenarios(ISP_SOURCE_PATH)
    @test read(ISP_SOURCE_PATH) == before

    @test_throws ArgumentError read_isp_source(joinpath(ISP_SOURCE_DIR, "missing.duckdb"); scenario = :step_change)

    err = try
        read_isp_source(ISP_SOURCE_PATH; scenario = :nonexistent)
        nothing
    catch e
        e
    end
    @test err isa ArgumentError
    message = sprint(showerror, err)
    @test occursin("step_change", message)
    @test occursin("slower_growth", message)
end

@testset "Scenario listing and cache location" begin
    @test isp_scenarios(ISP_SOURCE_PATH) == ["slower_growth", "step_change"]

    config_dir = mktempdir()
    mkpath(joinpath(config_dir, "ISP", "2026"))
    cp(ISP_SOURCE_PATH, joinpath(config_dir, "ISP", "2026", "isp.duckdb"))
    config = HiveConfiguration(; hive_location = config_dir)
    source = read_isp_source(config; scenario = :step_change)
    @test source.path == joinpath(config_dir, "ISP", "2026", "isp.duckdb")
    @test length(source.records) == length(ISP_SOURCE.records)

    handle = only(ISP_SOURCE.trace_handles)
    hostile = ISPTraceHandle(
        handle.scenario, handle.data_file_object_id, handle.data_file_object_name, handle.relative_path,
        "traces\"; DROP TABLE x; --", handle.table_name, handle.source_sha256, handle.source_path,
    )
    @test_throws ArgumentError read_isp_trace(ISP_SOURCE_PATH, hostile)
end
