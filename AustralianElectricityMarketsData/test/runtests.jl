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
end

@testset "Aqua" begin
    include("aqua.jl")
end
