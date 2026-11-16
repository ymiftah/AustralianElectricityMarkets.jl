@testset "read_isp_renewable_costs_parameters" begin
    df = read_isp_renewable_costs_parameters()
    @test nrow(df) > 0
    @test !("isp_technology" in names(df))

    # Per ISP 2025: Wind and Large-scale Solar PV have 0 AUD/MWh variable OPEX
    @test all(df.variable_opex_aud_mwh .== 0.0)

    # Renewable units are a strict subset of all variable opex units
    all_units = Set(read_isp_variable_opex().unit)
    @test issubset(Set(df.unit), all_units)
end
