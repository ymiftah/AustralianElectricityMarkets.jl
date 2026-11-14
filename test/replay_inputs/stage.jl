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

@testset "a change of availability after the replay inputs are written is refused, naming the component" begin
    hive = mktempdir()
    create_mock_data(hive; complete_inputs = true)
    write_mock_interconnector_results(hive)
    db = aem_connect(HiveConfiguration(hive_location = hive))
    t = DateTime(2025, 1, 1, 0, 5)
    sys = nem_system(db, NEMDEConfiguration(); date_range = t:Minute(5):(t + Minute(20)))
    @test isnothing(AustralianElectricityMarkets._check_replay_availability(sys))
    device = first(AustralianElectricityMarkets.nem_dispatch_devices(sys))
    PowerSystems.set_available!(device, false)
    err = try
        AustralianElectricityMarkets._check_replay_availability(sys)
        nothing
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin("made unavailable: $(nameof(typeof(device))) $(PowerSystems.get_name(device))", err.msg)
    PowerSystems.set_available!(device, true)
    @test isnothing(AustralianElectricityMarkets._check_replay_availability(sys))
    # A system without replay inputs carries no recorded availability.
    regional = nem_system(db, RegionalNetworkConfiguration())
    @test_throws ArgumentError AustralianElectricityMarkets._check_replay_availability(regional)

    @testset "a build report written before unavailable_constraints throws instead of a KeyError" begin
        old = deepcopy(sys)
        delete!(PowerSystems.get_ext(old)["build_report"], "unavailable_constraints")
        @test_throws ArgumentError get_build_report(old)
    end
end

@testset "the replay inputs refuse single time series off the dispatch interval" begin
    sys = PowerSystems.System(100.0)
    bus = PowerSystems.ACBus(; number = 1, name = "b", bustype = PowerSystems.ACBusTypes.REF, angle = 0.0, magnitude = 1.0, voltage_limits = nothing, base_voltage = 1.0, available = true)
    PowerSystems.add_component!(sys, bus)
    load = PowerSystems.PowerLoad(; name = "l", available = true, bus, active_power = 0.0, reactive_power = 0.0, base_power = 100.0, max_active_power = 1.0, max_reactive_power = 0.0)
    PowerSystems.add_component!(sys, load)
    stamps = DateTime(2025, 1, 1):Hour(1):DateTime(2025, 1, 1, 3)
    PowerSystems.add_time_series!(sys, load, PowerSystems.SingleTimeSeries("max_active_power", PowerSystems.TimeSeries.TimeArray(collect(stamps), ones(4))))
    err = try
        AustralianElectricityMarkets._set_replay_inputs!(sys)
        nothing
    catch e
        e
    end
    @test err isa ArgumentError && occursin("dispatch intervals", err.msg) && occursin("1 hour", err.msg)
end

@testset "a NEMDE replay system round-trips through JSON with its replay inputs" begin
    hive = mktempdir()
    create_mock_data(hive; complete_inputs = true)
    write_mock_interconnector_results(hive)
    db = aem_connect(HiveConfiguration(hive_location = hive))
    t = DateTime(2025, 1, 1, 0, 5)
    sys = nem_system(db, NEMDEConfiguration(); date_range = t:Minute(5):(t + Minute(20)))
    path = joinpath(mktempdir(), "sys.json")
    to_json(sys, path; force = true)
    sys2 = System(path)
    AEM_ = AustralianElectricityMarkets
    @test PowerSystems.get_time_series_counts(sys2) == PowerSystems.get_time_series_counts(sys)
    @test replay_intervals(sys2) == replay_intervals(sys)
    @test length(collect(get_components(AEM_.EnergyTieBreak, sys2))) == 1
    @test get_build_report(sys2) == get_build_report(sys)
    @test isnothing(AEM_._check_replay_availability(sys2))
    prices(s, f) = sort(
        [
            (get_name(d), string(hasproperty(b, :service) ? b.service : b.direction), b.band_prices) for d in AEM_.nem_dispatch_devices(s)
                for c in (AEM_._nem_offer_cost(d),) if !isnothing(c) for b in f(c)
        ]; by = string,
    )
    @test !isempty(prices(sys, AEM_.get_fcas_bids))
    @test prices(sys2, AEM_.get_fcas_bids) == prices(sys, AEM_.get_fcas_bids)
    @test prices(sys2, AEM_.get_energy_bids) == prices(sys, AEM_.get_energy_bids)
    # Tie-break scales are series on the devices and survive with the forecasts.
    scale_names(s) = sort([k.name for d in AEM_.nem_dispatch_devices(s) for k in PowerSystems.get_time_series_keys(d) if startswith(k.name, "tie_break_scale")])
    @test scale_names(sys2) == scale_names(sys)
end
