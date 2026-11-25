using HiGHS
using PowerSimulations
import PowerSimulations as PSI
import PowerSystems as PSY

const FCAS_TOY_TOLERANCE = 1.0e-4
# TOY_START is in FY2024-25, Market Price Cap $17,500/MWh.
const FCAS_TOY_MPC = 17_500.0

"""
    add_toy_fcas!(sys, device, initial_timestamp, n, bid_type, trapezium_mw, bands_mw_price; decremental = false)

Attaches the flat trapezium, `MAXAVAIL` and offer curve bid series, as service bids, over `n` steps from `initial_timestamp`,
as [`add_toy_fcas_offer!`](@ref) does.
"""
function add_toy_fcas!(
        sys, device, initial_timestamp, n::Integer, bid_type::BidType,
        trapezium_mw::NTuple{5, Float64}, bands_mw_price::Vector{Tuple{Float64, Float64}};
        decremental::Bool = false, resolution = TOY_RESOLUTION,
    )
    stamps = [initial_timestamp + (i - 1) * resolution for i in 1:n]
    add_toy_fcas_offer!(sys, device, stamps, bid_type, fill(trapezium_mw, n), fill(bands_mw_price, n); decremental)
    return
end

"""
    add_toy_fcas_scaling!(sys, device, initial_timestamp, n, bid_type; agc_enablement_min = nothing,
        agc_enablement_max = nothing, agc_max_avail = nothing)

Attaches the regulation enablement of `bid_type` to the device's telemetry and the derived
`"fcas_agc_ramp_rate_<bid_type>"` series over `n` flat steps. `agc_max_avail` is the AGC ramping
capability in MW over one `resolution` interval. A `nothing` keyword leaves that input unattached.
"""
function add_toy_fcas_scaling!(
        sys, device, initial_timestamp, n::Integer, bid_type::BidType;
        agc_enablement_min::Union{Nothing, Float64} = nothing,
        agc_enablement_max::Union{Nothing, Float64} = nothing,
        agc_max_avail::Union{Nothing, Float64} = nothing,
        resolution = TOY_RESOLUTION,
    )
    base_power = PSY.get_base_power(sys)
    stamps = [initial_timestamp + (i - 1) * resolution for i in 1:n]
    if !isnothing(agc_enablement_min) || !isnothing(agc_enablement_max)
        enablement = fill((something(agc_enablement_min, NaN), something(agc_enablement_max, NaN)), n)
        field = bid_type == BidType.RAISEREG ? :raise_reg_enablement : :lower_reg_enablement
        set_toy_unit_field!(sys, device, stamps, field, enablement)
    end
    isnothing(agc_max_avail) && return
    PSY.add_time_series!(
        sys, device,
        PSY.SingleTimeSeries(;
            name = "fcas_agc_ramp_rate_$(string(bid_type))",
            data = PSY.TimeSeries.TimeArray(stamps, fill(agc_max_avail / (Dates.value(Minute(resolution)) / 60) / base_power, n)),
        ),
    )
    return
end

"Attaches the device's `agc_status` telemetry, `status` over `n` flat steps."
function add_toy_fcas_agc_status!(sys, device, initial_timestamp, n::Integer, status::Int; resolution = TOY_RESOLUTION)
    stamps = [initial_timestamp + (i - 1) * resolution for i in 1:n]
    set_toy_unit_field!(sys, device, stamps, :agc_status, fill(Float64(status), n))
    return
end

"Attaches the device's observed net `initial_mw` (per unit of the system base) over `n` flat steps."
function add_toy_storage_initial_mw!(sys, device, initial_timestamp, n::Integer, initial_mw::Float64; resolution = TOY_RESOLUTION)
    stamps = [initial_timestamp + (i - 1) * resolution for i in 1:n]
    set_toy_unit_field!(sys, device, stamps, :initial_mw, fill(initial_mw, n))
    return
end

"""
    _write_toy_battery_nemde_inputs!(sys, bat, stamps)

Attaches `bat`'s `NEMDispatch` requirements over `stamps`: cheap generation and worthless load
energy offers, generous ramp rates and a zero net `initial_mw`. None of them bind in these tests,
which fix the energy variables directly.
"""
function _write_toy_battery_nemde_inputs!(sys, bat, stamps)
    base_power = PSY.get_base_power(sys)
    rating = PSY.get_output_active_power_limits(bat).max
    for (direction, price, mw) in (
            (AustralianElectricityMarkets.BidDirection.GEN, 1.0, rating),
            (AustralianElectricityMarkets.BidDirection.LOAD, 0.0, PSY.get_input_active_power_limits(bat).max),
        )
        _toy_energy_bid!(sys, bat, direction, stamps, fill(PSY.PiecewiseStepData([0.0, rating], [price]), length(stamps)), fill(mw, length(stamps)))
    end
    for (name, price) in (("energy_offer", 1.0), ("energy_offer_decremental", 0.0))
        curves = fill(PSY.PiecewiseStepData([0.0, rating], [price]), length(stamps))
        AustralianElectricityMarkets.replace_single_series!(
            sys, bat, AustralianElectricityMarkets.single_series(name, stamps[1], curves, TOY_RESOLUTION),
        )
    end
    _toy_set_band_prices!(bat)
    for name in ("ramp_up_rate", "ramp_down_rate")
        PSY.add_time_series!(
            sys, bat, PSY.SingleTimeSeries(; name = name, data = PSY.TimeSeries.TimeArray(stamps, fill(1.0e4 / base_power, length(stamps)))),
        )
    end
    set_toy_unit_field!(sys, bat, stamps, :initial_mw, fill(0.0, length(stamps)))
    set_toy_unit_field!(sys, bat, stamps, :ramp_up_limit, fill(1.0e4 * 60, length(stamps)))
    set_toy_unit_field!(sys, bat, stamps, :ramp_down_limit, fill(1.0e4 * 60, length(stamps)))
    return
end

"`NEMDispatch`/`StaticPowerLoad` for the toy's devices, plus [`FCASMarket`](@ref) for each named [`FCASService`](@ref)."
function fcas_toy_template(sys, service_names; use_slacks = false, duals = [FCASJointCapacityConstraint])
    template = PSI.ProblemTemplate(PSI.NetworkModel(PSI.AreaBalancePowerModel; use_slacks = true))
    set_nem_dispatch_models!(template, sys)
    PSI.set_device_model!(template, PSY.PowerLoad, PSI.StaticPowerLoad)
    for name in service_names
        PSI.set_service_model!(template, name, PSI.ServiceModel(FCASService, FCASMarket, name; duals, use_slacks))
    end
    return template
end

"A one-unit toy `System` whose sole `ThermalStandard` can be fixed to `energy_mw`."
function fcas_energy_toy_system(energy_mw; mutate! = nothing)
    return nem_toy_system(
        [
            TOY_CHEAP => toy_unit(
                100.0, [(100.0, 20.0)]; initial = energy_mw, ramp_up = 100.0, ramp_down = 100.0,
                availability = max(energy_mw, 1.0),
            ),
        ],
        energy_mw;
        mutate! = mutate!,
    )
end

"""
    fcas_offer_sys(energy_mw, offers; decremental = false, extra! = nothing)

A [`fcas_energy_toy_system`](@ref) whose unit bids each `(bid_type, trapezium_mw, bands)` of
`offers` into its own service `"TAS1_<bid_type>"`. `extra!(sys, device, stamps)` runs last.
"""
function fcas_offer_sys(energy_mw, offers; decremental = false, extra! = nothing)
    return fcas_energy_toy_system(
        energy_mw;
        mutate! = (sys, stamps) -> begin
            device = PSY.get_component(ThermalStandard, sys, TOY_CHEAP)
            for (bid_type, trapezium_mw, bands) in offers
                add_toy_fcas!(sys, device, stamps[1], length(stamps), bid_type, trapezium_mw, bands; decremental)
                PSY.add_service!(
                    sys, FCASService(; name = "TAS1_$(string(bid_type))", region = "TAS1", bid_type = bid_type), [device],
                )
            end
            isnothing(extra!) || extra!(sys, device, stamps)
        end,
    )
end

"Builds a `steps`-interval `PSI.DecisionModel` for `sys`/`service_names` and returns its `PSI.OptimizationContainer`."
function build_fcas(sys, service_names; steps = 1, use_slacks = false)
    model = PSI.DecisionModel(
        fcas_toy_template(sys, service_names; use_slacks), sys;
        optimizer = optimizer_with_attributes(HiGHS.Optimizer, "output_flag" => false),
        horizon = steps * TOY_RESOLUTION, resolution = TOY_RESOLUTION, interval = TOY_RESOLUTION,
        initial_time = TOY_START, name = "fcas_toy", store_variable_names = true,
    )
    @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
    return PSI.get_optimization_container(model)
end

"Runs `PSI.build_impl!` on a one-interval model of `sys`/`service_names` and returns the error it throws, or `nothing`."
function fcas_build_error(sys, service_names; recurrent = false)
    model = PSI.DecisionModel(
        fcas_toy_template(sys, service_names), sys; optimizer = HiGHS.Optimizer, horizon = TOY_RESOLUTION,
        resolution = TOY_RESOLUTION, interval = TOY_RESOLUTION, initial_time = TOY_START,
    )
    PSI.set_output_dir!(model, mktempdir())
    PSI.get_optimization_container(model).built_for_recurrent_solves = recurrent
    return _caught(() -> PSI.build_impl!(model))
end

"Fixes `duid`'s `ActivePowerVariable` at `energy_mw`, so FCAS reward can't shift energy off it."
function fix_energy!(container, duid, energy_mw; device_type = ThermalStandard)
    var = PSI.get_variable(container, PSI.ActivePowerVariable(), device_type)
    PSI.JuMP.fix(var[duid, 1], energy_mw / PSI.get_base_power(container); force = true)
    return
end

"Fixes BAT1's `ActivePowerOutVariable`/`ActivePowerInVariable` at `out_mw`/`in_mw`."
function fix_storage!(container, out_mw, in_mw)
    base_power = PSI.get_base_power(container)
    for (var_type, mw) in ((PSI.ActivePowerOutVariable(), out_mw), (PSI.ActivePowerInVariable(), in_mw))
        PSI.JuMP.fix(PSI.get_variable(container, var_type, EnergyReservoirStorage)["BAT1", 1], mw / base_power; force = true)
    end
    return
end

"Maximises `reward_fn(container)` (added to the objective with a large negative weight) and solves."
function maximize_and_solve!(reward_fn, container)
    jm = PSI.get_jump_model(container)
    PSI.JuMP.set_objective_function(jm, PSI.JuMP.objective_function(jm) - 1.0e6 * reward_fn(container))
    PSI.JuMP.optimize!(jm)
    @test PSI.JuMP.termination_status(jm) == PSI.MOI.OPTIMAL
    return
end

"Solves `container` as built and returns its JuMP model."
function solve_container!(container)
    jm = PSI.get_jump_model(container)
    PSI.JuMP.optimize!(jm)
    @test PSI.JuMP.termination_status(jm) == PSI.MOI.OPTIMAL
    return jm
