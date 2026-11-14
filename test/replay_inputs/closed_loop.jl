# With the observed starting output, the closed-loop inputs of an interval are the series nem_system wrote.
@testset "closed-loop inputs equal the written series for the observed state" begin
    hive = mktempdir()
    create_mock_data(hive; complete_inputs = true)
    write_mock_interconnector_results(hive)
    db = aem_connect(HiveConfiguration(hive_location = hive))
    t0 = DateTime(2025, 1, 1, 0, 5)
    sys = nem_system(db, NEMDEConfiguration(); date_range = t0:Minute(5):(t0 + Minute(20)))
    AEM_ = AustralianElectricityMarkets
    base = PowerSystems.get_base_power(sys)
    checked = Dict{Symbol, Int}()
    for device in AEM_.nem_dispatch_devices(sys)
        observed = AEM_.get_observed_state(device)
        observed.initial_mw isa PowerSystems.IS.StaticTimeSeriesKey || continue
        for key in PowerSystems.get_time_series_keys(device)
            key isa PowerSystems.IS.StaticTimeSeriesKey || continue
            name = key.name
            is_state_dependent_input(name) || continue
            for t in replay_intervals(sys)
                initial = only(AEM_._initial_mw_series(device, [t]))
                value = closed_loop_input(device, name, t, initial, base)
                isnothing(value) && continue
                written = only(PowerSystems.get_time_series_values(PowerSystems.SingleTimeSeries, device, name; start_time = t, len = 1))
                @test all(isapprox.(collect(value), collect(written); atol = 1.0e-12))
                family = first(AEM_._closed_loop_family(name))
                checked[family] = get(checked, family, 0) + 1
            end
        end
    end
    @test get(checked, :fcas_offer, 0) > 0
    @test get(checked, :fcas_ramping, 0) > 0
    @test get(checked, :ramp, 0) > 0
    @info "closed-loop inputs checked" checked
end

@testset "a different starting output changes a storage ramp rate and an FCAS ramping limit" begin
    hive = mktempdir()
    create_mock_data(hive; complete_inputs = true)
    write_mock_interconnector_results(hive)
    db = aem_connect(HiveConfiguration(hive_location = hive))
    t0 = DateTime(2025, 1, 1, 0, 5)
    sys = nem_system(db, NEMDEConfiguration(); date_range = t0:Minute(5):(t0 + Minute(20)))
    AEM_ = AustralianElectricityMarkets
    base = PowerSystems.get_base_power(sys)
    t = first(replay_intervals(sys))
    # The FCAS ramping limit is the starting output plus or minus the AGC capability.
    moved = false
    for device in AEM_.nem_dispatch_devices(sys), name in (fcas_ramping_series_name(BidType.RAISEREG), fcas_ramping_series_name(BidType.LOWERREG))
        PowerSystems.has_time_series(device, PowerSystems.SingleTimeSeries, name) || continue
        a = closed_loop_input(device, name, t, 10.0, base)
        b = closed_loop_input(device, name, t, 30.0, base)
        (isnothing(a) || a == b) && continue
        moved = true
        break
    end
    @test moved
    @test is_state_dependent_input(NEM_SERIES.ramp_up_rate)
    @test !is_state_dependent_input(NEM_SERIES.max_active_power)
end
