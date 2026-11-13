# The loss demand coefficient kernel and the `loss_demand_coefficient` series, written on the mock replay
# System (AEMSim not loaded). Writer tests strip their own family's series and call the writer directly
# after editing the raw demand inputs.

const _LD_START = DateTime(2025, 1, 1, 0, 5)
const _LD_N = 4

# A NEM replay System on the mock hive, with its replay inputs written by `nem_system`.
function _ld_mock_system()
    hive = mktempdir()
    create_mock_data(hive; complete_inputs = true)
    write_mock_interconnector_results(hive)
    db = aem_connect(HiveConfiguration(hive_location = hive))
    return nem_system(db, NEMDEConfiguration(); date_range = _LD_START:Minute(5):(_LD_START + Minute(5 * _LD_N)))
end

# The error thrown by `f`.
function _ld_error(f)
    try
        f()
    catch err
        return err
    end
    error("no error was thrown")
end

# The loss-modelled interchanges of `sys`, as `PowerSystems.AreaInterchange` components.
_ld_modelled(sys) = [
    ic for ic in PowerSystems.get_components(PowerSystems.AreaInterchange, sys) if
        length(PowerSystems.get_supplemental_attributes(AustralianElectricityMarkets.InterconnectorLossModel, ic)) == 1
]

# Removes the `loss_demand_coefficient` series of every interchange of `sys`, so the writer can run again.
function _ld_strip!(sys)
    AEM = AustralianElectricityMarkets
    for ic in PowerSystems.get_components(PowerSystems.AreaInterchange, sys)
        PowerSystems.has_time_series(ic, PowerSystems.SingleTimeSeries, AEM.NEM_SERIES.loss_demand_coefficient) &&
            AEM.remove_single_series!(sys, ic, AEM.NEM_SERIES.loss_demand_coefficient)
    end
    return sys
end

# The expected coefficient of `ic`: each region's demand term times its summed available load in per-unit of the
# system base, read from the raw MW `loss_demand` series.
function _ld_expected(sys, model)
    n = _LD_N
    demand = Dict{String, Vector{Float64}}()
    PowerSystems.with_units_base(sys, "NATURAL_UNITS") do
        for load in PowerSystems.get_components(PowerSystems.get_available, PowerSystems.PowerLoad, sys)
            area = PowerSystems.get_name(PowerSystems.get_area(PowerSystems.get_bus(load)))
            total = get!(() -> zeros(n), demand, area)
            total .+= PowerSystems.get_time_series_values(PowerSystems.SingleTimeSeries, load, "loss_demand")
        end
    end
    base_power = PowerSystems.get_base_power(sys)
    return [
        sum(c * get(demand, r, zeros(n))[i] / base_power for (r, c) in model.demand_coefficients; init = 0.0) for i in 1:n
    ]
end

@testset "loss_demand_coefficient sums each named region's coefficient times its demand" begin
    AEM = AustralianElectricityMarkets
    model = AEM.InterconnectorLossModel(;
        interconnector = "IC1", from_region = "NSW1", to_region = "VIC1", from_region_loss_share = 0.5,
        loss_constant = 0.0, loss_flow_coefficient = 0.0,
        demand_coefficients = Dict("NSW1" => 0.5, "VIC1" => 1.5), breakpoints = [-100.0, 0.0, 100.0],
    )
    @test AEM.loss_demand_coefficient(model, Dict("NSW1" => 100.0, "VIC1" => 200.0)) == 350.0
    @test AEM.loss_demand_coefficient(model, Dict("NSW1" => 100.0)) == 50.0
    @test AEM.loss_demand_coefficient(model, Dict{String, Float64}()) == 0.0
end

@testset "the stage writes the coefficient series on each loss-modelled interchange only" begin
    AEM = AustralianElectricityMarkets
    sys = _ld_mock_system()
    modelled = _ld_modelled(sys)
    @test !isempty(modelled)
    for ic in PowerSystems.get_components(PowerSystems.AreaInterchange, sys)
        has = PowerSystems.has_time_series(ic, PowerSystems.SingleTimeSeries, AEM.NEM_SERIES.loss_demand_coefficient)
        @test has == (ic in modelled)
    end
end

@testset "the coefficient is the demand term per interval, on per-unit regional demand" begin
    AEM = AustralianElectricityMarkets
    sys = _ld_strip!(_ld_mock_system())
    AEM._set_loss_demand_coefficients!(sys)
    for ic in _ld_modelled(sys)
        model = only(PowerSystems.get_supplemental_attributes(AEM.InterconnectorLossModel, ic))
        coefficient = PowerSystems.get_time_series_values(PowerSystems.SingleTimeSeries, ic, AEM.NEM_SERIES.loss_demand_coefficient)
        @test coefficient ≈ _ld_expected(sys, model)
        @test any(!iszero, coefficient)
        @test PowerSystems.get_time_series_timestamps(PowerSystems.SingleTimeSeries, ic, AEM.NEM_SERIES.loss_demand_coefficient) ==
            PowerSystems.get_time_series_timestamps(PowerSystems.SingleTimeSeries, first(PowerSystems.get_components(PowerSystems.PowerLoad, sys)), "loss_demand")
    end
