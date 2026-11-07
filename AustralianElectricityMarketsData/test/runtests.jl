using AustralianElectricityMarketsData
using Test

using Dates
using DuckDB
using DataFrames: nrow, DataFrame

@testset "NEMWEB download/cache tests" begin
    include("test-nemweb-load.jl")
end

@testset "ISP 2026 PLEXOS parsing tests" begin
    include("isp2026_fixture.jl")
    include("isp2026.jl")
    include("isp2026_cache.jl")
    include("isp2026_traces.jl")
end

@testset "ISP 2026 release and archive acquisition tests" begin
    include("isp2026_release.jl")
end

@testset "Aqua" begin
    include("aqua.jl")
end
