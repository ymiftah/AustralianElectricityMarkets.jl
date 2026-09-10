@testset "Augmented PowerSystemCaseBuilder system" begin
    sys = augmented_pscb_system()

    @testset "base case survives augmentation" begin
        @test Set(get_name(a) for a in get_components(Area, sys)) == Set(["1", "2"])
        for duid in ("Alta", "Brighton", "Park City", "Sundance", "Solitude")
            @test !isnothing(get_component(ThermalStandard, sys, duid))
        end
        @test !isnothing(get_component(HydroDispatch, sys, "HydroDispatch2"))
    end

    # `add_nem_constraints!` resolves each term kind with exactly these three lookups, so a
    # constraint referencing any of them must resolve rather than be skipped.
    @testset "every constraint term kind resolves" begin
        @test !isnothing(get_component(Device, sys, "Alta"))              # UnitTerm
        @test !isnothing(get_component(Area, sys, "1"))                   # RegionTerm
        @test !isnothing(get_component(AreaInterchange, sys, "IC1"))      # InterconnectorTerm
    end

    @testset "FCAS bid branches have a component to attach to" begin
        # set_fcas_bids! walks Generators for incremental bids, and handles
        # EnergyReservoirStorage separately to also attach decremental (LOAD) series.
        gen_names = Set(get_name(g) for g in get_components(Generator, sys))
        @test "SOLAR1" in gen_names
        @test "BAT1" ∉ gen_names
        @test !isnothing(get_component(EnergyReservoirStorage, sys, "BAT1"))
    end

    @testset "added components are what the NEMWEB fixture will key to" begin
        @test get_name.(get_components(AreaInterchange, sys)) == ["IC1"]
        @test get_name.(get_components(RenewableDispatch, sys)) == ["SOLAR1"]
        @test get_name.(get_components(EnergyReservoirStorage, sys)) == ["BAT1"]
        ic = get_component(AreaInterchange, sys, "IC1")
        @test get_name(get_from_area(ic)) == "1"
        @test get_name(get_to_area(ic)) == "2"
        @test get_prime_mover_type(get_component(RenewableDispatch, sys, "SOLAR1")) == PrimeMovers.PVe
    end
end
