@testset "NEMUnitState carries the start-of-interval state" begin
    @test NEMUnitState(10.0, 0).initial_mw == 10.0
end

@testset "state rules are callable from AustralianElectricityMarkets" begin
    @test composite_ramp_rates(3.0, 4.0, 5.0, 6.0, 5.0, NEMUnitState(50.0, 4)) == (3.0, 4.0)
    @test composite_ramp_rates(3.0, 4.0, 5.0, 6.0, 5.0, NEMUnitState(-50.0, 4)) == (6.0, 5.0)
    @test fixed_load_invoked(50.0, NEMUnitState(10.0, 4))
    @test !fixed_load_invoked(50.0, NEMUnitState(10.0, 2))
end

@testset "replay interval stamps drop the two trailing stamps of the date range" begin
    hive = mktempdir()
    create_mock_data(hive; complete_inputs = true)
    write_mock_interconnector_results(hive)
    db = aem_connect(HiveConfiguration(hive_location = hive))
    t = DateTime(2025, 1, 1, 0, 5)
    sys = nem_system(db, NEMDEConfiguration(); date_range = t:Minute(5):(t + Minute(20)))
    @test AustralianElectricityMarkets._replay_interval_stamps(sys) == collect(t:Minute(5):(t + Minute(10)))
end
