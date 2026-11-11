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

@testset "energy offer guards: FCAS-only units have no energy bands, one-sided storage offers throw" begin
    template_for(sys) = begin
        template = PSI.ProblemTemplate(PSI.NetworkModel(PSI.AreaBalancePowerModel; use_slacks = true))
        set_nem_dispatch_models!(template, sys; tie_breaks = false)
        PSI.set_device_model!(template, PSY.PowerLoad, PSI.StaticPowerLoad)
        return template
    end
    # Removes the named device's energy offers on `sides` (their series and bids) before the fixture
    # transforms its series. The removed bid's MAXAVAIL series stays attached but is no longer read.
    without(device_type, name, sides) = (sys, _) -> begin
        device = PSY.get_component(device_type, sys, name)
        bids = AustralianElectricityMarkets.get_energy_bids(AustralianElectricityMarkets._nem_offer_cost(device))
        for side in sides
            name_offer = AustralianElectricityMarkets.energy_offer_series_name(side)
            PSY.has_time_series(device, PSY.SingleTimeSeries, name_offer) &&
                PSY.remove_time_series!(sys, PSY.SingleTimeSeries, device, name_offer)
            filter!(b -> AustralianElectricityMarkets._energy_offer_side(b.direction) != side, bids)
        end
        return
    end
    toy(; loads = Pair{String, Any}[], mutate! = nothing) = nem_toy_system(
        [TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = 0.0, ramp_up = 100.0)],
        50.0;
        batteries = [TOY_BATTERY => toy_battery(50.0, 10.0, 50.0, 1.0; initial = 0.0, ramp_up = 100.0)],
        loads = loads, mutate! = mutate!,
    )
    band_devices(container, meta) = begin
        keys = [k for k in PSI.get_variable_keys(container) if PSI.IS.Optimization.get_entry_type(k) === EnergyOfferBandVariable && k.meta == meta]
        return sort!(vcat((collect(axes(PSI.get_variable(container, k), 1)) for k in keys)...))
    end

    # (a) A battery with no energy offers builds, has no energy bands, and its discharge carries no energy cost.
    sys = toy(; mutate! = without(EnergyReservoirStorage, TOY_BATTERY, (OfferSide.GEN, OfferSide.LOAD)))
    model = toy_model(sys; template = template_for(sys))
    status, log = _toy_build_log(model)
    @test status == PSI.ModelBuildStatus.BUILT
    container = PSI.get_optimization_container(model)
    @test band_devices(container, "gen") == [TOY_CHEAP]
    @test isempty(band_devices(container, "load"))
    out = PSI.get_variable(container, PSI.ActivePowerOutVariable(), EnergyReservoirStorage)
    @test PSI.JuMP.coefficient(PSI.JuMP.objective_function(PSI.get_jump_model(container)), out[TOY_BATTERY, first(axes(out, 2))]) == 0.0

    # (b) A battery with a GEN offer and no LOAD offer fails the build instead of charging for free.
    sys = toy(; mutate! = without(EnergyReservoirStorage, TOY_BATTERY, (OfferSide.LOAD,)))
    status, log = _toy_build_log(toy_model(sys; template = template_for(sys)))
    @test status == PSI.ModelBuildStatus.FAILED
    @test occursin("$TOY_BATTERY: the device has an energy offer on the other side but no LOAD energy offer series", log)

    # (c) A scheduled load with no energy offer builds and has no energy bands.
    sys = toy(;
        loads = [TOY_LOAD_SERVICE_ONLY => toy_load(50.0, 30.0; initial = 0.0, ramp_up = 100.0)],
        mutate! = without(InterruptiblePowerLoad, TOY_LOAD_SERVICE_ONLY, (OfferSide.LOAD,)),
    )
    model = toy_model(sys; template = template_for(sys))
    status, _ = _toy_build_log(model)
    @test status == PSI.ModelBuildStatus.BUILT
    @test TOY_LOAD_SERVICE_ONLY ∉ band_devices(PSI.get_optimization_container(model), "load")
end