end

@testset "an unavailable load drops out of its region's demand, and a rerun after stripping gives the same series" begin
    AEM = AustralianElectricityMarkets
    sys = _ld_strip!(_ld_mock_system())
    AEM._set_loss_demand_coefficients!(sys)
    ic = first(_ld_modelled(sys))
    model = only(PowerSystems.get_supplemental_attributes(AEM.InterconnectorLossModel, ic))
    load = PowerSystems.get_component(PowerSystems.PowerLoad, sys, "VIC1 Load")
    PowerSystems.set_available!(load, false)
    _ld_strip!(sys)
    AEM._set_loss_demand_coefficients!(sys)
    coefficient = PowerSystems.get_time_series_values(PowerSystems.SingleTimeSeries, ic, AEM.NEM_SERIES.loss_demand_coefficient)
    @test coefficient ≈ _ld_expected(sys, model)
end

@testset "the writer writes nothing when no interchange carries an InterconnectorLossModel" begin
    AEM = AustralianElectricityMarkets
    sys = _ld_strip!(_ld_mock_system())
    for ic in _ld_modelled(sys)
        PowerSystems.remove_supplemental_attribute!(sys, ic, only(PowerSystems.get_supplemental_attributes(AEM.InterconnectorLossModel, ic)))
    end
    AEM._set_loss_demand_coefficients!(sys)
    for ic in PowerSystems.get_components(PowerSystems.AreaInterchange, sys)
        @test !PowerSystems.has_time_series(ic, PowerSystems.SingleTimeSeries, AEM.NEM_SERIES.loss_demand_coefficient)
    end
end

@testset "the writer rejects a system with no available load" begin
    AEM = AustralianElectricityMarkets
    sys = _ld_strip!(_ld_mock_system())
    foreach(l -> PowerSystems.set_available!(l, false), PowerSystems.get_components(PowerSystems.PowerLoad, sys))
    err = _ld_error(() -> AEM._set_loss_demand_coefficients!(sys))
    @test err isa ArgumentError
    @test occursin("no available PowerLoad", sprint(showerror, err))
end

@testset "the writer rejects a load on a bus with no area" begin
    AEM = AustralianElectricityMarkets
    sys = _ld_strip!(_ld_mock_system())
    load = PowerSystems.get_component(PowerSystems.PowerLoad, sys, "VIC1 Load")
    PowerSystems.set_area!(PowerSystems.get_bus(load), nothing)
    err = _ld_error(() -> AEM._set_loss_demand_coefficients!(sys))
    @test err isa ArgumentError
    @test occursin("on a bus with no area", sprint(showerror, err))
end

@testset "the writer rejects a load with no loss_demand series" begin
    AEM = AustralianElectricityMarkets
    sys = _ld_strip!(_ld_mock_system())
    load = PowerSystems.get_component(PowerSystems.PowerLoad, sys, "VIC1 Load")
    PowerSystems.remove_time_series!(sys, PowerSystems.SingleTimeSeries, load, "loss_demand")
    err = _ld_error(() -> AEM._set_loss_demand_coefficients!(sys))
    @test err isa ArgumentError
    @test occursin("no \"loss_demand\" series", sprint(showerror, err))
end

@testset "the writer rejects a load series off the common timestamps" begin
    AEM = AustralianElectricityMarkets
    sys = _ld_strip!(_ld_mock_system())
    load = PowerSystems.get_component(PowerSystems.PowerLoad, sys, "VIC1 Load")
    original = PowerSystems.get_time_series(PowerSystems.SingleTimeSeries, load, "loss_demand")
    stamps = PowerSystems.get_time_series_timestamps(PowerSystems.SingleTimeSeries, load, "loss_demand")
    values = PowerSystems.get_time_series_values(PowerSystems.SingleTimeSeries, load, "loss_demand")
    PowerSystems.remove_time_series!(sys, PowerSystems.SingleTimeSeries, load, "loss_demand")
    PowerSystems.add_time_series!(
        sys, load,
        AEM.single_series("loss_demand", first(stamps) + Minute(5), values, PowerSystems.get_resolution(original)),
    )
    err = _ld_error(() -> AEM._set_loss_demand_coefficients!(sys))
    @test err isa ArgumentError
    @test occursin("is not on the timestamps", sprint(showerror, err))
end
