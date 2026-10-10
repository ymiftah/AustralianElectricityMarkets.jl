import PowerSimulations as PSI
import PowerSystems as PSY
const AEMS = AustralianElectricityMarketsSimulations

@testset "Pinned PowerSimulations.jl fork resolves the area-balance dual to an Area-keyed container" begin
    # `hasmethod` can't tell fork from stock: stock 0.38.4 already has a generic
    # `NetworkModel{T} where T<:PM.AbstractPowerModel` method that matches `AreaBalancePowerModel`
    # (it's an `AbstractActivePowerModel`) and resolves to a bus-keyed container. Check which
    # method dispatch actually selects instead.
    m1 = which(
        PSI.add_constraint_dual!,
        Tuple{PSI.OptimizationContainer, PSY.System, PSI.NetworkModel{PSI.AreaBalancePowerModel}},
    )
    @test occursin("AreaBalancePowerModel", string(m1.sig))

    m2 = which(
        PSI.assign_dual_variable!,
        Tuple{
            PSI.OptimizationContainer,
            Type{PSI.CopperPlateBalanceConstraint},
            PSY.System,
            PSI.NetworkModel{PSI.AreaBalancePowerModel},
        },
    )
    @test occursin("AreaBalancePowerModel", string(m2.sig))
end

@testset "the area-balance slack objective resolves to this package's override, AreaPTDF keeps PSI's" begin
    m = which(
        PSI.objective_function!,
        Tuple{PSI.OptimizationContainer, PSY.System, PSI.NetworkModel{PSI.AreaBalancePowerModel}},
    )
    @test m.module === AEMS
    m_ptdf = which(
        PSI.objective_function!,
        Tuple{PSI.OptimizationContainer, PSY.System, PSI.NetworkModel{PSI.AreaPTDFPowerModel}},
    )
    @test m_ptdf.module === PSI
end

@testset "_modify_device_model! no-ops for LinearFactorLimit and FCASMarket" begin
    @test hasmethod(
        PSI._modify_device_model!,
        Tuple{Dict{Symbol, PSI.DeviceModel}, PSI.ServiceModel{GenericConstraint, AEMS.LinearFactorLimit}, Vector},
    )
    @test hasmethod(
        PSI._modify_device_model!,
        Tuple{Dict{Symbol, PSI.DeviceModel}, PSI.ServiceModel{FCASService, AEMS.FCASMarket}, Vector},
    )
end
