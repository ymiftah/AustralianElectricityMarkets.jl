import PowerSimulations as PSI
import PowerSystems as PSY
const AEMS = AustralianElectricityMarketsSimulations

@testset "Pinned PowerSimulations.jl fork resolves the area-balance dual to an Area-keyed container" begin
    # `hasmethod` can't tell fork from stock: stock PowerSimulations already has a generic
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

@testset "the area-balance slack objective is PSI's own, so a plain model keeps its default slack cost" begin
    m = which(
        PSI.objective_function!,
        Tuple{PSI.OptimizationContainer, PSY.System, PSI.NetworkModel{PSI.AreaBalancePowerModel}},
    )
    @test m.module === PSI
    m_ptdf = which(
        PSI.objective_function!,
        Tuple{PSI.OptimizationContainer, PSY.System, PSI.NetworkModel{PSI.AreaPTDFPowerModel}},
    )
    @test m_ptdf.module === PSI
end

@testset "energy-offer rows retain typed PSI containers and affine coefficients" begin
    for (T, U, V, W) in (
                (PSY.ThermalStandard, PSI.ActivePowerVariable, PSI.PiecewiseLinearBlockIncrementalOffer, PSI.PiecewiseLinearBlockIncrementalOfferConstraint),
                (PSY.InterruptiblePowerLoad, PSI.ActivePowerVariable, PSI.PiecewiseLinearBlockDecrementalOffer, PSI.PiecewiseLinearBlockDecrementalOfferConstraint),
                (PSY.EnergyReservoirStorage, PSI.ActivePowerOutVariable, PSI.PiecewiseLinearBlockIncrementalOffer, PSI.PiecewiseLinearBlockIncrementalOfferConstraint),
                (PSY.EnergyReservoirStorage, PSI.ActivePowerInVariable, PSI.PiecewiseLinearBlockDecrementalOffer, PSI.PiecewiseLinearBlockDecrementalOfferConstraint),
            ), breakpoints in ([0.0, 0.0, 0.5], [0.1, 0.4, 0.6], [-0.2, 0.3], [0.1])
        sys = PSY.System(100.0; time_series_in_memory = true, runchecks = false)
        container = PSI.OptimizationContainer(sys, PSI.Settings(sys), nothing, PSY.SingleTimeSeries)
        jm = PSI.get_jump_model(container)
        PSI.JuMP.set_string_names_on_creation(jm, false)
        device = T(nothing)
        name = PSY.get_name(device)
        power = PSI.add_variable_container!(container, U(), T, [name], 1:1)
        power[name, 1] = PSI.JuMP.@variable(jm)
        bands = PSI.add_variable_container!(container, V(), T, [name], 1:(length(breakpoints) - 1), 1:1)
        for k in 1:(length(breakpoints) - 1)
            bands[name, k, 1] = PSI.JuMP.@variable(jm)
        end
        S, D = AEMS._energy_offer_slacks(V)
        surplus = PSI.add_variable_container!(container, S(), T, [name], 1:1)
        deficit = PSI.add_variable_container!(container, D(), T, [name], 1:1)
        surplus[name, 1] = PSI.JuMP.@variable(jm, lower_bound = 0)
        deficit[name, 1] = PSI.JuMP.@variable(jm, lower_bound = 0)
        signature = Tuple{typeof(container), T, U, NEMReplayDispatch, typeof(breakpoints), Int, Type{V}, Type{W}}
        @test which(PSI._add_pwl_constraint!, signature).module === AEMS
        if length(breakpoints) == 1
            @test_throws ArgumentError PSI._add_pwl_constraint!(container, device, U(), NEMReplayDispatch(), breakpoints, 1, V, W)
            continue
        end
        PSI._add_pwl_constraint!(container, device, U(), NEMReplayDispatch(), breakpoints, 1, V, W)
        row = PSI.get_constraint(container, W(), T)[name, 1]
        @test PSI.JuMP.normalized_rhs(row) == first(breakpoints)
        @test PSI.JuMP.normalized_coefficient(row, power[name, 1]) == 1.0
        @test PSI.JuMP.normalized_coefficient(row, surplus[name, 1]) == -1.0
        @test PSI.JuMP.normalized_coefficient(row, deficit[name, 1]) == 1.0
        for k in 1:(length(breakpoints) - 1)
            @test PSI.JuMP.normalized_coefficient(row, bands[name, k, 1]) == -1.0
        end
        bounds = PSI.JuMP.all_constraints(jm, PSI.JuMP.AffExpr, PSI.MOI.LessThan{Float64})
        @test length(bounds) == length(breakpoints) - 1
        for (k, bound) in enumerate(bounds)
            @test PSI.JuMP.normalized_rhs(bound) ≈ breakpoints[k + 1] - breakpoints[k]
            @test PSI.JuMP.normalized_coefficient(bound, bands[name, k, 1]) == 1.0
        end
    end
