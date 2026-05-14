@testset "read_isp_fixed_opex" begin
    df = read_isp_fixed_opex()
    @test df isa DataFrame
    @test nrow(df) > 0
    @test "unit" in names(df)
    @test "isp_technology" in names(df)
    @test "primemover" in names(df)
    @test "fixed_opex_aud_kw_year" in names(df)
    @test eltype(df.unit) <: AbstractString
    @test eltype(df.fixed_opex_aud_kw_year) <: AbstractFloat
    @test all(df.fixed_opex_aud_kw_year .>= 0)
    # all ISP technologies in the data must be in PM_MAPPING (no missing primemovers)
    @test eltype(df.primemover) == PrimeMovers
    @test !any(ismissing.(df.primemover))
end

@testset "read_isp_variable_opex" begin
    df = read_isp_variable_opex()
    @test df isa DataFrame
    @test nrow(df) > 0
    @test "unit" in names(df)
    @test "isp_technology" in names(df)
    @test "primemover" in names(df)
    @test "variable_opex_aud_mwh" in names(df)
    @test eltype(df.unit) <: AbstractString
    @test eltype(df.variable_opex_aud_mwh) <: AbstractFloat
    @test all(df.variable_opex_aud_mwh .>= 0)
    @test eltype(df.primemover) == PrimeMovers
    @test !any(ismissing.(df.primemover))
end

@testset "read_isp_renewable_costs_parameters" begin
    df = read_isp_renewable_costs_parameters()
    @test df isa DataFrame
    @test nrow(df) > 0
    @test "unit" in names(df)
    @test "primemover" in names(df)
    @test "variable_opex_aud_mwh" in names(df)
    @test !("isp_technology" in names(df))

    # Per ISP 2025: Wind and Large-scale Solar PV have 0 AUD/MWh variable OPEX
    @test all(df.variable_opex_aud_mwh .== 0.0)

    @test eltype(df.primemover) == PrimeMovers
    @test !any(ismissing.(df.primemover))
    # only wind (WT) and solar (PVe) prime movers
    @test all(pm -> pm in (PrimeMovers.WT, PrimeMovers.PVe), df.primemover)

    # Renewable units are a strict subset of all variable opex units
    all_units = Set(read_isp_variable_opex().unit)
    @test issubset(Set(df.unit), all_units)
end
