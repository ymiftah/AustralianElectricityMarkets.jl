# Pins the tie-break row a price tie builds between two energy offer bands, so a change to where NEM
# bids are stored can prove it left the optimisation unchanged.

@testset "tie-break: two units tied at one band price" begin
    sys = nem_toy_system(
        [
            TOY_CHEAP => toy_unit(100.0, [(60.0, 20.0)]; initial = 0.0, ramp_up = 100.0),
            TOY_EXPENSIVE => toy_unit(100.0, [(40.0, 20.0)]; initial = 0.0, ramp_up = 100.0),
        ],
        50.0,
    )
    out = solve_toy(sys)
    container = out.container
    bands = PSI.get_variable(container, EnergyOfferBandVariable(), ThermalStandard, "gen")
    objective = PSI.JuMP.objective_function(PSI.get_jump_model(container))
    # One row `s_b x_a - s_a x_b + up - down = 0`, its slacks priced at TIE_BREAK_CVP_FACTOR $/MWh.
    row = only(values(PSI.get_constraint(container, TieBreakConstraint(), EnergyTieBreak, TIE_BREAK_SERVICE_NAME).data))
    terms = PSI.JuMP.constraint_object(row).func.terms
    @test length(terms) == 4
    @test terms[bands[TOY_CHEAP, "1", 1]] ≈ 2 / 3 atol = 1.0e-9
    @test terms[bands[TOY_EXPENSIVE, "1", 1]] ≈ -1.0 atol = 1.0e-9
    slacks = [v for v in keys(terms) if !(v in (bands[TOY_CHEAP, "1", 1], bands[TOY_EXPENSIVE, "1", 1]))]
    @test PSI.JuMP.coefficient.(objective, slacks) ≈ fill(TIE_BREAK_CVP_FACTOR * 100.0 / 12.0, 2) atol = 1.0e-12
end