end

fcas_capacity(container, service_name) =
    PSI.get_variable(container, FCASCapacityVariable(), FCASService, service_name)

fcas_mw(container, service_name, duid) =
    PSI.JuMP.value(fcas_capacity(container, service_name)[duid, 1]) * PSI.get_base_power(container)

fcas_side_capacity(container, service_name, side::Symbol) =
    PSI.get_variable(container, FCASSideCapacityVariable(), FCASService, "$(service_name)_$side")

fcas_side_mw(container, service_name, side::Symbol, duid) =
    PSI.JuMP.value(fcas_side_capacity(container, service_name, side)[duid, 1]) * PSI.get_base_power(container)

fcas_unit_target(container, service_name) =
    PSI.get_expression(container, FCASUnitRegulationTarget(), FCASService, service_name)

fcas_unit_mw(container, service_name, duid) =
    PSI.JuMP.value(fcas_unit_target(container, service_name)[duid, 1]) * PSI.get_base_power(container)

"Maximises `duid`'s `service_name` capacity and returns it in MW."
function max_fcas_mw(container, service_name, duid)
    maximize_and_solve!(c -> fcas_capacity(c, service_name)[duid, 1], container)
    return fcas_mw(container, service_name, duid)
end

joint_row(container, meta, duid) = PSI.JuMP.constraint_object(
    PSI.get_constraint(container, FCASJointCapacityConstraint(), FCASService, meta)[duid, 1],
)

unit_row(container, meta, duid) = PSI.JuMP.constraint_object(
    PSI.get_constraint(container, FCASUnitConstraint(), FCASService, meta)[duid, 1],
)

bat_var(container, var_type) = PSI.get_variable(container, var_type(), EnergyReservoirStorage)["BAT1", 1]

fcas_slack(container, meta, duid) = PSI.get_variable(container, FCASSlack(), FCASService, meta)[duid, 1]

"The objective coefficient of a slack priced at `cvp_factor` x MPC."
cvp_cost(container, cvp_factor) =
    PSI.get_base_power(container) * interval_cost_coefficient(cvp_factor * FCAS_TOY_MPC, TOY_RESOLUTION)

slack_cost(container, slack) = PSI.JuMP.objective_function(PSI.get_jump_model(container)).terms[slack]

"Coefficient of `band` of `duid`'s `service_name` offer in the invariant objective."
function band_coefficient(container, service_name, duid, band)
    bands = PSI.get_variable(container, FCASOfferBandVariable(), FCASService, service_name)
    invariant = PSI.get_invariant_terms(PSI.get_objective_expression(container))
    return PSI.JuMP.coefficient(invariant, bands[duid, string(band), 1]) /
        (PSI.get_base_power(container) * interval_hours(PSI.get_resolution(container)))
end

@testset "FCASMarket reproduces the published Tungatinah/TAS1 numbers" begin
    # BIDPEROFFER_D trapeziums for DUID TUNGATIN, 2025-01-13 16:30, one row per market.
    duid = TOY_CHEAP
    trapeziums_mw = Dict(
        BidType.LOWER6SEC => (1.0, 5.0, 26.0, 27.0, 4.0),
        BidType.RAISE6SEC => (1.0, 1.0, 11.0, 27.0, 9.0),
        BidType.RAISE60SEC => (1.0, 1.0, 6.0, 27.0, 21.0),
        BidType.RAISE5MIN => (1.0, 2.0, 2.0, 26.0, 26.0),
        BidType.RAISEREG => (1.0, 1.0, 1.0, 26.0, 25.0),
    )
    sys = fcas_offer_sys(2.0, [(bt, trap, [(trap[5], 10.0)]) for (bt, trap) in trapeziums_mw])
    service_names = ["TAS1_$(string(bt))" for bt in keys(trapeziums_mw)]
    container = build_fcas(sys, service_names)
    @test PSY.get_base_power(sys) != 1.0
    fix_energy!(container, duid, 2.0)
    # No AGC ramp rate is attached, so fix RAISEREG at the published target.
    PSI.JuMP.fix(fcas_capacity(container, "TAS1_RAISEREG")[duid, 1], 9.0 / PSY.get_base_power(sys); force = true)
    maximize_and_solve!(container) do container
        sum(fcas_capacity(container, name)[duid, 1] for name in service_names)
    end
    @test fcas_mw(container, "TAS1_LOWER6SEC", duid) ≈ 1.0 atol = FCAS_TOY_TOLERANCE
    @test fcas_mw(container, "TAS1_RAISE6SEC", duid) ≈ 9.0 atol = FCAS_TOY_TOLERANCE
    @test fcas_mw(container, "TAS1_RAISE60SEC", duid) ≈ 16.0 atol = FCAS_TOY_TOLERANCE
    @test fcas_mw(container, "TAS1_RAISE5MIN", duid) ≈ 16.25 atol = FCAS_TOY_TOLERANCE
end

@testset "regulation trapezium scaling (§4) changes the solved cap" begin
    raisereg_cap(trapezium_mw, energy_mw; scaling...) = begin
        sys = fcas_offer_sys(
            energy_mw, [(BidType.RAISEREG, trapezium_mw, [(25.0, 10.0)])];
            extra! = (sys, device, stamps) -> isempty(scaling) ||
                add_toy_fcas_scaling!(sys, device, stamps[1], length(stamps), BidType.RAISEREG; scaling...),
        )
        container = build_fcas(sys, ["TAS1_RAISEREG"])
        fix_energy!(container, TOY_CHEAP, energy_mw)
        max_fcas_mw(container, "TAS1_RAISEREG", TOY_CHEAP)
    end
    # A flat trapezium: only MaxAvail (25), or a more restrictive AGC ramping capability, binds.
    flat = (0.0, 0.0, 100.0, 100.0, 25.0)
    @test raisereg_cap(flat, 2.0) ≈ 25.0 atol = FCAS_TOY_TOLERANCE
    @test raisereg_cap(flat, 2.0; agc_max_avail = 15.0) ≈ 15.0 atol = FCAS_TOY_TOLERANCE
    @test raisereg_cap(flat, 2.0; agc_max_avail = 40.0) ≈ 25.0 atol = FCAS_TOY_TOLERANCE
    # Upper slope 0.4; AGC EnablementMax 50 slides HighBreakpoint to 40, so at 45 MW R <= (50 - 45) / 0.4.
    sloped = (0.0, 0.0, 90.0, 100.0, 25.0)
    @test raisereg_cap(sloped, 45.0) ≈ 25.0 atol = FCAS_TOY_TOLERANCE
    @test raisereg_cap(sloped, 45.0; agc_enablement_max = 50.0) ≈ 12.5 atol = FCAS_TOY_TOLERANCE
    # An inverted AGC window leaves EnablementMax < EnablementMin: §5 disables the bid.
    @test raisereg_cap(sloped, 45.0; agc_enablement_min = 60.0, agc_enablement_max = 40.0) ≈ 0.0 atol = FCAS_TOY_TOLERANCE
end

@testset "the LOWER6SEC trapezium caps the capacity at every energy level of its enablement span" begin
    # (1, 5, 26, 27, 4): energy - 1.0 L >= EnablementMin 1, energy + 0.25 L <= EnablementMax 27, L <= MaxAvail 4.
    container = build_fcas(fcas_offer_sys(26.5, [(BidType.LOWER6SEC, (1.0, 5.0, 26.0, 27.0, 4.0), [(4.0, 10.0)])]), ["TAS1_LOWER6SEC"])
    for energy_mw in (1.0, 2.0, 3.5, 5.0, 5.5, 15.0, 26.0, 26.5)
        fix_energy!(container, TOY_CHEAP, energy_mw)
        @test max_fcas_mw(container, "TAS1_LOWER6SEC", TOY_CHEAP) ≈ min(4.0, energy_mw - 1.0, (27.0 - energy_mw) / 0.25) atol = FCAS_TOY_TOLERANCE
    end
end

@testset "regulation terms enter the contingency joint rows" begin
    # RAISEREG enters each contingency's upper form, LOWERREG its lower form.
    flat = (0.0, 10.0, 90.0, 100.0, 10.0)
    offers = [(bt, flat, [(10.0, 10.0)]) for bt in (BidType.LOWER6SEC, BidType.RAISE6SEC, BidType.RAISEREG, BidType.LOWERREG)]
    container = build_fcas(fcas_offer_sys(50.0, offers), ["TAS1_$(string(o[1]))" for o in offers])
    raise_reg = fcas_capacity(container, "TAS1_RAISEREG")[TOY_CHEAP, 1]
    lower_reg = fcas_capacity(container, "TAS1_LOWERREG")[TOY_CHEAP, 1]
    for service in ("TAS1_LOWER6SEC", "TAS1_RAISE6SEC")
        upper = joint_row(container, "$(service)_upper", TOY_CHEAP).func.terms
        lower = joint_row(container, "$(service)_lower", TOY_CHEAP).func.terms
        @test upper[raise_reg] == 1.0 && !haskey(upper, lower_reg)
        @test lower[lower_reg] == -1.0 && !haskey(lower, raise_reg)
    end
end

@testset "a malformed offered trapezium is rejected before the build" begin
    # HighBreakpoint (110) above EnablementMax (100).
    err = _caught(() -> fcas_offer_sys(2.0, [(BidType.RAISE6SEC, (0.0, 0.0, 110.0, 100.0, 10.0), [(10.0, 10.0)])]))
    @test err isa ArgumentError
    @test occursin("Malformed FCAS trapezium", err.msg)
end

@testset "offer cost equals the hand-worked band cost" begin
    # HighBreakpoint == EnablementMax: only the band cost and the 10 MW MaxAvail are in play.
    sys = fcas_offer_sys(2.0, [(BidType.RAISE6SEC, (0.0, 0.0, 100.0, 100.0, 10.0), [(2.0, 10.0), (2.0, 30.0)])])
    base_power = PSY.get_base_power(sys)
    function objective_at(capacity_mw)
        container = build_fcas(sys, ["TAS1_RAISE6SEC"])
        fix_energy!(container, TOY_CHEAP, 2.0)
        PSI.JuMP.fix(fcas_capacity(container, "TAS1_RAISE6SEC")[TOY_CHEAP, 1], capacity_mw / base_power; force = true)
        return PSI.JuMP.objective_value(solve_container!(container))
    end
    o0, o2, o3 = objective_at.((0.0, 2.0, 3.0))
    @test (o2 - o0) ≈ interval_cost_coefficient(10.0) * 2.0 atol = FCAS_TOY_TOLERANCE
    @test (o3 - o2) ≈ interval_cost_coefficient(30.0) * 1.0 atol = FCAS_TOY_TOLERANCE
end

