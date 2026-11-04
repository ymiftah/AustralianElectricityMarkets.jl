# Pins the toy dispatch, area prices, objective and the objective coefficient of every offer band
# variable, so a change to where NEM bids are stored can prove it left the optimisation unchanged.

# Offer variable types whose objective coefficients are pinned, with the side each carries.
const _BAND_VARIABLE_TYPES = (
    PSI.PiecewiseLinearBlockIncrementalOffer => OfferSide.GEN,
    PSI.PiecewiseLinearBlockDecrementalOffer => OfferSide.LOAD,
)

# The objective coefficient the solver sees on each energy band variable of `container`, keyed
# `(device name, side, band, t)`.
function _band_variable_coefficients(container)
    objective = PSI.JuMP.objective_function(PSI.get_jump_model(container))
    coefficients = Dict{Tuple{String, OfferSide, Int, Int}, Float64}()
    for (variable_type, side) in _BAND_VARIABLE_TYPES, key in PSI.get_variable_keys(container)
        PSI.IS.Optimization.get_entry_type(key) === variable_type || continue
        for ((name, band, t), variable) in pairs(PSI.get_variable(container, key).data)
            coefficients[(name, side, band, t)] = PSI.JuMP.coefficient(objective, variable)
        end
    end
    return coefficients
end

# The raw CopperPlateBalanceConstraint dual of the single area, in $ per base-power MW.
_area_balance_dual(out) = only(read_dual(out.results, "CopperPlateBalanceConstraint__Area").value)

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
end
