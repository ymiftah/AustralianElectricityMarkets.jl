using AustralianElectricityMarketsData
using Test

using Dates
using DuckDB
using DataFrames: nrow, DataFrame

@testset "NEMWEB download/cache tests" begin
    include("test-nemweb-load.jl")
end

@testset "Aqua" begin
    include("aqua.jl")
end