@testset "a GEN and a BIDIRECTIONAL bid on one side are priced from their own curves" begin
    service_name = "TOY_RAISE6SEC_MIX"
    sys = nem_toy_system(
        [TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = 2.0, ramp_up = 100.0, ramp_down = 100.0, availability = 2.0)],
        2.0;
        batteries = [TOY_BATTERY => toy_battery(50.0, 30.0, 50.0, 0.0; initial = 0.0, ramp_up = 100.0)],
        mutate! = (sys, stamps) -> begin
            alta = PSY.get_component(ThermalStandard, sys, TOY_CHEAP)
            batt = PSY.get_component(EnergyReservoirStorage, sys, TOY_BATTERY)
            add_toy_fcas_offer!(
                sys, alta, stamps, BidType.RAISE6SEC,
                fill((0.0, 0.0, 100.0, 100.0, 10.0), 2), fill([(2.0, 10.0), (2.0, 30.0)], 2),
            )
            add_toy_fcas_offer!(
                sys, batt, stamps, BidType.RAISE6SEC, fill((0.0, 0.0, 50.0, 50.0, 10.0), 2), fill([(10.0, 15.0)], 2);
                direction = AustralianElectricityMarkets.BidDirection.BIDIRECTIONAL,
            )
            PSY.add_service!(sys, FCASService(; name = service_name, region = "TAS1", bid_type = BidType.RAISE6SEC), [alta, batt])
            return
        end,
    )
    container = build_fcas(sys, [service_name])
    @test band_coefficient(container, service_name, TOY_CHEAP, 2) ≈ 30.0
    @test band_coefficient(container, service_name, TOY_BATTERY, 1) ≈ 15.0
end

"Attaches a flat `max_active_power` of 1 p.u. over `stamps` to every load and `RenewableDispatch` in `sys`."
function _add_flat_max_active_power!(sys, stamps)
    for comp in Iterators.flatten((get_components(PowerLoad, sys), get_components(RenewableDispatch, sys)))
        PSY.add_time_series!(
            sys, comp,
            PSY.SingleTimeSeries(;
                name = "max_active_power", data = PSY.TimeSeries.TimeArray(stamps, fill(1.0, length(stamps))),
                scaling_factor_multiplier = PSY.get_max_active_power,
            ),
        )
    end
    return
end

"""
    battery_fcas_model(service_name, bids; initial_mw = nothing, energy_max_avail_mw = nothing,
        scaling = nothing, agc_status = nothing, use_slacks = false, requirement_mw = nothing)

Builds the toy PSCB `DecisionModel` with BAT1, under `NEMDispatch`, as the only contributor to
one `service_name` [`FCASService`](@ref). Each `(bid_type, trapezium_mw, bands, decremental)` of
`bids` is one side's offer. `energy_max_avail_mw = (gen, load)` is BAT1's energy `MAXAVAIL`,
`initial_mw` its net `INITIALMW`, `scaling` keywords for [`add_toy_fcas_scaling!`](@ref).
`requirement_mw` adds a `GE` generic constraint `"F_BDU"` on BAT1's target.

# Returns
`(model, sys)`, with `model` built.
"""
function battery_fcas_model(
        service_name, bids; initial_mw = nothing, energy_max_avail_mw = nothing, scaling = nothing,
        agc_status = nothing, use_slacks = false, requirement_mw = nothing,
    )
    sys = augmented_pscb_system()
    _fix_thermal_floor!(sys)
    bat = get_component(EnergyReservoirStorage, sys, "BAT1")
    AustralianElectricityMarkets.attach_nem_unit_data!(sys, bat)
    # Every forecast in a System shares one window count and horizon, so rebuild them to match the FCAS window.
    PSY.clear_time_series!(sys)
    stamps = [TOY_START, TOY_START + TOY_RESOLUTION]
    n = length(stamps)
    bid_type = first(first(bids))
    _add_flat_max_active_power!(sys, stamps)
    for (bt, trapezium_mw, bands, decremental) in bids
        add_toy_fcas!(sys, bat, stamps[1], n, bt, trapezium_mw, bands; decremental)
    end
    isnothing(agc_status) || add_toy_fcas_agc_status!(sys, bat, stamps[1], n, agc_status)
    _write_toy_battery_nemde_inputs!(sys, bat, stamps)
    isnothing(initial_mw) || add_toy_storage_initial_mw!(sys, bat, stamps[1], n, initial_mw)
    isnothing(scaling) || add_toy_fcas_scaling!(sys, bat, stamps[1], n, bid_type; scaling...)
    if !isnothing(energy_max_avail_mw)
        for (direction, mw) in zip((AustralianElectricityMarkets.BidDirection.GEN, AustralianElectricityMarkets.BidDirection.LOAD), energy_max_avail_mw)
            replace_single_series_with!(
                sys, bat, AustralianElectricityMarkets.bid_series_name(BidType.ENERGY, :max_avail, direction), fill(mw, n), stamps,
            )
        end
    end
    # The clear above drops the observed-state series the NEMDE stage wrote, which the model reads.
    AustralianElectricityMarkets._set_observed_state_inputs!(sys)
    add_service!(sys, FCASService(; name = service_name, region = "TAS1", bid_type = bid_type), [bat])
    if !isnothing(requirement_mw)
        gc = GenericConstraint(;
            name = "F_BDU", sense = ConstraintSense.GE, rhs = requirement_mw,
            terms = ConstraintTerm[UnitTerm("BAT1", bid_type, 1.0)],
            fcas_requirements = [FCASRequirement("TAS1", bid_type)],
        )
        add_service!(sys, gc, [bat])
        add_toy_constraint_series!(sys, gc, stamps, fill(requirement_mw, n), fill(1.0, n))
    end
    AustralianElectricityMarkets._set_fcas_effective_offers!(sys)
    PSY.transform_single_time_series!(sys, 2 * TOY_RESOLUTION, TOY_RESOLUTION)

    template = _area_balance_template(sys)
    PSI.set_device_model!(template, EnergyReservoirStorage, NEMDispatch)
    PSI.set_service_model!(
        template, service_name,
        PSI.ServiceModel(FCASService, FCASMarket, service_name; duals = [FCASJointCapacityConstraint], use_slacks),
    )
    isnothing(requirement_mw) || PSI.set_service_model!(
        template, "F_BDU", PSI.ServiceModel(GenericConstraint, LinearFactorLimit, "F_BDU"; duals = [NEMConstraintLimit]),
    )
    model = _decision_model(
        template, sys; mpc = FCAS_TOY_MPC,
        optimizer = optimizer_with_attributes(HiGHS.Optimizer, "output_flag" => false),
        horizon = TOY_RESOLUTION, resolution = TOY_RESOLUTION, interval = TOY_RESOLUTION, initial_time = TOY_START,
    )
    @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
    return model, sys
end

"`battery_fcas_model` for a single-sided BAT1 bid `(bid_type, trapezium_mw)` with one 10 MW band at 50."
storage_fcas_toy_model(service_name, bid_type, trapezium_mw; decremental = false, initial_mw = 0.0, kwargs...) =
    battery_fcas_model(service_name, [(bid_type, trapezium_mw, [(10.0, 50.0)], decremental)]; initial_mw, kwargs...)

"""
    _build_bdu_regulation(service_name, out_mw, in_mw; load_max_avail = 10.0, band_mw = 10.0, solve = true, kwargs...)

BAT1 bidding RAISEREG on both sides, generation `(0, 5, 20, 25, 10)` at 15 and load
`(-25, -20, -5, 0, load_max_avail)` at 12, with its energy fixed at `out_mw`/`in_mw` and its total
RAISEREG target maximised. Returns the solved container, or the built model with `solve = false`.
"""
function _build_bdu_regulation(service_name, out_mw, in_mw; load_max_avail = 10.0, band_mw = 10.0, solve = true, kwargs...)
    bids = [
        (BidType.RAISEREG, (0.0, 5.0, 20.0, 25.0, 10.0), [(band_mw, 15.0)], false),
        (BidType.RAISEREG, (-25.0, -20.0, -5.0, 0.0, load_max_avail), [(band_mw, 12.0)], true),
    ]
    model, _ = battery_fcas_model(service_name, bids; kwargs...)
    solve || return model
    container = PSI.get_optimization_container(model)
    fix_storage!(container, out_mw, in_mw)
    maximize_and_solve!(c -> fcas_unit_target(c, service_name)["BAT1", 1], container)
    return container
end

"Fixes BAT1 at `out_mw`/`in_mw`, maximises its `service_name` capacity and returns it in MW."
function max_storage_fcas_mw(model, service_name, out_mw, in_mw)
    container = PSI.get_optimization_container(model)
    fix_storage!(container, out_mw, in_mw)
    return max_fcas_mw(container, service_name, "BAT1")
end

@testset "a Storage device's FCAS reads its own side's energy" begin
    # Contingency on the net-MW axis: LowerSlopeCoeff 1.0, so LOWER6SEC <= -6 - (-8) = 2 MW while charging 6 MW.
    model, _ = storage_fcas_toy_model("S", BidType.LOWER6SEC, (-8.0, 2.0, 5.0, 20.0, 10.0))
    @test max_storage_fcas_mw(model, "S", 0.0, 6.0) ≈ 2.0 atol = FCAS_TOY_TOLERANCE
    # GEN-side RAISEREG while charging reads generation 0, so its lower form 0 - 1.0 R >= 0 gives R = 0.
    model, _ = storage_fcas_toy_model("S", BidType.RAISEREG, (0.0, 10.0, 15.0, 20.0, 10.0))
    @test max_storage_fcas_mw(model, "S", 0.0, 6.0) ≈ 0.0 atol = FCAS_TOY_TOLERANCE
    # A vertical lower slope offers the full MaxAvail at zero generation, unless stranded from a charging InitialMW.
    for (initial_mw, expected) in ((0.0, 10.0), (-6.0, 0.0))
        model, _ = storage_fcas_toy_model("S", BidType.RAISEREG, (0.0, 0.0, 15.0, 20.0, 10.0); initial_mw)
        @test max_storage_fcas_mw(model, "S", 0.0, 6.0) ≈ expected atol = FCAS_TOY_TOLERANCE
    end
end

@testset "a Storage device's LOAD-side regulation" begin
    trapezium = (-20.0, -15.0, -5.0, 0.0, 10.0)
    model, sys = storage_fcas_toy_model("S", BidType.LOWERREG, trapezium; decremental = true)
    container = PSI.get_optimization_container(model)
    for side in ("upper", "lower")
        terms = joint_row(container, "S_$side", "BAT1").func.terms
        @test terms[bat_var(container, PSI.ActivePowerInVariable)] == -1.0
        @test !haskey(terms, bat_var(container, PSI.ActivePowerOutVariable))
    end
    # The load bid's price is the band cost.
    @test band_coefficient(container, "S", "BAT1", 1) ≈ 50.0

    # Both slope coefficients 0.5; AGC EnablementMin -10 and a 4 MW AGC capability give (-10, -8, -2, 0, 4).
    model, sys = storage_fcas_toy_model(
        "S", BidType.LOWERREG, trapezium; decremental = true, scaling = (; agc_enablement_min = -10.0, agc_max_avail = 4.0),
    )
    bat = get_component(EnergyReservoirStorage, sys, "BAT1")
    window = AustralianElectricityMarkets._fcas_window(bat, [TOY_START], TOY_RESOLUTION, get_base_power(sys))
    market = AustralianElectricityMarkets._fcas_market(window, bat, BidType.LOWERREG, fcas_bid_direction(bat, BidType.LOWERREG); offer_curves = false)
    trap = AustralianElectricityMarkets._fcas_scaled_trapezium(market, market.load, 1)
    @test collect(Tuple(trap)[1:5]) .* get_base_power(sys) ≈ [-10.0, -8.0, -2.0, 0.0, 4.0]
