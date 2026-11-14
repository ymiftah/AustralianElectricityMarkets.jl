using Test
using Dates
using PowerSystems
using PowerSystemsInvestmentsPortfolios
using PowerSystemsInvestments
using PowerSimulations
using TimeSeries
const PSY = PowerSystems
const PSIP = PowerSystemsInvestmentsPortfolios

pushfirst!(LOAD_PATH, joinpath(@__DIR__, "Boundary"))
using PortfolioBoundary
@test Base.get_extension(PortfolioBoundary, :PortfolioBoundaryPSIPExt) !== nothing
@test PortfolioBoundary.portfolio_type() === PSIP.Portfolio

@testset "PSIP portfolio data contract" begin
    sys = PSY.System(100.0; runchecks = false)
    bus = PSY.ACBus(nothing)
    PSY.set_bustype!(bus, PSY.ACBusTypes.REF)
    PSY.add_component!(sys, bus)
    gen = PSY.ThermalStandard(nothing)
    PSY.set_name!(gen, "existing")
    PSY.set_bus!(gen, bus)
    PSY.set_base_power!(gen, 100.0)
    PSY.set_active_power_limits!(gen, (min = 0.0, max = 0.5))
    PSY.add_component!(sys, gen)
    port = PSIP.Portfolio(sys; financial_data = PSIP.PortfolioFinancialData(2025, 0.07, 0.05, 0.03))
    zone = PSIP.Zone(; name = "NSW", id = 1)
    PSIP.add_region!(port, zone)
    fin = PSIP.TechnologyFinancialData(; capital_recovery_period = 30, technology_base_year = 2025, debt_fraction = 0.5, debt_rate = 0.07, return_on_equity = 0.1, tax_rate = 0.25)
    supply = PSIP.SupplyTechnology{PSY.ThermalStandard}(; name = "thermal", id = 1, available = true, financial_data = fin, power_systems_type = "ThermalStandard", region = [zone])
    storage = PSIP.StorageTechnology{PSY.EnergyReservoirStorage}(; name = "battery", id = 2, available = true, financial_data = fin, storage_tech = PSY.StorageTech.LIB, power_systems_type = "EnergyReservoirStorage", region = [zone])
    PSIP.add_technology!(port, supply)
    PSIP.add_technology!(port, storage)
    requirement = PSIP.CapacityReserveMargin(; name = "reserve", id = 3, available = true, target_year = 2030, capacity_reserve_fraction = 0.15)
    PSIP.add_requirement!(port, requirement)
    PSIP.set_requirements!(supply, [requirement])
    @test PSIP.has_requirement(supply, requirement)
    PSIP.add_supplemental_attribute!(port, supply, PSIP.ExistingDevices(; id = 4, existing_devices = ["existing"]))
    ts = PSY.SingleTimeSeries("inv_capex", TimeArray([DateTime(2025), DateTime(2026)], [1.0, 0.9]))
    PSIP.add_time_series!(port, supply, ts)
    @test PSIP.get_region(PSIP.Zone, port, "NSW") === zone
    @test PSIP.get_technology(PSIP.SupplyTechnology, port, "thermal") === supply
    @test PSIP.get_technology(PSIP.StorageTechnology, port, "battery") === storage
    @test PSIP.get_requirement(PSIP.CapacityReserveMargin, port, "reserve") === requirement
    @test PSIP.get_existing_capacity_mw(port, supply) ≈ 50.0
    @test PSIP.get_time_series_array(PSY.SingleTimeSeries, supply, "inv_capex") == PSIP.get_time_series_array(supply, ts)
    mktempdir() do dir
        path = joinpath(dir, "portfolio.json")
        PSIP.to_json(port, path; force = true)
        restored = PSIP.Portfolio(path)
        restored_supply = PSIP.get_technology(PSIP.SupplyTechnology, restored, "thermal")
        @test PSIP.get_existing_capacity_mw(restored, restored_supply) ≈ 50.0
        @test PSIP.get_technology(PSIP.StorageTechnology, restored, "battery") !== nothing
        restored_requirement = PSIP.get_requirement(PSIP.CapacityReserveMargin, restored, "reserve")
        @test restored_requirement !== nothing
        @test PSIP.has_requirement(restored_supply, restored_requirement)
        @test PSIP.get_time_series_array(PSY.SingleTimeSeries, restored_supply, "inv_capex") == PSIP.get_time_series_array(supply, ts)
    end
end
