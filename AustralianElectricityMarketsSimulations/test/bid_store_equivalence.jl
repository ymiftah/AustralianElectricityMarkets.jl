# Pins the toy dispatch, area prices, objective and the objective coefficient of every offer band
# variable, so a change to where NEM bids are stored can prove it left the optimisation unchanged.

# Offer band variable meta whose objective coefficients are pinned, with the side each carries.
const _BAND_VARIABLE_TYPES = (
    "gen" => OfferSide.GEN,
    "load" => OfferSide.LOAD,
)

# The objective coefficient the solver sees on each energy band variable of `container` (the
# `PSI.OptimizationContainer`, e.g. `out.container` from `solve_toy`, not the DecisionModel),
# keyed `(device name, side, band, t)`.
function _band_variable_coefficients(container)
    objective = PSI.JuMP.objective_function(PSI.get_jump_model(container))
    coefficients = Dict{Tuple{String, OfferSide, Int, Int}, Float64}()
    for (meta, side) in _BAND_VARIABLE_TYPES, key in PSI.get_variable_keys(container)
        PSI.IS.Optimization.get_entry_type(key) === EnergyOfferBandVariable && key.meta == meta || continue
        variables = PSI.get_variable(container, key)
        for name in axes(variables, 1), label in axes(variables, 2), t in axes(variables, 3)
            coefficients[(name, side, parse(Int, label), t)] = PSI.JuMP.coefficient(objective, variables[name, label, t])
        end
    end
    return coefficients
end

# The terms of every tie-break row of `container`, as `(row coefficients by (name, side, band, t),
# objective coefficients of its two slacks)` pairs, in a stable order. Band variables are named
# through `_BAND_VARIABLE_TYPES`.
function _tie_break_terms(container)
    names = Dict{PSI.JuMP.VariableRef, Tuple{String, OfferSide, Int, Int}}()
    for (meta, side) in _BAND_VARIABLE_TYPES, key in PSI.get_variable_keys(container)
        PSI.IS.Optimization.get_entry_type(key) === EnergyOfferBandVariable && key.meta == meta || continue
        variables = PSI.get_variable(container, key)
        for name in axes(variables, 1), label in axes(variables, 2), t in axes(variables, 3)
            names[variables[name, label, t]] = (name, side, parse(Int, label), t)
        end
    end
    objective = PSI.JuMP.objective_function(PSI.get_jump_model(container))
    rows = PSI.get_constraint(container, TieBreakConstraint(), EnergyTieBreak, TIE_BREAK_SERVICE_NAME)
    terms = []
    for row in values(rows.data)
        func = PSI.JuMP.constraint_object(row).func
        bands = Dict(names[v] => c for (v, c) in func.terms if haskey(names, v))
        slacks = sort!([PSI.JuMP.coefficient(objective, v) for (v, _) in func.terms if !haskey(names, v)])
        push!(terms, (bands, slacks))
    end
    return terms
end

# The raw CopperPlateBalanceConstraint dual of the single area, in $ per base-power MW.
function _area_balance_dual(out)
    return only(read_dual(out.results, "CopperPlateBalanceConstraint__Area").value)
end

