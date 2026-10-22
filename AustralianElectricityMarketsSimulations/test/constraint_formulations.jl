import PowerSimulations as PSI
const AEMS = AustralianElectricityMarketsSimulations

@testset "LinearFactorLimit and FCASMarket are PSI service formulations" begin
    @test AEMS.LinearFactorLimit <: PSI.AbstractServiceFormulation
    @test AEMS.FCASMarket <: PSI.AbstractServiceFormulation
end

@testset "Expression/constraint/parameter types sit under PSI's own optimization-container types" begin
    @test AEMS.NEMConstraintLHS <: PSI.ExpressionType
    @test AEMS.NEMConstraintLimit <: PSI.ConstraintType
    @test AEMS.NEMConstraintRHSParameter <: PSI.TimeSeriesParameter
    @test AEMS.GenericConstraintSlackCostParameter <: PSI.ObjectiveFunctionParameter
end

@testset "GenericConstraintSlackUp/SlackDown are PSI.VariableTypes" begin
    @test AEMS.GenericConstraintSlackUp <: PSI.VariableType
    @test AEMS.GenericConstraintSlackDown <: PSI.VariableType
end
