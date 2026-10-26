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
            @test PSI.get_parameter_array(container, invoked_key)["F_REG", 1] == 1.0
            slack = PSI.get_variable(container, GenericConstraintSlackDown(), GenericConstraint, "F_REG")["F_REG", 1]
            penalty = PSI.get_parameter_multiplier_array(container, invoked_key)["F_REG", 1]
            @test PSI.JuMP.coefficient(PSI.get_variant_terms(PSI.get_objective_expression(container)), slack) == 12345.0 * penalty
            storage = PSI.IS.get_time_series_storage(PSY.get_component(PSY.ThermalStandard, sys, TOY_CHEAP))
            path = storage.file_path
            cached && mv(path, path * ".hidden")
            try
                _update_objective_cache_parameters!(model, keys, 1)
                @test PSI.get_parameter_array(container, price_key)[TOY_CHEAP, "1", 1] == 15.0
                @test PSI.get_parameter_array(container, invoked_key)["F_REG", 1] == 0.0
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

include(joinpath(@__DIR__, "real_data", "benchmark_updates.jl"))

@testset "benchmark snapshot iteration handles dense and sparse containers" begin
    jm = PSI.JuMP.Model()
    dense = PSI.JuMP.@variable(jm, dense[["a", "b"], 1:2])
    sparse = PSI.JuMP.Containers.SparseAxisArray(
        Dict{Tuple{String, Int, Int}, Any}(("a", 1, 1) => dense["a", 1], ("b", 2, 1) => dense["b", 2], ("c", 3, 1) => 0.0),
    )
    @test Set(first(pair) for pair in _benchmark_entries(dense)) == Set([("a", 1), ("a", 2), ("b", 1), ("b", 2)])
    @test Set(first(pair) for pair in _benchmark_entries(sparse)) == Set([("a", 1, 1), ("b", 2, 1), ("c", 3, 1)])
    @test count(pair -> last(pair) isa PSI.JuMP.VariableRef, _benchmark_entries(sparse)) == 2
    @test collect(_benchmark_entries([2.0, 3.0])) == [(1,) => 2.0, (2,) => 3.0]
end
