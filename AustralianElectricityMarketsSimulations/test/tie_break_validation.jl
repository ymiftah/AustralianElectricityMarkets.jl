@testset "tie-break rows bind EnergyOfferBandVariable bands" begin
    sys = nem_toy_system(
        [
            TOY_CHEAP => toy_unit(100.0, [(60.0, 20.0)]; initial = 0.0, ramp_up = 100.0),
            TOY_EXPENSIVE => toy_unit(100.0, [(40.0, 20.0)]; initial = 0.0, ramp_up = 100.0),
        ],
        50.0;
        batteries = [TOY_BATTERY => toy_battery(30.0, 20.0, 10.0, 5.0; initial = 0.0, ramp_up = 100.0)],
    )
    out = solve_toy(sys)
    rows = PSI.get_constraint(out.container, TieBreakConstraint(), EnergyTieBreak, TIE_BREAK_SERVICE_NAME)
    band_variables = Set{PSI.JuMP.VariableRef}()
    for key in PSI.get_variable_keys(out.container)
        PSI.IS.Optimization.get_entry_type(key) === EnergyOfferBandVariable || continue
        union!(band_variables, values(PSI.get_variable(out.container, key).data))
    end
    @test !isempty(rows.data)
    for row in values(rows.data)
        terms = PSI.JuMP.constraint_object(row).func.terms
        bands = [v for v in keys(terms) if v in band_variables]
        @test length(bands) == 2
        @test all(v -> v in band_variables || startswith(PSI.JuMP.name(v), "TieBreakSlack"), keys(terms))
    end
    @test out.dispatch_mw[TOY_CHEAP] / 60.0 ≈ out.dispatch_mw[TOY_EXPENSIVE] / 40.0 atol = 1.0e-5
end