@testset "padded energy bands never clear" begin
    # A one-band unit beside a three-band one: its two padded bands have zero width and price.
    sys = nem_toy_system(
        [
            TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = 0.0, ramp_up = 100.0),
            TOY_EXPENSIVE => toy_unit(100.0, [(20.0, 30.0), (20.0, 40.0), (20.0, 50.0)]; initial = 0.0, ramp_up = 100.0),
        ],
        130.0,
    )
    out = solve_toy(sys)
    @test out.dispatch_mw[TOY_CHEAP] ≈ 100.0 atol = 1.0e-6
    @test out.dispatch_mw[TOY_EXPENSIVE] ≈ 30.0 atol = 1.0e-6
    bands = PSI.get_variable(out.container, EnergyOfferBandVariable(), ThermalStandard, "gen")
    @test axes(bands, 2) == ["1", "2", "3"]
    base_power = PSY.get_base_power(sys)
    cleared(name, b) = PSI.JuMP.value(bands[name, string(b), 1]) * base_power
    @test cleared(TOY_CHEAP, 1) ≈ 100.0 atol = 1.0e-6
    @test cleared(TOY_CHEAP, 2) ≈ 0.0 atol = 1.0e-6
    @test cleared(TOY_CHEAP, 3) ≈ 0.0 atol = 1.0e-6
end

@testset "a battery with its LOAD price below its GEN price does not circulate" begin
    sys = nem_toy_system(
        [TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = 0.0, ramp_up = 100.0)],
        50.0;
        batteries = [TOY_BATTERY => toy_battery(50.0, 30.0, 50.0, 20.0; initial = 0.0, ramp_up = 100.0)],
    )
    out = solve_toy(sys)
    @test out.battery_out_mw[TOY_BATTERY] * out.battery_in_mw[TOY_BATTERY] ≈ 0.0 atol = 1.0e-6
end

@testset "an energy offer on a side the device type does not bid fails the build" begin
    template_for(sys) = begin
        template = PSI.ProblemTemplate(PSI.NetworkModel(PSI.AreaBalancePowerModel; use_slacks = true))
        set_nem_dispatch_models!(template, sys; tie_breaks = false)
        PSI.set_device_model!(template, PSY.PowerLoad, PSI.StaticPowerLoad)
        return template
    end
    offer = (sys, stamps) -> PSY.PiecewiseStepData([0.0, 10.0], [5.0])
    function stray(device_type, name, side, series)
        return (sys, stamps) -> begin
            device = PSY.get_component(device_type, sys, name)
            AustralianElectricityMarkets.replace_single_series!(
                sys, device,
                AustralianElectricityMarkets.single_series(
                    AEMS.energy_availability_series_name(device, side), TOY_START, fill(1.0, length(stamps)), TOY_RESOLUTION,
                ),
            )
            AustralianElectricityMarkets.replace_single_series!(
                sys, device,
                AustralianElectricityMarkets.single_series(series, TOY_START, fill(offer(sys, stamps), length(stamps)), TOY_RESOLUTION),
            )
            return
        end
    end
    toy(mutate!) = nem_toy_system(
        [TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = 0.0, ramp_up = 100.0)], 50.0;
        loads = [TOY_LOAD_SERVICE_ONLY => toy_load(50.0, 30.0; initial = 0.0, ramp_up = 100.0)], mutate!,
    )
    sys = toy(stray(ThermalStandard, TOY_CHEAP, OfferSide.LOAD, "energy_offer_decremental"))
    status, log = _toy_build_log(toy_model(sys; template = template_for(sys)))
    @test status == PSI.ModelBuildStatus.FAILED
    @test occursin("$TOY_CHEAP: the device carries an unpriced LOAD energy offer series", log)

    sys = toy(stray(InterruptiblePowerLoad, TOY_LOAD_SERVICE_ONLY, OfferSide.GEN, "energy_offer"))
    status, log = _toy_build_log(toy_model(sys; template = template_for(sys)))
    @test status == PSI.ModelBuildStatus.FAILED
    @test occursin("$TOY_LOAD_SERVICE_ONLY: the device carries an unpriced GEN energy offer series", log)
end
