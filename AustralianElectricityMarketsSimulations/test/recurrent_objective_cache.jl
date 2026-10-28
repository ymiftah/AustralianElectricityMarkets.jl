# The second forecast must be served from the model cache even when its HDF5 file is unavailable.
function _objective_cache_system()
    sys = fcas_toy_system()
    alta = PSY.get_component(PSY.ThermalStandard, sys, TOY_CHEAP)
    gc = PSY.get_component(GenericConstraint, sys, "F_REG")
    curve_name = "fcas_curve_RAISEREG"
    replacements = (
        (alta, curve_name, [_toy_offer([(0.1, 5.0), (0.1, 12.0)]), _toy_offer([(0.1, 15.0), (0.1, 22.0)])]),
        (gc, "invoked", [1.0, 0.0]),
    )
    for (owner, name, values) in replacements
        PSY.remove_time_series!(sys, PSY.DeterministicSingleTimeSeries, owner, name)
        AustralianElectricityMarkets.replace_single_series!(
            sys, owner, AustralianElectricityMarkets.single_series(name, TOY_START, values, TOY_RESOLUTION),
        )
    end
    PSY.transform_single_time_series!(sys, TOY_RESOLUTION, TOY_RESOLUTION)
    return sys
end

function _update_objective_cache_parameters!(model, keys, execution_count)
    container = PSI.get_optimization_container(model)
    objective = PSI.get_objective_expression(container)
    PSI.reset_variant_terms(objective)
    PSI.set_synchronized_status!(objective, false)
    PSI.set_execution_count!(model, execution_count)
    input = PSI.DatasetContainer{PSI.InMemoryDataset}()
    for key in keys
        PSI.update_container_parameter_values!(container, model, key, input)
    end
    return
end

@testset "disk-backed objective updates reuse forecasts and retain second-step values" begin
    for cached in (true, false)
        mktempdir() do folder
            sys = _objective_cache_system()
            @test !PSY.stores_time_series_in_memory(sys)
            template = replication_template(sys)
            service_model = PSI.get_model(template, GenericConstraint, "F_REG")
            PSI.get_attributes(service_model)["market_price_cap"] = 12345.0
            model = PSI.DecisionModel(
                template, sys; horizon = TOY_RESOLUTION, resolution = TOY_RESOLUTION,
                interval = TOY_RESOLUTION, initial_time = TOY_START,
                optimizer = PSI.optimizer_with_attributes(HiGHS.Optimizer, "output_flag" => false),
                time_series_cache_size = cached ? 1024 * 1024 : 0,
            )
            @test PSI.build!(model; output_dir = joinpath(folder, "model")) == PSI.ModelBuildStatus.BUILT
            container = PSI.get_optimization_container(model)
            keys = [k for k in Base.keys(PSI.get_parameters(model)) if PSI.IS.Optimization.get_entry_type(k) in (FCASBandPriceParameter, AEMS.GenericConstraintSlackCostParameter)]
            price_key = only(k for k in keys if PSI.IS.Optimization.get_entry_type(k) === FCASBandPriceParameter && startswith(k.meta, "1_RAISEREG") && TOY_CHEAP in axes(PSI.get_parameter_array(container, k))[1])
            invoked_key = only(k for k in keys if PSI.IS.Optimization.get_entry_type(k) === AEMS.GenericConstraintSlackCostParameter && k.meta == "F_REG")
            _update_objective_cache_parameters!(model, keys, 0)
            @test PSI.get_parameter_array(container, price_key)[TOY_CHEAP, "1", 1] == 5.0
            @test PSI.get_parameter_column_refs(PSI.get_parameter(container, invoked_key), "F_REG")[1] == 1.0
            slack = PSI.get_variable(container, GenericConstraintSlackDown(), GenericConstraint, "F_REG")["F_REG", 1]
            gc = PSY.get_component(GenericConstraint, sys, "F_REG")
            penalty = PSI.get_base_power(container) * interval_cost_coefficient(AustralianElectricityMarkets.constraint_cvp_factor(gc), PSI.get_resolution(container))
            @test PSI.JuMP.coefficient(PSI.get_variant_terms(PSI.get_objective_expression(container)), slack) == 12345.0 * penalty
            storage = PSI.IS.get_time_series_storage(PSY.get_component(PSY.ThermalStandard, sys, TOY_CHEAP))
            path = storage.file_path
            cached && mv(path, path * ".hidden")
            try
                _update_objective_cache_parameters!(model, keys, 1)
                @test PSI.get_parameter_array(container, price_key)[TOY_CHEAP, "1", 1] == 15.0
                @test PSI.get_parameter_column_refs(PSI.get_parameter(container, invoked_key), "F_REG")[1] == 0.0
                objective = PSI.get_variant_terms(PSI.get_objective_expression(container))
                @test PSI.JuMP.coefficient(objective, slack) == 0.0
                band = PSI.get_variable(container, FCASOfferBandVariable(), FCASService, price_key.meta)[TOY_CHEAP, "1", 1]
                @test PSI.JuMP.coefficient(objective, band) ≈ 15.0 * 100.0 / 12
                @test cached || isempty(PSI.get_time_series_cache(model))
            finally
                cached && mv(path * ".hidden", path)
            end
        end
    end
