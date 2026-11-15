using AustralianElectricityMarketsCache
using Aqua
using Test

const Cache = AustralianElectricityMarketsCache

@testset "Cache infrastructure" begin
    root = mktempdir()
    db = aem_connect(HiveConfiguration(hive_location = root))
    source = get_table(db, :DISPATCHPRICE)
    @test source.path == joinpath(root, "DISPATCHPRICE")
    @test Cache._parse_hive_root(HiveConfiguration(hive_location = "bucket/prefix", filesystem = "s3")) == "s3://bucket/prefix"
    @test Cache._parse_hive_root(HiveConfiguration(hive_location = "bucket/prefix", filesystem = "gs")) == "gs://bucket/prefix"
end

@testset "Aqua" begin
    Aqua.test_all(Cache; ambiguities = false, persistent_tasks = false)
end
