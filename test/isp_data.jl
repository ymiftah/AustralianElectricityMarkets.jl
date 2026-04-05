@testset "read_isp_fixed_opex" begin
    df = read_isp_fixed_opex()
    @test df isa DataFrame
    @test nrow(df) > 0
    @test "unit" in names(df)
    @test "isp_technology" in names(df)
    @test "fixed_opex_aud_kw_year" in names(df)
    @test eltype(df.unit) <: AbstractString
    @test eltype(df.fixed_opex_aud_kw_year) <: AbstractFloat
    @test all(df.fixed_opex_aud_kw_year .>= 0)
end

@testset "read_isp_variable_opex" begin
    df = read_isp_variable_opex()
    @test df isa DataFrame
    @test nrow(df) > 0
    @test "unit" in names(df)
    @test "isp_technology" in names(df)
    @test "variable_opex_aud_mwh" in names(df)
    @test eltype(df.unit) <: AbstractString
    @test eltype(df.variable_opex_aud_mwh) <: AbstractFloat
    @test all(df.variable_opex_aud_mwh .>= 0)
end

@testset "read_isp_renewable_costs_parameters" begin
    df = read_isp_renewable_costs_parameters()
    @test df isa DataFrame
    @test nrow(df) > 0
    @test "unit" in names(df)
    @test "variable_opex_aud_mwh" in names(df)
    # isp_technology is not exposed — only unit and variable_opex_aud_mwh
    @test !("isp_technology" in names(df))

    # Per ISP 2025: Wind and Large-scale Solar PV have 0 AUD/MWh variable OPEX
    @test all(df.variable_opex_aud_mwh .== 0.0)

    # Renewable units are a strict subset of all variable opex units
    all_units = Set(read_isp_variable_opex().unit)
    @test issubset(Set(df.unit), all_units)
end