end

@testset "FCASMarket disables a Storage FCAS bid its energy bid availability can't reach" begin
    capacity_bound(gen_mw) = begin
        model, _ = storage_fcas_toy_model(
            "S", BidType.RAISE6SEC, (2.0, 4.0, 15.0, 20.0, 10.0); energy_max_avail_mw = (gen_mw, 50.0), initial_mw = 3.0,
        )
        PSI.JuMP.upper_bound(fcas_capacity(PSI.get_optimization_container(model), "S")["BAT1", 1])
    end
    # EnablementMin = 2 MW: a 1 MW energy bid can't reach the trapezium, a 5 MW one can.
    @test capacity_bound(1.0) == 0.0
    @test capacity_bound(5.0) > 0.0
end

@testset "a Storage device's per-side regulation FCAS (§6.2/§6.3/§6.4/§5)" begin
    unit_mw(c) = fcas_unit_mw(c, "BDU", "BAT1")
    # Discharging: the generation side's upper slope 0.5 gives 22 + 0.5 R <= 25, R <= 6; the load side reads 0.
    container = _build_bdu_regulation("BDU", 22.0, 0.0)
    @test fcas_side_mw(container, "BDU", :gen, "BAT1") ≈ 6.0 atol = FCAS_TOY_TOLERANCE
    @test fcas_side_mw(container, "BDU", :load, "BAT1") ≈ 0.0 atol = FCAS_TOY_TOLERANCE
    @test unit_mw(container) ≈ 6.0 atol = FCAS_TOY_TOLERANCE
    # Charging: the load side's lower slope 0.5 gives -22 - 0.5 R >= -25, R <= 6; the generation side reads 0.
    container = _build_bdu_regulation("BDU", 0.0, 22.0)
    @test fcas_side_mw(container, "BDU", :load, "BAT1") ≈ 6.0 atol = FCAS_TOY_TOLERANCE
    @test fcas_side_mw(container, "BDU", :gen, "BAT1") ≈ 0.0 atol = FCAS_TOY_TOLERANCE
    # §6.4: at 15/15 MW each side is bounded only by its 10 MW MaxAvail; a 12 MW SCADA ramp caps the unit
    # total, and a zero ramp rate imposes no cap.
    @test unit_mw(_build_bdu_regulation("BDU", 15.0, 15.0; scaling = (; agc_max_avail = 12.0))) ≈ 12.0 atol = FCAS_TOY_TOLERANCE
    @test unit_mw(_build_bdu_regulation("BDU", 15.0, 15.0; scaling = (; agc_max_avail = 0.0))) ≈ 20.0 atol = FCAS_TOY_TOLERANCE
    # §5: AGC status 0, a net InitialMW outside [EnablementMin_LOAD, EnablementMax_GEN], or an AGC window
    # above both sides' spans disables regulation on both sides.
    @test unit_mw(_build_bdu_regulation("BDU", 22.0, 0.0; agc_status = 0)) ≈ 0.0 atol = FCAS_TOY_TOLERANCE
    @test unit_mw(_build_bdu_regulation("BDU", 22.0, 0.0; initial_mw = -30.0)) ≈ 0.0 atol = FCAS_TOY_TOLERANCE
    @test unit_mw(
        _build_bdu_regulation("BDU", 0.0, 22.0; scaling = (; agc_enablement_min = 368.39502, agc_enablement_max = 0.0)),
    ) ≈ 0.0 atol = FCAS_TOY_TOLERANCE
    # With the load side at MaxAvail 0, only the generation side's own [0, 25] window strands it.
    @test unit_mw(_build_bdu_regulation("BDU", 22.0, 0.0; load_max_avail = 0.0, initial_mw = -10.0)) ≈ 0.0 atol = FCAS_TOY_TOLERANCE
    @test unit_mw(_build_bdu_regulation("BDU", 22.0, 0.0; load_max_avail = 0.0, initial_mw = 10.0)) ≈ 6.0 atol = FCAS_TOY_TOLERANCE
end

@testset "§5 enablement pre-conditions on a generator" begin
    trapezium = (5.0, 10.0, 90.0, 100.0, 10.0)
    bands = [(10.0, 10.0)]
    # Each `(name, initial, availability, trapezium_mw, bands)` unit bids RAISE6SEC; AGC status 0 on TOY_CHEAP.
    function capacity_bounds(units; steps = 1)
        sys = nem_toy_system(
            [
                name => toy_unit(100.0, [(100.0, 20.0)]; initial, ramp_up = 1.0e4, ramp_down = 1.0e4, availability)
                    for (name, initial, availability) in units
            ],
            sum(u[2] for u in units);
            mutate! = (sys, stamps) -> begin
                devices = [PSY.get_component(ThermalStandard, sys, u[1]) for u in units]
                for (device, (_, _, _, trap, bnds)) in zip(devices, units)
                    add_toy_fcas!(sys, device, stamps[1], length(stamps), BidType.RAISE6SEC, trap, bnds)
                end
                add_toy_fcas_agc_status!(sys, devices[1], stamps[1], length(stamps), 0)
                PSY.add_service!(sys, FCASService(; name = "TAS1_RAISE6SEC", region = "TAS1", bid_type = BidType.RAISE6SEC), devices)
            end,
        )
        container = build_fcas(sys, ["TAS1_RAISE6SEC"]; steps)
        var = fcas_capacity(container, "TAS1_RAISE6SEC")
        bounds = Dict(u[1] => [PSI.JuMP.upper_bound(var[u[1], t]) * PSI.get_base_power(container) for t in 1:steps] for u in units)
        return bounds, container
    end
    capacity_bound_mw(trap, bnds; initial = 20.0, availability = 100.0) =
        capacity_bounds([(TOY_CHEAP, initial, availability, trap, bnds)])

    # Two units over two intervals are gated independently: TOY_EXPENSIVE starts stranded below
    # EnablementMin, while AGC status 0 leaves TOY_CHEAP's contingency enabled.
    bounds, _ = capacity_bounds([(TOY_CHEAP, 20.0, 100.0, trapezium, bands), (TOY_EXPENSIVE, 2.0, 100.0, trapezium, bands)]; steps = 2)
    @test bounds[TOY_CHEAP] ≈ [10.0, 10.0]
    @test bounds[TOY_EXPENSIVE] == [0.0, 0.0]
    for (trap, bnds, kwargs) in (
            ((5.0, 10.0, 90.0, 100.0, 0.0), bands, (;)),            # MaxAvail = 0
            ((5.0, 10.0, 40.0, 50.0, 10.0), bands, (; initial = 60.0)),  # stranded above EnablementMax
            (trapezium, bands, (; initial = 6.0, availability = 4.0)),   # energy availability below EnablementMin
        )
        @test first(capacity_bound_mw(trap, bnds; kwargs...))[TOY_CHEAP] == [0.0]
    end

    # A disabled bid's joint rows are inactive, with a zero slope.
    _, container = capacity_bound_mw((5.0, 10.0, 90.0, 100.0, 0.0), bands)
    inactive = FCAS_INACTIVE_LIMIT_MW / PSI.get_base_power(container)
    cap = fcas_capacity(container, "TAS1_RAISE6SEC")[TOY_CHEAP, 1]
    upper, lower = (joint_row(container, "TAS1_RAISE6SEC_$side", TOY_CHEAP) for side in ("upper", "lower"))
    @test upper.set == PSI.MOI.LessThan(inactive) && lower.set == PSI.MOI.GreaterThan(-inactive)
    @test get(upper.func.terms, cap, 0.0) == 0.0 && get(lower.func.terms, cap, 0.0) == 0.0
end

@testset "check_fcas_services and the build refuse unsupported FCAS contributors" begin
    lower6 = (BidType.LOWER6SEC, (1.0, 5.0, 26.0, 27.0, 4.0), [(4.0, 10.0)])
    sys = fcas_offer_sys(2.0, [lower6])
    function partial_template(thermal_model, service = "TAS1_LOWER6SEC")
        template = PSI.ProblemTemplate(PSI.NetworkModel(PSI.AreaBalancePowerModel; use_slacks = true))
        PSI.set_device_model!(template, PSY.PowerLoad, PSI.StaticPowerLoad)
        isnothing(thermal_model) || PSI.set_device_model!(template, ThermalStandard, thermal_model)
        PSI.set_service_model!(template, service, PSI.ServiceModel(FCASService, FCASMarket, service))
        return template
    end

    @testset "a contributor the template doesn't model, or models as FixedOutput" begin
        err = _caught(() -> check_fcas_services(partial_template(nothing), sys))
        @test err isa ArgumentError
        @test occursin(TOY_CHEAP, sprint(showerror, err))
        err = _caught(() -> check_fcas_services(partial_template(PSI.FixedOutput), sys))
        @test err isa ArgumentError
        @test occursin("FixedOutput", sprint(showerror, err))
    end

    @testset "a decremental bid on a non-Storage device" begin
        dec_sys = fcas_offer_sys(2.0, [lower6]; decremental = true)
        phrase = "carries neither an incremental nor a decremental LOWER6SEC bid"
        err = _caught(() -> check_fcas_services(fcas_toy_template(dec_sys, ["TAS1_LOWER6SEC"]), dec_sys))
        @test err isa ArgumentError && occursin(phrase, sprint(showerror, err))
        err = fcas_build_error(dec_sys, ["TAS1_LOWER6SEC"])
        @test err isa ArgumentError && occursin(phrase, sprint(showerror, err))
    end

    @testset "unavailable devices and services not modeled by FCASMarket are skipped" begin
        scope_sys = fcas_energy_toy_system(
            2.0;
            mutate! = (sys, stamps) -> begin
                device = PSY.get_component(ThermalStandard, sys, TOY_CHEAP)
                add_toy_fcas!(sys, device, stamps[1], length(stamps), BidType.RAISE6SEC, (0.0, 0.0, 100.0, 100.0, 10.0), [(10.0, 10.0)])
                # TOY_EXPENSIVE is unavailable in the toy system and carries no FCAS bid.
                offline = PSY.get_component(ThermalStandard, sys, TOY_EXPENSIVE)
                PSY.add_service!(sys, FCASService(; name = "TAS1_RAISE6SEC", region = "TAS1", bid_type = BidType.RAISE6SEC), [device, offline])
                PSY.add_service!(sys, FCASService(; name = "TAS1_LOWER6SEC", region = "TAS1", bid_type = BidType.LOWER6SEC), [device])
            end,
        )
        @test isnothing(check_fcas_services(fcas_toy_template(scope_sys, ["TAS1_RAISE6SEC"]), scope_sys))
    end

    @testset "a regulation contributor missing an observed initial MW" begin
        reg_sys = fcas_offer_sys(
            2.0, [(BidType.RAISEREG, (0.0, 0.0, 100.0, 100.0, 10.0), [(10.0, 10.0)])];
            extra! = (sys, device, stamps) -> add_toy_fcas_scaling!(sys, device, stamps[1], length(stamps), BidType.RAISEREG; agc_max_avail = 5.0),
        )
        AustralianElectricityMarkets.set_observed_state!(
            PSY.get_component(ThermalStandard, reg_sys, TOY_CHEAP),
            AustralianElectricityMarkets.NEMObservedState(; initial_mw = 0.0, dispatch_mode = 0),
        )
        err = _caught(() -> check_fcas_services(partial_template(NEMDispatch, "TAS1_RAISEREG"), reg_sys))
        @test err isa ArgumentError
        @test occursin("observed initial MW", sprint(showerror, err))
    end
