const _ST_START = DateTime(2025, 1, 1, 0, 5)
const _ST_SYS = nemde_test_system()

@testset "dispatch interval stamps drop the two trailing stamps of the date range" begin
    @test AustralianElectricityMarkets._dispatch_interval_stamps(_ST_SYS) == collect(_ST_START:Minute(5):(_ST_START + Minute(10)))
end

@testset "a NEMDE system round-trips through JSON with its NEMDE inputs" begin
    AEM_ = AustralianElectricityMarkets
    sys = _ST_SYS
    path = joinpath(mktempdir(), "sys.json")
    to_json(sys, path; force = true)
    sys2 = System(path)
    @test PowerSystems.get_time_series_counts(sys2) == PowerSystems.get_time_series_counts(sys)
    @test dispatch_intervals(sys2) == dispatch_intervals(sys)
    @test get_build_report(sys2) == get_build_report(sys)
    @test isnothing(AEM_._check_nemde_availability(sys2))
    series_names(d) = sort([get_name(k) for k in get_time_series_keys(d) if get_time_series_type(k) === SingleTimeSeries])
    read(d) = [get_time_series_values(SingleTimeSeries, d, n; ignore_scaling_factors = true) for n in series_names(d)]
    @test all(get_components(StaticInjection, sys)) do device
        back = get_component(typeof(device), sys2, get_name(device))
        return series_names(back) == series_names(device) && read(back) == read(device)
    end
    tie_break(s) = sort!(get_name.(get_contributing_devices(s, only(get_components(AEM_.EnergyTieBreak, s)))))
    @test tie_break(sys2) == tie_break(sys)
    # Band prices are stored on the bids, not as series.
    prices(s, f) = sort(
        [
            (get_name(d), string(hasproperty(b, :service) ? b.service : b.direction), b.band_prices) for d in AEM_.nem_dispatch_devices(s)
                for c in (AEM_._nem_offer_cost(d),) if !isnothing(c) for b in f(c)
        ]; by = string,
    )
    @test !isempty(prices(sys, AEM_.get_fcas_bids))
    @test prices(sys2, AEM_.get_fcas_bids) == prices(sys, AEM_.get_fcas_bids)
    @test prices(sys2, AEM_.get_energy_bids) == prices(sys, AEM_.get_energy_bids)
end

@testset "a change of availability after the NEMDE inputs are written is refused, naming the component" begin
    sys = deepcopy(_ST_SYS)
    device = first(AustralianElectricityMarkets.nem_dispatch_devices(sys))
    PowerSystems.set_available!(device, false)
    err = (@test_throws ArgumentError AustralianElectricityMarkets._check_nemde_availability(sys)).value
    @test occursin("made unavailable: $(nameof(typeof(device))) $(PowerSystems.get_name(device))", err.msg)
    PowerSystems.set_available!(device, true)
    @test isnothing(AustralianElectricityMarkets._check_nemde_availability(sys))
    # A system without NEMDE inputs carries no recorded availability.
    @test_throws ArgumentError AustralianElectricityMarkets._check_nemde_availability(nem_system(nemde_test_db(), RegionalNetworkConfiguration()))
    # A build report written before unavailable_constraints throws instead of a KeyError.
    delete!(PowerSystems.get_ext(sys)["build_report"], "unavailable_constraints")
    @test_throws ArgumentError get_build_report(sys)
end

@testset "the NEMDE inputs refuse single time series off the dispatch interval" begin
    sys = PowerSystems.System(100.0)
    bus = PowerSystems.ACBus(; number = 1, name = "b", bustype = PowerSystems.ACBusTypes.REF, angle = 0.0, magnitude = 1.0, voltage_limits = nothing, base_voltage = 1.0, available = true)
    PowerSystems.add_component!(sys, bus)
    load = PowerSystems.PowerLoad(; name = "l", available = true, bus, active_power = 0.0, reactive_power = 0.0, base_power = 100.0, max_active_power = 1.0, max_reactive_power = 0.0)
    PowerSystems.add_component!(sys, load)
    stamps = DateTime(2025, 1, 1):Hour(1):DateTime(2025, 1, 1, 3)
    PowerSystems.add_time_series!(sys, load, PowerSystems.SingleTimeSeries("max_active_power", PowerSystems.TimeSeries.TimeArray(collect(stamps), ones(4))))
    err = (@test_throws ArgumentError AustralianElectricityMarkets._set_nemde_inputs!(sys)).value
    @test occursin("dispatch intervals", err.msg) && occursin("1 hour", err.msg)
end
