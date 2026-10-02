import PowerSimulations as PSI
const AEMS = AustralianElectricityMarketsSimulations

@testset "LinearFactorLimit sits under AbstractNEMConstraintFormulation, under PSI's own formulation type" begin
    @test AEMS.LinearFactorLimit <: AEMS.AbstractNEMConstraintFormulation <: PSI.AbstractServiceFormulation
end

@testset "FCASMarket is a direct AbstractServiceFormulation, not an AbstractNEMConstraintFormulation" begin
    @test AEMS.FCASMarket <: PSI.AbstractServiceFormulation
    @test !(AEMS.FCASMarket <: AEMS.AbstractNEMConstraintFormulation)
end

@testset "Expression/constraint/parameter types sit under PSI's own optimization-container types" begin
    @test AEMS.NEMConstraintLHS <: PSI.ExpressionType
    @test AEMS.NEMConstraintLimit <: PSI.ConstraintType
    @test AEMS.NEMConstraintRHSParameter <: PSI.TimeSeriesParameter
end