end

@testset "a device in two FCASServices of one market" begin
    sys = fcas_offer_sys(
        2.0, [
            (BidType.RAISEREG, (0.0, 0.0, 100.0, 100.0, 9.0), [(9.0, 10.0)]),
            (BidType.RAISE6SEC, (0.0, 0.0, 100.0, 100.0, 10.0), [(10.0, 10.0)]),
        ],
    )
    # Added after the toy build, whose effective-offer derivation refuses it.
    PSY.add_service!(
        sys, FCASService(; name = "TAS1_RAISEREG_B", region = "TAS1", bid_type = BidType.RAISEREG),
        [PSY.get_component(ThermalStandard, sys, TOY_CHEAP)],
    )
    template = fcas_toy_template(sys, ["TAS1_RAISEREG", "TAS1_RAISEREG_B", "TAS1_RAISE6SEC"])
    err = _caught(() -> check_fcas_services(template, sys))
    @test err isa ArgumentError
    @test occursin("TAS1_RAISEREG, TAS1_RAISEREG_B", sprint(showerror, err))
    model = PSI.DecisionModel(
        template, sys; optimizer = optimizer_with_attributes(HiGHS.Optimizer, "output_flag" => false),
        horizon = TOY_RESOLUTION, resolution = TOY_RESOLUTION, interval = TOY_RESOLUTION, initial_time = TOY_START,
    )
    @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.FAILED
end

@testset "FCASMarket build contracts" begin
    sys = fcas_offer_sys(2.0, [(BidType.RAISE6SEC, (0.0, 0.0, 100.0, 100.0, 10.0), [(10.0, 10.0)])])
    # Builds for a recurrent simulation.
    @test isnothing(fcas_build_error(sys, ["TAS1_RAISE6SEC"]; recurrent = true))

    container = build_fcas(sys, ["TAS1_RAISE6SEC"])
    err = _caught() do
        PSI.construct_service!(
            container, sys, PSI.ArgumentConstructStage(),
            PSI.ServiceModel(FCASService, FCASMarket, "TAS1_RAISE6SEC"; duals = [PSI.CopperPlateBalanceConstraint]),
            Dict{Symbol, PSI.DeviceModel}(), Set{DataType}(), PSI.NetworkModel(PSI.CopperPlatePowerModel),
        )
    end
    @test err isa ArgumentError
    @test occursin("FCASJointCapacityConstraint and FCASUnitConstraint only", err.msg)

    # Without its effective offer forecast the device cannot be built, and the error names the setter.
    device = PSY.get_component(ThermalStandard, sys, TOY_CHEAP)
    PSY.remove_time_series!(sys, PSY.DeterministicSingleTimeSeries, device, "fcas_effective_RAISE6SEC")
    PSY.remove_time_series!(sys, PSY.SingleTimeSeries, device, "fcas_effective_RAISE6SEC")
    err = fcas_build_error(sys, ["TAS1_RAISE6SEC"])
    @test err isa ArgumentError
    @test occursin("nem_system", err.msg)
end

"""
    load_fcas_toy(bids; initial = 10.0, capacity = 40.0, availability = 40.0, extra! = nothing)

A toy `System` whose scheduled load `"PUMP"` (`InterruptiblePowerLoad`, `InitialMW = initial`)
offers each `(bid_type, trapezium_mw, bands)` of `bids` on its decremental series and contributes to
one `FCASService` named `"TAS1_<bid_type>"` per bid. `extra!(sys, load, stamps)` runs last.
"""
function load_fcas_toy(bids; initial = 10.0, capacity = 40.0, availability = 40.0, extra! = nothing)
    return nem_toy_system(
        [TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = 50.0, ramp_up = 1.0e4, ramp_down = 1.0e4)],
        40.0;
        loads = ["PUMP" => toy_load(capacity, 5.0; initial, ramp_up = 1.0e4, ramp_down = 1.0e4, availability)],
        mutate! = (sys, stamps) -> begin
            load = PSY.get_component(InterruptiblePowerLoad, sys, "PUMP")
            for (bid_type, trapezium_mw, bands) in bids
                add_toy_fcas!(sys, load, stamps[1], length(stamps), bid_type, trapezium_mw, bands; decremental = true)
                PSY.add_service!(
                    sys, FCASService(; name = "TAS1_$(string(bid_type))", region = "TAS1", bid_type = bid_type), [load],
                )
            end
            isnothing(extra!) || extra!(sys, load, stamps)
        end,
    )
end

"""
    joint_ramping_toy(initial_mw; capacity = 1000.0, raise_agc = nothing, lower_agc = nothing, extra! = nothing)

A one-unit toy `System` (`InitialMW = initial_mw`) bidding flat RAISEREG and LOWERREG trapeziums as
`"TAS1_RAISEREG"`/`"TAS1_LOWERREG"`, with an AGC ramping capability of `raise_agc`/`lower_agc` MW per
interval when given, for AEMO *FCAS Model in NEMDE* §6.1 joint ramping tests.
"""
function joint_ramping_toy(
        initial_mw; capacity = 1000.0, raise_agc::Union{Nothing, Float64} = nothing,
        lower_agc::Union{Nothing, Float64} = nothing, extra! = nothing,
    )
    return nem_toy_system(
        [
            TOY_CHEAP => toy_unit(
                capacity, [(capacity, 20.0)]; initial = initial_mw, ramp_up = 1.0e4, ramp_down = 1.0e4,
                availability = capacity,
            ),
        ],
        max(initial_mw, 1.0);
        mutate! = (sys, stamps) -> begin
            device = PSY.get_component(ThermalStandard, sys, TOY_CHEAP)
            n = length(stamps)
            trap = (0.0, 0.0, capacity, capacity, capacity)
            for (bid_type, agc) in ((BidType.RAISEREG, raise_agc), (BidType.LOWERREG, lower_agc))
                add_toy_fcas!(sys, device, stamps[1], n, bid_type, trap, [(capacity, 10.0)])
                isnothing(agc) || add_toy_fcas_scaling!(sys, device, stamps[1], n, bid_type; agc_max_avail = agc)
                PSY.add_service!(sys, FCASService(; name = "TAS1_$(string(bid_type))", region = "TAS1", bid_type = bid_type), [device])
            end
            isnothing(extra!) || extra!(sys, device, stamps)
        end,
    )
end

"Whether `row` (a `JuMP.constraint_object`) has the inactive right-hand side `FCAS_INACTIVE_LIMIT_MW`, upper or lower form, at `base_power`."
function _is_placeholder_row(row; base_power = 100.0)
    inactive = FCAS_INACTIVE_LIMIT_MW / base_power
    return row.set == PSI.MOI.LessThan(inactive) || row.set == PSI.MOI.GreaterThan(-inactive)
end

@testset "AEMO §6.1 joint ramping constraint" begin
    duid = TOY_CHEAP

    @testset "RAISEREG and LOWERREG bind on the joint ramp (A.2 numbers)" begin
        # InitialMW 450, AGC up 15 MW and down 10 MW per interval: energy + RaiseReg <= 465, energy - LowerReg >= 440.
        container = build_fcas(joint_ramping_toy(450.0; raise_agc = 15.0, lower_agc = 10.0), ["TAS1_RAISEREG", "TAS1_LOWERREG"])
        for (energy_mw, service, expected) in ((460.0, "TAS1_RAISEREG", 5.0), (465.0, "TAS1_RAISEREG", 0.0), (445.0, "TAS1_LOWERREG", 5.0))
            fix_energy!(container, duid, energy_mw)
            @test max_fcas_mw(container, service, duid) ≈ expected atol = FCAS_TOY_TOLERANCE
        end
    end

    @testset "a BDU's row reads net energy and, two-sided, the combined regulation target" begin
        model = _build_bdu_regulation("BDU", 0.0, 20.0; initial_mw = -20.0, scaling = (; agc_max_avail = 12.0), solve = false)
        container = PSI.get_optimization_container(model)
        row = unit_row(container, "joint_ramping|BDU", "BAT1")
        @test row.func.terms[bat_var(container, PSI.ActivePowerOutVariable)] == 1.0
        @test row.func.terms[bat_var(container, PSI.ActivePowerInVariable)] == -1.0
        @test row.func.terms[fcas_side_capacity(container, "BDU", :gen)["BAT1", 1]] == 1.0
        @test row.func.terms[fcas_side_capacity(container, "BDU", :load)["BAT1", 1]] == 1.0
        # InitialMW (-20) + AGC ramping capability (12) = -8.
        @test row.set.upper ≈ -8.0 / PSI.get_base_power(container) atol = 1.0e-9

        model, _ = storage_fcas_toy_model("S", BidType.RAISEREG, (0.0, 0.0, 20.0, 20.0, 10.0); scaling = (; agc_max_avail = 5.0))
        container = PSI.get_optimization_container(model)
        row = unit_row(container, "joint_ramping|S", "BAT1")
        @test row.func.terms[bat_var(container, PSI.ActivePowerOutVariable)] == 1.0
        @test row.func.terms[bat_var(container, PSI.ActivePowerInVariable)] == -1.0
    end

    @testset "a load's rows are swapped" begin
        trapezium = (0.0, 0.0, 100.0, 100.0, 100.0)
        sys = load_fcas_toy(
            [(BidType.RAISEREG, trapezium, [(100.0, 10.0)]), (BidType.LOWERREG, trapezium, [(100.0, 10.0)])];
            initial = 20.0,
            extra! = (sys, load, stamps) -> begin
                add_toy_fcas_scaling!(sys, load, stamps[1], length(stamps), BidType.RAISEREG; agc_max_avail = 15.0)
                add_toy_fcas_scaling!(sys, load, stamps[1], length(stamps), BidType.LOWERREG; agc_max_avail = 10.0)
            end,
        )
        container = build_fcas(sys, ["TAS1_RAISEREG", "TAS1_LOWERREG"])
        # Consumption + LowerReg <= InitialMW + up (35); consumption - RaiseReg >= InitialMW - down (10).
        for (service, energy_mw, expected) in (("TAS1_LOWERREG", 30.0, 5.0), ("TAS1_RAISEREG", 12.0, 2.0))
            fix_energy!(container, "PUMP", energy_mw; device_type = InterruptiblePowerLoad)
            @test max_fcas_mw(container, service, "PUMP") ≈ expected atol = FCAS_TOY_TOLERANCE
        end
    end

    @testset "an inactive row where §6.1 doesn't apply" begin
        # No AGC ramp rate series, a zero AGC ramp rate, AGC status 0.
        for sys in (
                joint_ramping_toy(450.0), joint_ramping_toy(450.0; raise_agc = 0.0),
                joint_ramping_toy(
                    450.0; raise_agc = 15.0,
                    extra! = (sys, device, stamps) -> add_toy_fcas_agc_status!(sys, device, stamps[1], length(stamps), 0),
                ),
            )
            container = build_fcas(sys, ["TAS1_RAISEREG"])
            @test _is_placeholder_row(unit_row(container, "joint_ramping|TAS1_RAISEREG", duid))
        end
    end

    @testset "FCASUnitConstraint duals are read back" begin
        sys = joint_ramping_toy(450.0; raise_agc = 15.0, lower_agc = 10.0)
        model = PSI.DecisionModel(
            fcas_toy_template(sys, ["TAS1_RAISEREG"]; duals = [FCASJointCapacityConstraint, FCASUnitConstraint]), sys;
            optimizer = optimizer_with_attributes(HiGHS.Optimizer, "output_flag" => false),
            horizon = TOY_RESOLUTION, resolution = TOY_RESOLUTION, interval = TOY_RESOLUTION, initial_time = TOY_START,
        )
        @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
        @test PSI.solve!(model) == PSI.RunStatus.SUCCESSFULLY_FINALIZED
        dual_key = only(
            k for k in PSI.get_constraint_keys(PSI.get_optimization_container(model))
                if PSI.IS.Optimization.get_entry_type(k) === FCASUnitConstraint && startswith(k.meta, "joint_ramping|")
        )
        dual_df = PSI.read_dual(PSI.OptimizationProblemResults(model), dual_key)
        @test !isempty(dual_df) && all(!isnan, dual_df.value)
    end
