# The second forecast must be served from the model cache even when its HDF5 file is unavailable.
function _objective_cache_system()
    sys = fcas_toy_system()
    gc = PSY.get_component(GenericConstraint, sys, "F_REG")
    replacements = (
        (gc, AustralianElectricityMarkets.NEM_CONSTRAINT_SERIES.invoked, [1.0, 0.0, 0.0]),
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
            template = replay_template(sys)
            model = PSI.DecisionModel(
                template, sys; horizon = TOY_RESOLUTION, resolution = TOY_RESOLUTION,
                interval = TOY_RESOLUTION, initial_time = TOY_START,
                optimizer = PSI.optimizer_with_attributes(HiGHS.Optimizer, "output_flag" => false),
                time_series_cache_size = cached ? 1024 * 1024 : 0,
            )
            PSI.get_ext(PSI.get_settings(model))["market_price_cap"] = 12345.0
            @test PSI.build!(model; output_dir = joinpath(folder, "model")) == PSI.ModelBuildStatus.BUILT
            container = PSI.get_optimization_container(model)
            keys = [k for k in Base.keys(PSI.get_parameters(model)) if PSI.IS.Optimization.get_entry_type(k) === AEMS.GenericConstraintSlackCostParameter]
            invoked_key = only(k for k in keys if k.meta == "F_REG")
            _update_objective_cache_parameters!(model, keys, 0)
            @test PSI.get_parameter_column_refs(PSI.get_parameter(container, invoked_key), "F_REG")[1] == 1.0
            slack = PSI.get_variable(container, GenericConstraintSlackDown(), GenericConstraint, "F_REG")["F_REG", 1]
            gc = PSY.get_component(GenericConstraint, sys, "F_REG")
            penalty = PSI.get_base_power(container) * interval_cost_coefficient(AustralianElectricityMarkets.constraint_cvp_factor(gc), PSI.get_resolution(container))
            @test PSI.JuMP.coefficient(PSI.get_variant_terms(PSI.get_objective_expression(container)), slack) == 12345.0 * penalty
            storage = PSI.IS.get_time_series_storage(PSY.get_component(ThermalStandard, sys, TOY_CHEAP))
            path = storage.file_path
            cached && mv(path, path * ".hidden")
            try
                _update_objective_cache_parameters!(model, keys, 1)
                @test PSI.get_parameter_column_refs(PSI.get_parameter(container, invoked_key), "F_REG")[1] == 0.0
                objective = PSI.get_variant_terms(PSI.get_objective_expression(container))
                @test PSI.JuMP.coefficient(objective, slack) == 0.0
                @test cached || isempty(PSI.get_time_series_cache(model))
            finally
                cached && mv(path * ".hidden", path)
            end
        end
    end
end

@testset "structured caches bound history and refill with current values" begin
    sys = fcas_toy_system()
    template = replay_template(sys)
    PSY.clear_time_series!(sys)
    device = PSY.get_component(ThermalStandard, sys, TOY_CHEAP)
    curves = [_toy_offer([(10.0, Float64(i))]) for i in 1:60]
    PSY.add_time_series!(sys, device, AustralianElectricityMarkets.single_series("variable_cost", TOY_START, curves, TOY_RESOLUTION))
    curve_name = AustralianElectricityMarkets._fcas_offer_series_name(device, BidType.RAISEREG, false)
    PSY.add_time_series!(sys, device, AustralianElectricityMarkets.single_series(curve_name, TOY_START, curves, TOY_RESOLUTION))
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
        forecast = PSI.get_time_series_values!(
            PSI.get_default_time_series_type(PSI.get_optimization_container(model)), model, device, curve_name, start,
            length(PSI.get_time_steps(PSI.get_optimization_container(model)));
            interval = PSI.get_interval(PSI.get_settings(model)), ignore_scaling_factors = true,
        )
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
    template = replay_template(sys)
    PSY.clear_time_series!(sys)
    device = PSY.get_component(ThermalStandard, sys, TOY_CHEAP)
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
