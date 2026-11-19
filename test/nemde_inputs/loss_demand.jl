# The loss demand coefficient kernel and the `loss_demand_coefficient` series, written on the mock run
# System (AEMSim not loaded). Writer tests strip their own family's series and call the writer directly
# after editing the raw demand inputs.

const _LD_START = DateTime(2025, 1, 1, 0, 5)
const _LD_N = 4

# A NEM run System on the mock hive, with its NEMDE inputs written by `nem_system`.
const _LD_SYS = nemde_test_system()

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
            remove_series_and_forecast!(sys, ic, AEM.NEM_SERIES.loss_demand_coefficient)
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

@testset "the stage writes the demand term per interval on each loss-modelled interchange only" begin
    AEM = AustralianElectricityMarkets
    sys = _LD_SYS
    modelled = _ld_modelled(sys)
    @test !isempty(modelled)
    @test all(
        PowerSystems.has_time_series(ic, PowerSystems.SingleTimeSeries, AEM.NEM_SERIES.loss_demand_coefficient) == (ic in modelled)
            for ic in PowerSystems.get_components(PowerSystems.AreaInterchange, sys)
    )
    load_stamps = PowerSystems.get_time_series_timestamps(PowerSystems.SingleTimeSeries, first(PowerSystems.get_components(PowerSystems.PowerLoad, sys)), "loss_demand")
    @test all(modelled) do ic
        model = only(PowerSystems.get_supplemental_attributes(AEM.InterconnectorLossModel, ic))
        coefficient = PowerSystems.get_time_series_values(PowerSystems.SingleTimeSeries, ic, AEM.NEM_SERIES.loss_demand_coefficient)
        return coefficient ≈ _ld_expected(sys, model) && any(!iszero, coefficient) &&
            PowerSystems.get_time_series_timestamps(PowerSystems.SingleTimeSeries, ic, AEM.NEM_SERIES.loss_demand_coefficient) == load_stamps
    end
end

@testset "an unavailable VIC1 load changes the coefficient of an interchange that names VIC1" begin
    AEM = AustralianElectricityMarkets
    sys = deepcopy(_LD_SYS)
    ic = first(ic for ic in _ld_modelled(sys) if haskey(only(PowerSystems.get_supplemental_attributes(AEM.InterconnectorLossModel, ic)).demand_coefficients, "VIC1"))
    model = only(PowerSystems.get_supplemental_attributes(AEM.InterconnectorLossModel, ic))
    before = PowerSystems.get_time_series_values(PowerSystems.SingleTimeSeries, ic, AEM.NEM_SERIES.loss_demand_coefficient)
    PowerSystems.set_available!(PowerSystems.get_component(PowerSystems.PowerLoad, sys, "VIC1 Load"), false)
    _ld_strip!(sys)
    AEM._set_loss_demand_coefficients!(sys)
    coefficient = PowerSystems.get_time_series_values(PowerSystems.SingleTimeSeries, ic, AEM.NEM_SERIES.loss_demand_coefficient)
    @test !(coefficient ≈ before)
    @test coefficient ≈ _ld_expected(sys, model)
end

@testset "the coefficient is the same bit for bit whatever the System's units setting" begin
    AEM = AustralianElectricityMarkets
    sys = deepcopy(_LD_SYS)
    ics = _ld_modelled(sys)
    series = [PowerSystems.get_time_series_values(PowerSystems.SingleTimeSeries, ic, AEM.NEM_SERIES.loss_demand_coefficient) for ic in ics]
    _ld_strip!(sys)
    PowerSystems.with_units_base(sys, "NATURAL_UNITS") do
        AEM._set_loss_demand_coefficients!(sys)
    end
    natural = [PowerSystems.get_time_series_values(PowerSystems.SingleTimeSeries, ic, AEM.NEM_SERIES.loss_demand_coefficient) for ic in ics]
    @test natural == series
end

@testset "the writer writes nothing when no interchange carries an InterconnectorLossModel" begin
    AEM = AustralianElectricityMarkets
    sys = _ld_strip!(deepcopy(_LD_SYS))
    for ic in _ld_modelled(sys)
        PowerSystems.remove_supplemental_attribute!(sys, ic, only(PowerSystems.get_supplemental_attributes(AEM.InterconnectorLossModel, ic)))
    end
    AEM._set_loss_demand_coefficients!(sys)
    @test !any(
        PowerSystems.has_time_series(ic, PowerSystems.SingleTimeSeries, AEM.NEM_SERIES.loss_demand_coefficient)
            for ic in PowerSystems.get_components(PowerSystems.AreaInterchange, sys)
    )
end

# Moves the "loss_demand" series of `load` five minutes later, off the common timestamps.
function _ld_shift_series!(sys, load)
    original = PowerSystems.get_time_series(PowerSystems.SingleTimeSeries, load, "loss_demand")
    stamps = PowerSystems.get_time_series_timestamps(PowerSystems.SingleTimeSeries, load, "loss_demand")
    values = PowerSystems.get_time_series_values(PowerSystems.SingleTimeSeries, load, "loss_demand")
    remove_series_and_forecast!(sys, load, "loss_demand")
    PowerSystems.add_time_series!(
        sys, load, AustralianElectricityMarkets.single_series("loss_demand", first(stamps) + Minute(5), values, PowerSystems.get_resolution(original)),
    )
    return
end

@testset "the writer rejects $(message)" for (message, damage!) in (
        "no available PowerLoad" => (sys, _) -> foreach(l -> PowerSystems.set_available!(l, false), PowerSystems.get_components(PowerSystems.PowerLoad, sys)),
        "on a bus with no area" => (_, load) -> PowerSystems.set_area!(PowerSystems.get_bus(load), nothing),
        "no \"loss_demand\" series" => (sys, load) -> remove_series_and_forecast!(sys, load, "loss_demand"),
        "is not on the timestamps" => _ld_shift_series!,
    )
    sys = _ld_strip!(deepcopy(_LD_SYS))
    damage!(sys, PowerSystems.get_component(PowerSystems.PowerLoad, sys, "VIC1 Load"))
    err = (@test_throws ArgumentError AustralianElectricityMarkets._set_loss_demand_coefficients!(sys)).value
    @test occursin(message, sprint(showerror, err))
end