end

"A 100 MW unit at 20 MW offering LOWER6SEC on a (1, 5, 26, 27, 4) MW trapezium, with one `band_mw` band."
lower6sec_slack_sys(band_mw) = nem_toy_system(
    [TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = 20.0, ramp_up = 100.0, ramp_down = 100.0, availability = 100.0)],
    20.0;
    mutate! = (sys, stamps) -> begin
        device = PSY.get_component(ThermalStandard, sys, TOY_CHEAP)
        add_toy_fcas!(sys, device, stamps[1], length(stamps), BidType.LOWER6SEC, (1.0, 5.0, 26.0, 27.0, 4.0), [(band_mw, 10.0)])
        PSY.add_service!(sys, FCASService(; name = "TAS1_LOWER6SEC", region = "TAS1", bid_type = BidType.LOWER6SEC), [device])
    end,
)

@testset "elastic FCAS rows (use_slacks)" begin
    duid = TOY_CHEAP
    slack_mw(container, meta, id = duid) = PSI.JuMP.value(fcas_slack(container, meta, id)) * PSI.get_base_power(container)

    @testset "off by default: no slack variables" begin
        container = build_fcas(joint_ramping_toy(450.0; raise_agc = 15.0), ["TAS1_RAISEREG"])
        @test !PSI.has_container_key(container, FCASSlack, FCASService, "joint_ramping|TAS1_RAISEREG")
    end

    @testset "ramping slacks absorb a violated §6.1 row and are priced at 155 x MPC" begin
        container = build_fcas(
            joint_ramping_toy(450.0; raise_agc = 15.0, lower_agc = 10.0), ["TAS1_RAISEREG", "TAS1_LOWERREG"]; use_slacks = true,
        )
        slack = fcas_slack(container, "joint_ramping|TAS1_RAISEREG", duid)
        @test slack_cost(container, slack) ≈ cvp_cost(container, FCAS_RAMPING_CVP_FACTOR)
        # 10 MW above the 465 MW ceiling, then 5 MW below the 440 MW floor.
        for (energy_mw, meta, excess) in ((475.0, "joint_ramping|TAS1_RAISEREG", 10.0), (435.0, "joint_ramping|TAS1_LOWERREG", 5.0))
            fix_energy!(container, duid, energy_mw)
            solve_container!(container)
            @test slack_mw(container, meta) ≈ excess atol = FCAS_TOY_TOLERANCE
        end
    end

    @testset "capacity slacks are priced at 70 x MPC and absorb a breached window by exactly the excess" begin
        function lower6sec_slacks(energy_mw)
            # InitialMW 20 keeps the §5 gate open; the fixed dispatch then breaches the window.
            container = build_fcas(lower6sec_slack_sys(4.0), ["TAS1_LOWER6SEC"]; use_slacks = true)
            for side in ("upper", "lower")
                @test slack_cost(container, fcas_slack(container, "joint_capacity|TAS1_LOWER6SEC_$side", duid)) ≈
                    cvp_cost(container, FCAS_CAPACITY_CVP_FACTOR)
            end
            fix_energy!(container, duid, energy_mw)
            solve_container!(container)
            return [slack_mw(container, "joint_capacity|TAS1_LOWER6SEC_$side") for side in ("upper", "lower")]
        end
        # EnablementMax 27, EnablementMin 1.
        @test lower6sec_slacks(30.0) ≈ [3.0, 0.0] atol = FCAS_TOY_TOLERANCE
        @test lower6sec_slacks(0.5) ≈ [0.0, 0.5] atol = FCAS_TOY_TOLERANCE
        @test lower6sec_slacks(10.0) ≈ [0.0, 0.0] atol = FCAS_TOY_TOLERANCE
    end

    @testset "MaxAvail becomes a row priced at 155 x MPC whose slack absorbs the excess" begin
        # The 6 MW offer band exceeds the 4 MW MaxAvail, so MaxAvail is the only cap on the capacity.
        container = build_fcas(lower6sec_slack_sys(6.0), ["TAS1_LOWER6SEC"]; use_slacks = true)
        var = fcas_capacity(container, "TAS1_LOWER6SEC")[duid, 1]
        @test !PSI.JuMP.has_upper_bound(var)
        @test slack_cost(container, fcas_slack(container, "max_avail|TAS1_LOWER6SEC_maxavail", duid)) ≈
            cvp_cost(container, FCAS_MAXAVAIL_CVP_FACTOR)
        fix_energy!(container, duid, 10.0)
        PSI.JuMP.fix(var, 4.5 / PSI.get_base_power(container); force = true)
        solve_container!(container)
        @test slack_mw(container, "max_avail|TAS1_LOWER6SEC_maxavail") ≈ 0.5 atol = FCAS_TOY_TOLERANCE
    end

    @testset "a BDU's per-side MaxAvail and SCADA ramping slacks" begin
        # Each side's MaxAvail is 10 MW against 20 MW bands; fixing the sides at 12 and 13 MW exceeds
        # both, and their 25 MW total exceeds the 12 MW SCADA ramp by 13.
        model = _build_bdu_regulation("BDU", 15.0, 15.0; scaling = (; agc_max_avail = 12.0), band_mw = 20.0, solve = false, use_slacks = true)
        container = PSI.get_optimization_container(model)
        base_power = PSI.get_base_power(container)
        for (side, mw) in ((:gen, 12.0), (:load, 13.0))
            PSI.JuMP.fix(fcas_side_capacity(container, "BDU", side)["BAT1", 1], mw / base_power; force = true)
        end
        solve_container!(container)
        for (side, excess) in (("gen", 2.0), ("load", 3.0))
            meta = "max_avail|BDU_$(side)_maxavail"
            @test slack_mw(container, meta, "BAT1") ≈ excess atol = FCAS_TOY_TOLERANCE
            @test slack_cost(container, fcas_slack(container, meta, "BAT1")) ≈ cvp_cost(container, FCAS_MAXAVAIL_CVP_FACTOR)
        end
        @test slack_mw(container, "bdu_ramping|BDU", "BAT1") ≈ 13.0 atol = FCAS_TOY_TOLERANCE
        @test slack_cost(container, fcas_slack(container, "bdu_ramping|BDU", "BAT1")) ≈ cvp_cost(container, FCAS_BDU_RAMPING_CVP_FACTOR)
    end

    @testset "a two-sided BDU's generation-side capacity slack" begin
        model = _build_bdu_regulation("BDU", 0.0, 20.0; initial_mw = 10.0, solve = false, use_slacks = true)
        container = PSI.get_optimization_container(model)
        fix_storage!(container, 30.0, 0.0)  # above the generation-side EnablementMax (25)
        solve_container!(container)
        @test slack_mw(container, "joint_capacity|BDU_gen_upper", "BAT1") ≈ 5.0 atol = FCAS_TOY_TOLERANCE
    end
end

# A toy system whose one unit bids each `(bid_type, price)` in `bids` (flat 20 MW trapezium), with
# a GenericConstraint per `(name, sense, rhs_mw, terms, requirements)` in `gcs`.
function fcas_requirement_toy_system(bids, gcs)
    return fcas_energy_toy_system(
        2.0;
        mutate! = (sys, stamps) -> begin
            device = PSY.get_component(ThermalStandard, sys, TOY_CHEAP)
            for (bid_type, price) in bids
                add_toy_fcas!(sys, device, stamps[1], length(stamps), bid_type, (0.0, 0.0, 100.0, 100.0, 20.0), [(20.0, price)])
                PSY.add_service!(
                    sys, FCASService(; name = fcas_service_name(device, bid_type), region = "1", bid_type = bid_type), [device],
                )
            end
            for (name, sense, rhs_mw, terms, requirements) in gcs
                gc = GenericConstraint(;
                    name = name, sense = sense, rhs = rhs_mw, terms = ConstraintTerm[terms...],
                    fcas_requirements = [FCASRequirement("1", bt) for bt in requirements],
                )
                PSY.add_service!(sys, gc, [device])
                add_toy_constraint_series!(sys, gc, stamps, fill(rhs_mw, length(stamps)), fill(1.0, length(stamps)))
            end
        end,
    )
end

function solve_fcas_requirement(sys, service_names, gc_names; use_slacks = false, steps = 1, mpc = nothing)
    template = fcas_toy_template(sys, service_names)
    for name in gc_names
        PSI.set_service_model!(
            template, name, PSI.ServiceModel(GenericConstraint, LinearFactorLimit, name; duals = [NEMConstraintLimit], use_slacks),
        )
    end
    model = PSI.DecisionModel(
        template, sys;
        optimizer = optimizer_with_attributes(HiGHS.Optimizer, "output_flag" => false),
        horizon = steps * TOY_RESOLUTION, resolution = TOY_RESOLUTION, interval = TOY_RESOLUTION,
        initial_time = TOY_START, name = "fcas_req_toy", store_variable_names = true,
    )
    isnothing(mpc) || (PSI.get_ext(PSI.get_settings(model))["market_price_cap"] = mpc)
    @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
    @test PSI.solve!(model) == PSI.RunStatus.SUCCESSFULLY_FINALIZED
    return PSI.OptimizationProblemResults(model)
