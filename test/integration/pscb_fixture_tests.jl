@testset "Augmented PowerSystemCaseBuilder system" begin
    sys = augmented_pscb_system()
    @test Set(get_name(a) for a in get_components(Area, sys)) == Set(["1", "2"])
    # Each component is what the NEMWEB fixture keys to; a missing one fails the constraint tests loudly.
    @test get_name.(get_components(AreaInterchange, sys)) == ["IC1"]
    @test get_name.(get_components(RenewableDispatch, sys)) == ["SOLAR1"]
    @test get_name.(get_components(EnergyReservoirStorage, sys)) == ["BAT1"]
    @test "BAT1" ∉ (get_name(g) for g in get_components(Generator, sys))
    @test !isnothing(get_component(Device, sys, "Alta"))
end