end

@testset "energy offer slopes reuse disk-backed data without changing unit conversion" begin
    for cached in (true, false)
        mktempdir() do folder
            units = Dict(TOY_CHEAP => toy_unit(50.0, [[(20.0, 10.0)], [(35.0, 30.0)]]; initial = 0.0, ramp_up = 100.0))
            sys = nem_toy_system(
                units, 10.0; horizon = TOY_RESOLUTION,
                batteries = ["BAT" => toy_battery(20.0, 75.0, 20.0, 25.0; initial = 0.0, ramp_up = 100.0)],
                loads = ["LOAD" => toy_load(20.0, 40.0; initial = 0.0, ramp_up = 100.0)],
            )
            model = PSI.DecisionModel(
                replication_template(sys), sys; horizon = TOY_RESOLUTION, resolution = TOY_RESOLUTION,
                interval = TOY_RESOLUTION, initial_time = TOY_START,
                optimizer = PSI.optimizer_with_attributes(HiGHS.Optimizer, "output_flag" => false),
                time_series_cache_size = cached ? 1024 * 1024 : 0,
            )
            @test PSI.build!(model; output_dir = joinpath(folder, "model")) == PSI.ModelBuildStatus.BUILT
            container = PSI.get_optimization_container(model)
            keys = [k for k in Base.keys(PSI.get_parameters(model)) if PSI.IS.Optimization.get_entry_type(k) <: PSI.AbstractPiecewiseLinearSlopeParameter]
            _update_objective_cache_parameters!(model, keys, 0)
            gen_band = PSI.get_variable(container, PSI.PiecewiseLinearBlockIncrementalOffer(), PSY.ThermalStandard)[TOY_CHEAP, 1, 1]
            @test PSI.JuMP.coefficient(PSI.get_variant_terms(PSI.get_objective_expression(container)), gen_band) ≈ 10.0 * 100.0 / 12
            path = PSI.IS.get_time_series_storage(PSY.get_component(PSY.ThermalStandard, sys, TOY_CHEAP)).file_path
            cached && mv(path, path * ".hidden")
            try
                @test_nowarn _update_objective_cache_parameters!(model, keys, 1)
                objective = PSI.get_variant_terms(PSI.get_objective_expression(container))
                @test PSI.JuMP.coefficient(objective, gen_band) ≈ 30.0 * 100.0 / 12
                for (T, name, band_type, price) in (
                        (PSY.EnergyReservoirStorage, "BAT", PSI.PiecewiseLinearBlockIncrementalOffer, 75.0),
                        (PSY.EnergyReservoirStorage, "BAT", PSI.PiecewiseLinearBlockDecrementalOffer, -25.0),
                        (PSY.InterruptiblePowerLoad, "LOAD", PSI.PiecewiseLinearBlockDecrementalOffer, -40.0),
                    )
                    band = PSI.get_variable(container, band_type(), T)[name, 1, 1]
                    @test PSI.JuMP.coefficient(objective, band) ≈ price * 100.0 / 12
                end
                @test cached || isempty(PSI.get_time_series_cache(model))
            finally
                cached && mv(path * ".hidden", path)
            end
        end
    end