end

fcas_enabled_mw(results, sys, service_name) =
    PSI.read_variable(results, "FCASCapacityVariable__FCASService__$service_name").value .* PSY.get_base_power(sys)

@testset "a UnitTerm/RegionTerm on a contingency or regulation service forces it and prices the region via the dual" begin
    unit(bt) = UnitTerm(TOY_CHEAP, bt, 1.0)
    region(bt) = RegionTerm("1", bt, 1.0, [TOY_CHEAP])
    for (bid_type, make_term) in ((BidType.RAISE6SEC, unit), (BidType.RAISEREG, region))
        gcs = [("F_TOY", ConstraintSense.GE, 5.0, [make_term(bid_type)], [bid_type])]
        sys = fcas_requirement_toy_system([(bid_type, 10.0)], gcs)
        # Two intervals, so the resolution is read from `results`.
        results = solve_fcas_requirement(sys, ["1_$(string(bid_type))"], ["F_TOY"]; steps = 2)
        @test fcas_enabled_mw(results, sys, "1_$(string(bid_type))") ≈ [5.0, 5.0] atol = FCAS_TOY_TOLERANCE
        prices = read_fcas_prices(results, sys)
        @test prices.REGIONID == ["1", "1"]
        @test prices.BIDTYPE == [bid_type, bid_type]
        @test prices.ROP ≈ [10.0, 10.0] atol = 1.0e-4
    end
end

@testset "a binding LE FCAS constraint carries a non-positive dual (the solver's sign)" begin
    # A negative offer rewards capacity, so `<= 3 MW` binds; raising its right-hand side by 1 MW lowers cost by 10.
    bid_type = BidType.RAISE6SEC
    gcs = [("F_TOY", ConstraintSense.LE, 3.0, [UnitTerm(TOY_CHEAP, bid_type, 1.0)], [bid_type])]
    sys = fcas_requirement_toy_system([(bid_type, -10.0)], gcs)
    results = solve_fcas_requirement(sys, ["1_RAISE6SEC"], ["F_TOY"])
    @test fcas_enabled_mw(results, sys, "1_RAISE6SEC") ≈ [3.0] atol = FCAS_TOY_TOLERANCE
    @test read_fcas_prices(results, sys; resolution = TOY_RESOLUTION).ROP ≈ [-10.0] atol = 1.0e-4
end

@testset "constraints naming the same (region, service) sum, and one naming two services feeds both" begin
    r6, r60 = BidType.RAISE6SEC, BidType.RAISE60SEC
    gcs = [
        ("F_ONE", ConstraintSense.GE, 5.0, [UnitTerm(TOY_CHEAP, r6, 1.0)], [r6]),
        ("F_TWO", ConstraintSense.GE, 12.0, [UnitTerm(TOY_CHEAP, r6, 1.0), UnitTerm(TOY_CHEAP, r60, 1.0)], [r6, r60]),
    ]
    sys = fcas_requirement_toy_system([(r6, 10.0), (r60, 4.0)], gcs)
    results = solve_fcas_requirement(sys, ["1_RAISE6SEC", "1_RAISE60SEC"], ["F_ONE", "F_TWO"])
    @test fcas_enabled_mw(results, sys, "1_RAISE6SEC") ≈ [5.0] atol = FCAS_TOY_TOLERANCE
    @test fcas_enabled_mw(results, sys, "1_RAISE60SEC") ≈ [7.0] atol = FCAS_TOY_TOLERANCE
    # F_ONE's dual is 10 - 4 = 6 and F_TWO's is 4: RAISE6SEC sums both, RAISE60SEC gets F_TWO's alone.
    prices = read_fcas_prices(results, sys; resolution = TOY_RESOLUTION)
    @test prices.BIDTYPE == [r60, r6]
    @test prices.ROP ≈ [4.0, 10.0] atol = 1.0e-4
end

@testset "a violated requirement prices at its constraint violation penalty when elastic" begin
    bid_type = BidType.RAISE6SEC
    gcs = [("F_TOY", ConstraintSense.GE, 25.0, [UnitTerm(TOY_CHEAP, bid_type, 1.0)], [bid_type])]
    sys = fcas_requirement_toy_system([(bid_type, 10.0)], gcs)
    results = solve_fcas_requirement(sys, ["1_RAISE6SEC"], ["F_TOY"]; use_slacks = true, mpc = 20_300.0)
    weight = get_constraint_weight(get_component(GenericConstraint, sys, "F_TOY"))
    @test fcas_enabled_mw(results, sys, "1_RAISE6SEC") ≈ [20.0] atol = FCAS_TOY_TOLERANCE
    @test read_fcas_prices(results, sys; resolution = TOY_RESOLUTION).ROP ≈ [weight * 20_300.0] rtol = 1.0e-6
end

@testset "a bidirectional Storage regulation unit enters a constraint through its net gen + load target" begin
    service_name = fcas_service_name(get_component(EnergyReservoirStorage, augmented_pscb_system(), "BAT1"), BidType.RAISEREG)
    # Each side holds at most 10 MW; the cheaper load side (12) takes 10 and the generation side (15) the last MW.
    model = _build_bdu_regulation(service_name, 15.0, 15.0; scaling = (; agc_max_avail = 12.0), solve = false, requirement_mw = 11.0)
    sys = PSI.get_system(model)
    fix_storage!(PSI.get_optimization_container(model), 15.0, 15.0)
    @test PSI.solve!(model) == PSI.RunStatus.SUCCESSFULLY_FINALIZED
    results = PSI.OptimizationProblemResults(model)
    gen = PSI.read_variable(results, "FCASSideCapacityVariable__FCASService__$(service_name)_gen")
    load = PSI.read_variable(results, "FCASSideCapacityVariable__FCASService__$(service_name)_load")
    @test only(gen.value + load.value) * PSY.get_base_power(sys) ≈ 11.0 atol = FCAS_TOY_TOLERANCE
    @test read_fcas_prices(results, sys; resolution = TOY_RESOLUTION).ROP ≈ [15.0] atol = 1.0e-4
end

@testset "read_fcas_prices needs a resolution for one interval, and warns on constraints without a dual" begin
    bid_type = BidType.RAISE6SEC
    gcs = [("F_TOY", ConstraintSense.GE, 5.0, [UnitTerm(TOY_CHEAP, bid_type, 1.0)], [bid_type])]
    sys = fcas_requirement_toy_system([(bid_type, 10.0)], gcs)
    results = solve_fcas_requirement(sys, ["1_RAISE6SEC"], ["F_TOY"])
    @test_throws ArgumentError read_fcas_prices(results, sys)
    extra = GenericConstraint(;
        name = "F_UNBUILT", sense = ConstraintSense.GE, rhs = 0.0, fcas_requirements = [FCASRequirement("1", BidType.LOWER6SEC)],
    )
    PSY.add_component!(sys, extra)
    prices = @test_logs (:warn, r"F_UNBUILT") read_fcas_prices(results, sys; resolution = TOY_RESOLUTION)
    @test nrow(prices) == 1
end

@testset "an FCAS term's service must be modelled when it has devices; absent or empty services count as zero" begin
    bid_type = BidType.RAISE6SEC
    term = UnitTerm(TOY_CHEAP, bid_type, 1.0)
    sys = fcas_requirement_toy_system([(bid_type, 10.0)], [("F_TOY", ConstraintSense.GE, 5.0, [term], [bid_type])])
    device = PSY.get_component(ThermalStandard, sys, TOY_CHEAP)
    PSY.add_service!(sys, FCASService(; name = "1_LOWER6SEC", region = "1", bid_type = BidType.LOWER6SEC), [device])
    gc_template(service) = begin
        template = fcas_toy_template(sys, [service])
        PSI.set_service_model!(template, "F_TOY", PSI.ServiceModel(GenericConstraint, LinearFactorLimit, "F_TOY"))
        template
    end
    # The template models a different FCAS service only, so the term's own service has no FCASMarket model.
    template = gc_template("1_LOWER6SEC")
    @test [(r.constraint, r.reason, r.blocking) for r in _diagnosed_gcs(sys, template)] == [("F_TOY", :unmodeled_fcas_service, true)]
    err = _caught(() -> AEMS._check_blocked_constraints(AEMS._blocked_constraints(sys, template)))
    @test err isa ArgumentError
    @test occursin("F_TOY (unmodeled_fcas_service)", sprint(showerror, err))
    @test isempty(_diagnosed_gcs(sys, gc_template("1_RAISE6SEC")))
    # A service whose devices are all unavailable is skipped by FCASMarket and counts as zero.
    PSY.set_available!(device, false)
    @test isempty(_diagnosed_gcs(sys, template))
end

@testset "absent FCAS services warn once per build, naming their union" begin
    bid_types = [BidType.RAISE6SEC, BidType.LOWER6SEC, BidType.RAISE6SEC]
    sys = fcas_energy_toy_system(
        2.0;
        mutate! = (sys, stamps) -> begin
            device = PSY.get_component(ThermalStandard, sys, TOY_CHEAP)
            for (i, bid_type) in enumerate(bid_types)
                gc = GenericConstraint(;
                    name = "F_ABSENT_$i", sense = ConstraintSense.GE, rhs = 5.0,
                    terms = ConstraintTerm[UnitTerm(TOY_CHEAP, bid_type, 1.0)],
                )
                PSY.add_service!(sys, gc, [device])
                add_toy_constraint_series!(sys, gc, stamps, fill(5.0, length(stamps)), fill(1.0, length(stamps)))
            end
            return
        end,
    )
    template = fcas_toy_template(sys, String[])
    for i in eachindex(bid_types)
        PSI.set_service_model!(template, "F_ABSENT_$i", PSI.ServiceModel(GenericConstraint, LinearFactorLimit, "F_ABSENT_$i"))
    end
    model = PSI.DecisionModel(
        template, sys; optimizer = HiGHS.Optimizer, horizon = TOY_RESOLUTION,
        resolution = TOY_RESOLUTION, interval = TOY_RESOLUTION, initial_time = TOY_START,
    )
    PSI.set_output_dir!(model, mktempdir())
    # PSI.build! routes its own logging to files under the output directory, so read the warning back from there.
    out = mktempdir()
    PSI.build!(model; output_dir = out)
    log_text = join((read(joinpath(root, f), String) for (root, _, files) in walkdir(out) for f in files if endswith(f, ".log")), "\n")
    warnings = [m.match for m in eachmatch(r"FCAS terms reference services absent[^\n]*", log_text)]
    @test length(warnings) == 1
    device = PSY.get_component(ThermalStandard, sys, TOY_CHEAP)
    names = sort(unique(fcas_service_name.(Ref(device), bid_types)))
    @test occursin("$(join(names, ", ")); 3 generic constraint(s)", only(warnings))
end