@testset "bid store equivalence on the toy fixture" begin
    # $/MWh x base power (100 MW) x interval hours (1/12).
    per_mwh = 100.0 / 12.0

    @testset "merit order: two units, one band each" begin
        sys = nem_toy_system(
            [
                TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = 60.0, ramp_up = 100.0),
                TOY_EXPENSIVE => toy_unit(100.0, [(100.0, 80.0)]; initial = 60.0, ramp_up = 100.0),
            ],
            120.0,
        )
        out = solve_toy(sys)

        @test out.dispatch_mw[TOY_CHEAP] ≈ 100.0 atol = 1.0e-6
        @test out.dispatch_mw[TOY_EXPENSIVE] ≈ 20.0 atol = 1.0e-6
        @test out.price ≈ 80.0 atol = 1.0e-6
        @test _area_balance_dual(out) ≈ 80.0 * per_mwh atol = 1.0e-6
        @test out.objective ≈ 300.0 atol = 1.0e-6

        coefficients = _band_variable_coefficients(out.container)
        @test length(coefficients) == 2
        @test coefficients[(TOY_CHEAP, OfferSide.GEN, 1, 1)] ≈ 20.0 * per_mwh atol = 1.0e-6
        @test coefficients[(TOY_EXPENSIVE, OfferSide.GEN, 1, 1)] ≈ 80.0 * per_mwh atol = 1.0e-6
    end

    @testset "battery charge: a load bid above the marginal offer" begin
        sys = nem_toy_system(
            [TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = 60.0, ramp_up = 100.0)],
            40.0;
            batteries = [TOY_BATTERY => toy_battery(10.0, 1000.0, 30.0, 50.0; initial = 0.0, ramp_up = 100.0)],
        )
        out = solve_toy(sys)

        @test out.dispatch_mw[TOY_CHEAP] ≈ 70.0 atol = 1.0e-6
        @test out.dispatch_mw[TOY_BATTERY] ≈ -30.0 atol = 1.0e-6
        @test out.battery_out_mw[TOY_BATTERY] ≈ 0.0 atol = 1.0e-6
        @test out.battery_in_mw[TOY_BATTERY] ≈ 30.0 atol = 1.0e-6
        @test out.price ≈ 20.0 atol = 1.0e-6
        @test _area_balance_dual(out) ≈ 20.0 * per_mwh atol = 1.0e-6
        @test out.objective ≈ -100.0 / 12.0 atol = 1.0e-6

        coefficients = _band_variable_coefficients(out.container)
        @test length(coefficients) == 3
        @test coefficients[(TOY_CHEAP, OfferSide.GEN, 1, 1)] ≈ 20.0 * per_mwh atol = 1.0e-6
        @test coefficients[(TOY_BATTERY, OfferSide.GEN, 1, 1)] ≈ 1000.0 * per_mwh atol = 1.0e-6
        @test coefficients[(TOY_BATTERY, OfferSide.LOAD, 1, 1)] ≈ -50.0 * per_mwh atol = 1.0e-6
    end

    @testset "tie-break: two units tied at one band price" begin
        sys = nem_toy_system(
            [
                TOY_CHEAP => toy_unit(100.0, [(60.0, 20.0)]; initial = 0.0, ramp_up = 100.0),
                TOY_EXPENSIVE => toy_unit(100.0, [(40.0, 20.0)]; initial = 0.0, ramp_up = 100.0),
            ],
            50.0,
        )
        out = solve_toy(sys)

        # The 50 MW load splits pro rata to the 60 and 40 MW bands.
        @test out.dispatch_mw[TOY_CHEAP] ≈ 30.0 atol = 1.0e-6
        @test out.dispatch_mw[TOY_EXPENSIVE] ≈ 20.0 atol = 1.0e-6
        @test out.price ≈ 20.0 atol = 1.0e-6
        @test _area_balance_dual(out) ≈ 20.0 * per_mwh atol = 1.0e-6
        @test out.objective ≈ 20.0 * 50.0 / 12.0 atol = 1.0e-6

        # One row `s_b x_a - s_a x_b + up - down = 0`, its slacks priced at TIE_BREAK_CVP_FACTOR $/MWh.
        terms = _tie_break_terms(out.container)
        @test length(terms) == 1
        bands, slacks = only(terms)
        @test length(bands) == 2
        @test bands[(TOY_CHEAP, OfferSide.GEN, 1, 1)] ≈ 2 / 3 atol = 1.0e-9
        @test bands[(TOY_EXPENSIVE, OfferSide.GEN, 1, 1)] ≈ -1.0 atol = 1.0e-9
        @test slacks ≈ fill(TIE_BREAK_CVP_FACTOR * per_mwh, 2) atol = 1.0e-12
    end
end