end

@testset "energy cost guards: service-only costs add nothing, one-sided energy offers throw" begin
    template_for(sys) = begin
        template = PSI.ProblemTemplate(PSI.NetworkModel(PSI.AreaBalancePowerModel; use_slacks = true))
        set_nem_dispatch_models!(template, sys; tie_breaks = false)
        PSI.set_device_model!(template, PSY.PowerLoad, PSI.StaticPowerLoad)
        return template
    end
    service_only() = PSY.MarketBidCost(; no_load_cost = 0.0, start_up = (hot = 0.0, warm = 0.0, cold = 0.0), shut_down = 0.0)
    toy(; loads = Pair{String, Any}[]) = nem_toy_system(
        [TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = 0.0, ramp_up = 100.0)],
        50.0;
        batteries = [TOY_BATTERY => toy_battery(50.0, 10.0, 50.0, 1.0; initial = 0.0, ramp_up = 100.0)],
        loads = loads,
    )

    # (a) A battery with no energy curves builds, and its discharge carries no energy cost.
    sys = toy()
    battery = PSY.get_component(PSY.EnergyReservoirStorage, sys, TOY_BATTERY)
    PSY.set_operation_cost!(battery, service_only())
    model = toy_model(sys; template = template_for(sys))
    status, log = _toy_build_log(model)
    @test status == PSI.ModelBuildStatus.BUILT
    container = PSI.get_optimization_container(model)
    out = PSI.get_variable(container, PSI.ActivePowerOutVariable(), PSY.EnergyReservoirStorage)
    @test PSI.JuMP.coefficient(PSI.JuMP.objective_function(PSI.get_jump_model(container)), out[TOY_BATTERY, first(axes(out, 2))]) == 0.0

    # (b) A battery with a GEN curve and no LOAD curve fails the build instead of charging for free.
    sys = toy()
    battery = PSY.get_component(PSY.EnergyReservoirStorage, sys, TOY_BATTERY)
    gen_curve = PSY.CostCurve(PSY.PiecewiseIncrementalCurve(0.0, [0.0, 50.0], [10.0]))
    PSY.set_operation_cost!(battery, PSY.MarketBidCost(; no_load_cost = 0.0, start_up = (hot = 0.0, warm = 0.0, cold = 0.0), shut_down = 0.0, incremental_offer_curves = gen_curve))
    status, log = _toy_build_log(toy_model(sys; template = template_for(sys)))
    @test status == PSI.ModelBuildStatus.FAILED
    @test occursin("$TOY_BATTERY: the MarketBidCost has energy offers on the other side but no LOAD offer curve", log)

    # (c) A scheduled load with no energy curves and a service-only cost builds.
    sys = toy(; loads = [TOY_LOAD_SERVICE_ONLY => toy_load(50.0, 30.0; initial = 0.0, ramp_up = 100.0)])
    load = PSY.get_component(PSY.InterruptiblePowerLoad, sys, TOY_LOAD_SERVICE_ONLY)
    PSY.set_operation_cost!(load, service_only())
    status, _ = _toy_build_log(toy_model(sys; template = template_for(sys)))
    @test status == PSI.ModelBuildStatus.BUILT
end