@testset "a scheduled load offers FCAS on its consumption axis" begin
    # UpperSlope (30 - 20) / 10 = 1.0, LowerSlope (10 - 5) / 10 = 0.5.
    contingency = (BidType.RAISE6SEC, (5.0, 10.0, 20.0, 30.0, 10.0), [(10.0, 10.0)])
    function raise6sec_cap(consumption; regulation = nothing)
        bids = isnothing(regulation) ? [contingency] : [contingency, (regulation, (0.0, 0.0, 100.0, 100.0, 9.0), [(9.0, 10.0)])]
        container = build_fcas(load_fcas_toy(bids), ["TAS1_$(string(b[1]))" for b in bids])
        fix_energy!(container, "PUMP", consumption; device_type = InterruptiblePowerLoad)
        isnothing(regulation) || PSI.JuMP.fix(
            fcas_capacity(container, "TAS1_$(string(regulation))")["PUMP", 1], 4.0 / PSI.get_base_power(container); force = true,
        )
        return max_fcas_mw(container, "TAS1_RAISE6SEC", "PUMP")
    end
    # Upper slope: 25 + 1.0 R <= 30; lower slope: 8 - 0.5 R >= 5; on the plateau the full MaxAvail.
    @test raise6sec_cap(25.0) ≈ 5.0 atol = FCAS_TOY_TOLERANCE
    @test raise6sec_cap(8.0) ≈ 6.0 atol = FCAS_TOY_TOLERANCE
    @test raise6sec_cap(15.0) ≈ 10.0 atol = FCAS_TOY_TOLERANCE
    # Regulation enters swapped: LowerReg takes the upper row (25 + R + 4 <= 30), RaiseReg the lower row.
    @test raise6sec_cap(25.0; regulation = BidType.LOWERREG) ≈ 1.0 atol = FCAS_TOY_TOLERANCE
    @test raise6sec_cap(25.0; regulation = BidType.RAISEREG) ≈ 5.0 atol = FCAS_TOY_TOLERANCE

    # Maximising consumption would reach its 40 MW availability; the joint rows hold it at EnablementMax.
    container = build_fcas(load_fcas_toy([contingency]), ["TAS1_RAISE6SEC"])
    consumption = PSI.get_variable(container, PSI.ActivePowerVariable(), InterruptiblePowerLoad)["PUMP", 1]
    maximize_and_solve!(_ -> consumption, container)
    @test PSI.JuMP.value(consumption) * PSI.get_base_power(container) ≈ 30.0 atol = FCAS_TOY_TOLERANCE
end

@testset "a load's FCAS terms resolve in generic constraints and are priced" begin
    bid_type = BidType.RAISE6SEC
    sys = load_fcas_toy(
        [];
        extra! = (sys, load, stamps) -> begin
            add_toy_fcas!(
                sys, load, stamps[1], length(stamps), bid_type, (0.0, 0.0, 100.0, 100.0, 20.0), [(20.0, 10.0)]; decremental = true,
            )
            PSY.add_service!(sys, FCASService(; name = fcas_service_name(load, bid_type), region = "1", bid_type = bid_type), [load])
            gc = GenericConstraint(;
                name = "F_TOY", sense = ConstraintSense.GE, rhs = 5.0,
                terms = ConstraintTerm[UnitTerm("PUMP", bid_type, 1.0)], fcas_requirements = [FCASRequirement("1", bid_type)],
            )
            PSY.add_service!(sys, gc, [load])
            add_toy_constraint_series!(sys, gc, stamps, fill(5.0, length(stamps)), fill(1.0, length(stamps)))
        end,
    )
    results = solve_fcas_requirement(sys, ["1_RAISE6SEC"], ["F_TOY"]; steps = 2)
    @test fcas_enabled_mw(results, sys, "1_RAISE6SEC") ≈ [5.0, 5.0] atol = FCAS_TOY_TOLERANCE
    @test read_fcas_prices(results, sys).ROP ≈ [10.0, 10.0] atol = 1.0e-4
end

@testset "_fcas_direction_problem: which device types can offer each FCAS direction" begin
    thermal = PSY.get_component(ThermalStandard, fcas_energy_toy_system(2.0), TOY_CHEAP)
    load = PSY.get_component(InterruptiblePowerLoad, load_fcas_toy([]), "PUMP")
    problem(args...) = AEMS._fcas_direction_problem(args...)
    for (device, bid_type, direction, phrase) in (
            (thermal, BidType.LOWER6SEC, FCASBidDirection.NONE, "carries neither an incremental"),
            (thermal, BidType.RAISEREG, FCASBidDirection.BOTH, "carries both an incremental"),
            (thermal, BidType.LOWER6SEC, FCASBidDirection.DECREMENTAL, "has only a decremental"),
            (load, BidType.RAISE6SEC, FCASBidDirection.INCREMENTAL, "is a load with an incremental"),
        )
        @test occursin(phrase, problem(device, bid_type, direction))
    end
    @test isnothing(problem(thermal, BidType.LOWER6SEC, FCASBidDirection.INCREMENTAL))
    @test isnothing(problem(load, BidType.RAISE6SEC, FCASBidDirection.DECREMENTAL))

    # check_fcas_services accepts a load's decremental bid and refuses an incremental one.
    sys = load_fcas_toy([(BidType.RAISE6SEC, (5.0, 10.0, 20.0, 30.0, 10.0), [(10.0, 10.0)])])
    @test isnothing(check_fcas_services(fcas_toy_template(sys, ["TAS1_RAISE6SEC"]), sys))
    pump = PSY.get_component(InterruptiblePowerLoad, sys, "PUMP")
    add_toy_fcas!(sys, pump, TOY_START, 2, BidType.LOWER6SEC, (5.0, 10.0, 20.0, 30.0, 10.0), [(10.0, 10.0)])
    PSY.add_service!(sys, FCASService(; name = "TAS1_LOWER6SEC", region = "TAS1", bid_type = BidType.LOWER6SEC), [pump])
    err = _caught(() -> check_fcas_services(fcas_toy_template(sys, ["TAS1_RAISE6SEC", "TAS1_LOWER6SEC"]), sys))
    @test err isa ArgumentError
    @test occursin("incremental", sprint(showerror, err))
end

"""
    non_scheduled_fcas_sys(; extra! = nothing)

A toy `System` whose `ASLOAD` is built as a non-scheduled load (an empty `NEMOfferCost`, no energy
bid, zero availability) offering 20 MW of RAISE6SEC on the point trapezium `(0, 0, 0, 0)`.
`extra!(sys, load, stamps)` runs last.
"""
function non_scheduled_fcas_sys(; extra! = nothing)
    return nem_toy_system(
        [TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = 50.0, ramp_up = 1.0e4, ramp_down = 1.0e4)],
        40.0;
        loads = ["ASLOAD" => toy_load(1.0, 0.0; initial = 0.0, ramp_up = 0.0, ramp_down = 0.0, availability = 0.0)],
        mutate! = (sys, stamps) -> begin
            load = PSY.get_component(InterruptiblePowerLoad, sys, "ASLOAD")
            for key in collect(PSY.get_time_series_keys(load))
                PSY.remove_time_series!(sys, PSY.get_time_series_type(key), load, PSY.get_name(key))
            end
            AustralianElectricityMarkets._nem_unit_data(load).offer = NEMOfferCost()
            PSY.get_ext(load)["non_scheduled"] = true
            set_registration!(load, _toy_registration())
            zero_availability = AustralianElectricityMarkets.bid_series_name(BidType.ENERGY, :max_avail, AustralianElectricityMarkets.BidDirection.LOAD)
            # The ramp rates are written by the NEMDE input stage from the zero ramp limits set below.
            for name in ("max_active_power", zero_availability)
                PSY.add_time_series!(
                    sys, load, PSY.SingleTimeSeries(; name = name, data = PSY.TimeSeries.TimeArray(stamps, zeros(length(stamps)))),
                )
            end
            AustralianElectricityMarkets.set_telemetry!(load, nothing)
            AustralianElectricityMarkets.set_observed_state!(load, nothing)
            for field in (:initial_mw, :ramp_up_limit, :ramp_down_limit)
                set_toy_unit_field!(sys, load, stamps, field, zeros(length(stamps)))
            end
            add_toy_fcas!(
                sys, load, stamps[1], length(stamps), BidType.RAISE6SEC, (0.0, 0.0, 0.0, 0.0, 20.0), [(20.0, 3.0)]; decremental = true,
            )
            PSY.add_service!(sys, FCASService(; name = "TAS1_RAISE6SEC", region = "TAS1", bid_type = BidType.RAISE6SEC), [load])
            isnothing(extra!) || extra!(sys, load, stamps)
        end,
    )
end

@testset "a non-scheduled load with zero energy offers FCAS" begin
    container = build_fcas(non_scheduled_fcas_sys(), ["TAS1_RAISE6SEC"])
    @test max_fcas_mw(container, "TAS1_RAISE6SEC", "ASLOAD") ≈ 20.0 atol = FCAS_TOY_TOLERANCE
    var = PSI.get_variable(container, PSI.ActivePowerVariable(), InterruptiblePowerLoad)
    @test PSI.JuMP.value(var["ASLOAD", 1]) ≈ 0.0 atol = FCAS_TOY_TOLERANCE
end

@testset "a violation-priced constraint cannot dispatch a non-scheduled load for energy" begin
    # A GE row demanding 5 MW of ASLOAD energy is violable at the constraint violation price, which
    # dwarfs the load's elastic zero MaxAvail row; only the fixed energy variable keeps it at 0 MW.
    sys = non_scheduled_fcas_sys(;
        extra! = (sys, load, stamps) -> begin
            gc = GenericConstraint(;
                name = "PULL_LOAD", sense = ConstraintSense.GE, rhs = 5.0,
                terms = ConstraintTerm[UnitTerm("ASLOAD", BidType.ENERGY, 1.0)],
            )
            PSY.add_service!(sys, gc, [load])
            add_toy_constraint_series!(sys, gc, stamps, fill(5.0, length(stamps)), fill(1.0, length(stamps)))
        end,
    )
    template = fcas_toy_template(sys, ["TAS1_RAISE6SEC"])
    PSI.set_service_model!(template, "PULL_LOAD", PSI.ServiceModel(GenericConstraint, LinearFactorLimit, "PULL_LOAD"; use_slacks = true))
    model = PSI.DecisionModel(
        template, sys; optimizer = optimizer_with_attributes(HiGHS.Optimizer, "output_flag" => false),
        horizon = TOY_RESOLUTION, resolution = TOY_RESOLUTION, interval = TOY_RESOLUTION, initial_time = TOY_START,
    )
    @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
    @test PSI.solve!(model) == PSI.RunStatus.SUCCESSFULLY_FINALIZED
    var = PSI.get_variable(PSI.get_optimization_container(model), PSI.ActivePowerVariable(), InterruptiblePowerLoad)
    @test PSI.JuMP.value(var["ASLOAD", 1]) ≈ 0.0 atol = FCAS_TOY_TOLERANCE
end