end

@testset "structured caches bound history and refill with current values" begin
    sys = fcas_toy_system()
    template = replication_template(sys)
    PSY.clear_time_series!(sys)
    device = PSY.get_component(PSY.ThermalStandard, sys, TOY_CHEAP)
    curves = [_toy_offer([(10.0, Float64(i))]) for i in 1:60]
    PSY.add_time_series!(sys, device, AustralianElectricityMarkets.single_series("variable_cost", TOY_START, curves, TOY_RESOLUTION))
    PSY.add_time_series!(sys, device, AustralianElectricityMarkets.single_series("fcas_curve_RAISEREG", TOY_START, curves, TOY_RESOLUTION))
    PSY.transform_single_time_series!(sys, TOY_RESOLUTION, TOY_RESOLUTION)
    model = PSI.DecisionModel(
        template, sys;
        initial_time = TOY_START, horizon = TOY_RESOLUTION, resolution = TOY_RESOLUTION,
        interval = TOY_RESOLUTION,
    )
    read_energy(start) = PSI.get_time_series_values!(PSY.DeterministicSingleTimeSeries, model, device, "variable_cost", start, 1)
    for i in 1:60
        start = TOY_START + (i - 1) * TOY_RESOLUTION
        energy = read_energy(start)
        forecast = AEMS._forecast_window_values(model, device, "fcas_curve_RAISEREG", start)
        @test PSY.get_y_coords(only(energy)) == [Float64(i)]
        @test PSY.get_y_coords(only(forecast)) == [Float64(i)]
        if i in (1, 24, 25, 48, 49, 60)
            caches = PSI.get_time_series_cache(model)
            @test any(k -> k isa PSI.IS.TimeSeriesCacheKey && k.name == "variable_cost", keys(caches))
            @test all(c -> Base.summarysize(PSI.IS._get_time_series(c)) < 100_000, values(caches))
            @test PSY.get_y_coords(only(read_energy(start))) == [Float64(i)]
        end
    end
    @test_throws PSI.IS.InvalidValue read_energy(TOY_START)
    PSI.empty_time_series_cache!(model)
    @test PSY.get_y_coords(only(read_energy(TOY_START))) == [1.0]
end

@testset "bid cache is used when enabled and skipped when disabled" begin
    sys = fcas_toy_system()
    template = replication_template(sys)
    PSY.clear_time_series!(sys)
    device = PSY.get_component(PSY.ThermalStandard, sys, TOY_CHEAP)
    curves = [_toy_offer([(10.0, Float64(i))]) for i in 1:3]
    series = AustralianElectricityMarkets.single_series("variable_cost", TOY_START, curves, TOY_RESOLUTION)
    PSY.add_time_series!(sys, device, series)
    PSY.transform_single_time_series!(sys, TOY_RESOLUTION, TOY_RESOLUTION)
    for budget in (0, 1024 * 1024)
        model = PSI.DecisionModel(
            template, sys; initial_time = TOY_START, horizon = TOY_RESOLUTION,
            resolution = TOY_RESOLUTION, interval = TOY_RESOLUTION, time_series_cache_size = budget,
        )
        for i in 1:3
            stamp = TOY_START + (i - 1) * TOY_RESOLUTION
            values = PSI.get_time_series_values!(PSY.DeterministicSingleTimeSeries, model, device, "variable_cost", stamp, 1)
            @test PSY.get_y_coords(only(values)) == [Float64(i)]
        end
        caches = PSI.get_time_series_cache(model)
        if budget == 0
            @test isempty(caches)
        else
            @test any(k -> k isa PSI.IS.TimeSeriesCacheKey && k.name == "variable_cost", keys(caches))
        end
    end
end
