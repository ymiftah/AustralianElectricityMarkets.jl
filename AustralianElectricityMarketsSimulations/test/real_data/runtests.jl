# Integration tests against real AEMO data from a local NEMWEB hive cache. Not part of
# `Pkg.test`, and not run in CI. From the repository root:
#
#     julia --project=AustralianElectricityMarketsSimulations/test \
#         AustralianElectricityMarketsSimulations/test/real_data/runtests.jl [hive_location]
#
# `hive_location` defaults to `~/.nemdb_cache`.

using Test
using Dates
using DataFrames
using DuckDB
using HiGHS
using PowerSimulations
using AustralianElectricityMarkets
using AustralianElectricityMarketsData
using AustralianElectricityMarketsSimulations
import PowerSimulations as PSI
import PowerSystems as PSY

const AEM = AustralianElectricityMarkets
const AEMS = AustralianElectricityMarketsSimulations

const REAL_HIVE = isempty(ARGS) ? joinpath(homedir(), ".nemdb_cache") : only(ARGS)
const REAL_START = DateTime(2026, 6, 4, 0, 0)
const REAL_RESOLUTION = Minute(5)
const REAL_SPAN = Hour(1)
const REAL_DATE_RANGE = REAL_START:REAL_RESOLUTION:(REAL_START + REAL_SPAN)
const REAL_MONTH = Date(year(REAL_START), month(REAL_START), 1)

# Either table carries the dispatch FCAS requirements, depending on the archive month.
const FCAS_REQ_TABLES = (:DISPATCH_FCAS_REQ, :DISPATCH_FCAS_REQ_CONSTRAINT)

const db = aem_connect(HiveConfiguration(hive_location = REAL_HIVE))

function month_cached(table)
    root = AustralianElectricityMarketsData._parse_hive_root(db.config)
    glob = "$root/$table/archive_month=$REAL_MONTH/*.parquet"
    return only(DataFrame(DuckDB.execute(db.db, "SELECT COUNT(*) AS n FROM glob('$glob')")).n) > 0
end

let
    required = union(
        AEM.table_requirements(ConstrainedNetworkConfiguration()),
        [:BIDPEROFFER_D, :BIDDAYOFFER_D],
    )
    missing_tables = filter(t -> !(t in FCAS_REQ_TABLES) && !month_cached(t), required)
    any(month_cached, FCAS_REQ_TABLES) || push!(missing_tables, last(FCAS_REQ_TABLES))
    isempty(missing_tables) || error(
        "The hive at $REAL_HIVE has no $REAL_MONTH partition for: $(join(missing_tables, ", ")). " *
            "Populate them first, e.g.\n" * join(
            [
                "    populate(db, :$t, Date($(year(REAL_MONTH)), $(month(REAL_MONTH)), 1), " *
                    "Date($(year(REAL_MONTH)), $(month(REAL_MONTH)), $(daysinmonth(REAL_MONTH))))"
                    for t in missing_tables
            ], "\n",
        ),
    )
end

function aemsim_template(sys)
    template = PSI.ProblemTemplate(
        PSI.NetworkModel(
            PSI.AreaBalancePowerModel;
            use_slacks = true,
            duals = [PSI.CopperPlateBalanceConstraint],
        ),
    )
    set_nem_dispatch_models!(template, sys)
    PSI.set_device_model!(template, PSY.PowerLoad, PSI.StaticPowerLoad)
    PSI.set_device_model!(template, PSY.AreaInterchange, PSI.StaticBranch)
    return template
end

# `PSI.build!` swallows build exceptions into a `FAILED` status; this returns the exception.
function build_error(model)
    PSI.set_output_dir!(model, mktempdir())
    try
        PSI.build_impl!(model)
    catch e
        return e
    end
    return nothing
end

function term_device_names(gc)
    names = String[]
    for term in get_terms(gc)
        term isa UnitTerm && push!(names, get_duid(term))
        term isa RegionTerm && append!(names, get_devices(term))
    end
    return names
end

@testset "Real NEM data, $(Date(REAL_START))" begin
    sys = nem_system(db, ConstrainedNetworkConfiguration(); date_range = REAL_DATE_RANGE)

    @testset "the constrained System builds" begin
        areas = Set(PSY.get_name.(PSY.get_components(PSY.Area, sys)))
        @test issubset(Set(["NSW1", "QLD1", "SA1", "TAS1", "VIC1"]), areas)
        for T in (PSY.ThermalStandard, PSY.HydroDispatch, PSY.RenewableDispatch, PSY.AreaInterchange)
            @test !isempty(PSY.get_components(T, sys))
        end
        @test !isempty(PSY.get_components(GenericConstraint, sys))
    end

    set_demand!(sys, db, REAL_DATE_RANGE; resolution = REAL_RESOLUTION)
    set_market_bids!(sys, db, REAL_DATE_RANGE; resolution = REAL_RESOLUTION)
    set_fcas_scaling_inputs!(sys, db, REAL_DATE_RANGE)
    limits = read_dispatch_limits(db, REAL_DATE_RANGE)
    devices = AEM._nem_dispatch_devices(sys)

    @testset "dispatch limits" begin
        dispatched = Set(limits.DUID)
        @testset "every unit without DISPATCHLOAD rows was set unavailable for having no bids" begin
            @test all(d -> PSY.get_name(d) in dispatched || !PSY.get_available(d), devices)
        end

        @test begin
            set_nem_dispatch_limits!(sys, db, REAL_DATE_RANGE)
            true
        end

        @test all(
            d -> !PSY.get_available(d) || AEMS._has_nem_dispatch_limits(d, NEMReplayDispatch),
            devices,
        )

        @testset "the stored ramp rate yields AEMO's per-interval ramp" begin
            row = first(
                filter(
                    r -> r.SETTLEMENTDATE == REAL_START && coalesce(r.RAMPUPRATE, 0.0) > 0 &&
                        !isnothing(PSY.get_component(PSY.ThermalStandard, sys, r.DUID)) &&
                        PSY.get_available(PSY.get_component(PSY.ThermalStandard, sys, r.DUID)),
                    limits,
                ),
            )
            device = PSY.get_component(PSY.ThermalStandard, sys, row.DUID)
            stored = first(PSY.get_time_series_values(PSY.SingleTimeSeries, device, "ramp_up_rate"))
            minutes = Dates.value(Minute(REAL_RESOLUTION))
            # The formulation multiplies the stored rate by the interval in minutes.
            @test stored * minutes ≈
                row.RAMPUPRATE * DISPATCH_INTERVAL_HOURS / PSY.get_base_power(sys) rtol = 1.0e-9
        end
    end

    @testset "the stored dispatch ceiling is max(AVAILABILITY, ramp-down floor)" begin
        full_grid = collect(REAL_DATE_RANGE)[1:(end - 1)]
        checked = 0
        mismatches = String[]
        for device in devices
            PSY.has_time_series(device, PSY.SingleTimeSeries, "max_active_power") || continue
            duid = PSY.get_name(device)
            static_max_active_power = PSY.with_units_base(
                () -> PSY.get_max_active_power(device), sys, "NATURAL_UNITS",
            )
            series = PSY.get_time_series_values(
                PSY.SingleTimeSeries, device, "max_active_power"; ignore_scaling_factors = true,
            )
            rows = filter(:DUID => ==(duid), limits)
            by_time = Dict(zip(rows.SETTLEMENTDATE, eachrow(rows)))
            for (t, value) in zip(full_grid, series)
                row = get(by_time, t, nothing)
                isnothing(row) && continue
                expected = max(row.AVAILABILITY, row.INITIALMW - row.RAMPDOWNRATE * DISPATCH_INTERVAL_HOURS)
                checked += 1
                isapprox(value * static_max_active_power, expected; atol = 1.0e-6) ||
                    push!(mismatches, "$duid at $t: $(value * static_max_active_power) vs $expected")
            end
        end
        @test checked > 0
        @test isempty(mismatches)
    end

    template = aemsim_template(sys)
    constraints = collect(PSY.get_components(GenericConstraint, sys))
    buildable = filter_buildable_generic_constraints(sys, template; allow_partial_coverage = true)

    @testset "the pre-flight constraint check" begin
        @test_throws ArgumentError filter_buildable_generic_constraints(sys, template)
        @test !isempty(buildable)
        @test issubset(Set(PSY.get_name.(buildable)), Set(PSY.get_name.(constraints)))

        modeled = AEMS._modeled_device_types(template)
        interconnector_modeled = AEMS._interconnector_modeled(template)
        buildable_names = Set(PSY.get_name.(buildable))
        diagnoses = [
            AEMS._constraint_diagnosis(sys, gc, modeled, interconnector_modeled)
                for gc in constraints if !(PSY.get_name(gc) in buildable_names)
        ]

        @testset "every constraint term names a device in the System" begin
            @test issubset(Set(first.(diagnoses)), Set([:unsupported_bid_type, :unmodeled_device_type]))
        end

        @testset "no buildable constraint names an unavailable device" begin
            @test all(buildable) do gc
                all(term_device_names(gc)) do name
                    device = PSY.get_component(PSY.Device, sys, name)
                    return isnothing(device) || PSY.get_available(device)
                end
            end
        end
    end

    @testset "the AEMSim template builds and solves a DecisionModel" begin
        PSY.transform_single_time_series!(sys, REAL_SPAN, REAL_RESOLUTION)
        for gc in buildable
            name = PSY.get_name(gc)
            PSI.set_service_model!(
                template, name,
                PSI.ServiceModel(
                    GenericConstraint, LinearFactorLimit, name; duals = [NEMConstraintLimit],
                    use_slacks = true,
                ),
            )
        end
        model = PSI.DecisionModel(
            template, sys;
            optimizer = optimizer_with_attributes(HiGHS.Optimizer, "output_flag" => false),
            horizon = REAL_SPAN,
            resolution = REAL_RESOLUTION,
            interval = REAL_RESOLUTION,
            initial_time = REAL_START,
            name = "real_data",
        )

        build_time = @elapsed build_status = PSI.build!(model; output_dir = mktempdir())
        if build_status != PSI.ModelBuildStatus.BUILT
            err = build_error(model)
            isnothing(err) || @error "build! did not reach BUILT" exception = err
        end
        @test build_status == PSI.ModelBuildStatus.BUILT

        solve_time = @elapsed run_status = PSI.solve!(model)
        @test run_status == PSI.RunStatus.SUCCESSFULLY_FINALIZED

        container = PSI.get_optimization_container(model)
        base_power = PSY.get_base_power(sys)
        slack_keys = filter(PSI.get_variable_keys(container)) do key
            PSI.get_component_type(key) == PSY.Area && occursin("Slack", string(PSI.get_entry_type(key)))
        end
        slack_mw = Dict{Tuple{String, Int}, Float64}()
        for key in slack_keys
            var = PSI.get_variable(container, key)
            for area in axes(var, 1), t in axes(var, 2)
                slack_mw[(area, t)] = get(slack_mw, (area, t), 0.0) + PSI.JuMP.value(var[area, t]) * base_power
            end
        end
        total_area_slack_mw = sum(values(slack_mw); init = 0.0)
        @info "Real-data DecisionModel" build_time solve_time total_area_slack_mw

        @testset "elastic GenericConstraint slacks against AEMO's own published violations" begin
            base_power = PSY.get_base_power(sys)
            gc_slack_mw = Dict{String, Float64}()
            for var_type in (GenericConstraintSlackUp, GenericConstraintSlackDown)
                for key in PSI.get_variable_keys(container)
                    PSI.get_entry_type(key) === var_type && PSI.get_component_type(key) === GenericConstraint || continue
                    var = PSI.get_variable(container, key)
                    for name in axes(var, 1), t in axes(var, 2)
                        v = PSI.JuMP.value(var[name, t]) * base_power
                        gc_slack_mw[name] = get(gc_slack_mw, name, 0.0) + v
                    end
                end
            end
            nonzero_gc_slacks = Dict(n => v for (n, v) in gc_slack_mw if v > 1.0e-6)

            # AEMO's own record of which constraints were actually violated over this window
            # (VIOLATIONDEGREE > 0 <=> MARGINALVALUE priced at a CVP rate, not a market price).
            dc_table = AustralianElectricityMarketsData.read_hive(db, :DISPATCHCONSTRAINT)
            violated = DataFrame(
                DuckDB.execute(
                    db.db,
                    """
                    SELECT DISTINCT CONSTRAINTID FROM $dc_table
                    WHERE SETTLEMENTDATE BETWEEN ? AND ? AND VIOLATIONDEGREE > 0
                    """,
                    [REAL_START, REAL_START + REAL_SPAN],
                ),
            )
            violated_ids = Set(violated.CONSTRAINTID)
            nonzero_gencon_ids = Set(get_gencon_id(gc) for gc in buildable if PSY.get_name(gc) in keys(nonzero_gc_slacks))

            @info "Elastic GenericConstraint slacks" n_nonzero_slacks = length(nonzero_gc_slacks) n_aemo_violated =
                length(violated_ids) overlap = length(intersect(nonzero_gencon_ids, violated_ids)) nonzero_gc_slacks
        end
    end

    @testset "FCASMarket builds and solves alongside the constrained System" begin
        # ConstrainedNetworkConfiguration's add_fcas_services! built one FCASService per bid
        # (region, bid type), attaching only the bids FCASMarket models.
        fcas_registered = PSY.get_name.(PSY.get_components(FCASService, sys))
        n_regulation_trapeziums = 0
        n_regulation_trapeziums_scaled = 0
        n_two_sided_pairs = 0
        n_agc_disabled_pairs = 0
        both_names_by_service = Dict{BidType, Dict{String, Vector{String}}}(
            BidType.RAISEREG => Dict{String, Vector{String}}(),
            BidType.LOWERREG => Dict{String, Vector{String}}(),
        )  # bid type -> service name -> two-sided DUIDs
        horizon = Int(REAL_SPAN / REAL_RESOLUTION)
        for svc in PSY.get_components(FCASService, sys)
            bid_type = get_bid_type(svc)
            name = PSY.get_name(svc)
            # Count how many (device, t) regulation trapeziums AEMO's §4 scaling actually
            # narrowed - contingency bid types are never scaled for a scheduled unit. Also count
            # two-sided battery (device, t) pairs and how many regulation (device, t) pairs
            # AGCSTATUS = 0 disables.
            bid_type in AEM.FCAS_REGULATION_MARKETS || continue
            both_names = String[]
            for d in PSY.get_contributing_devices(sys, svc)
                direction = AEM._fcas_bid_direction(d, bid_type)
                for decremental in (direction == :both ? (false, true) : (direction == :decremental,))
                    raw = get_fcas_trapezium(d, bid_type, REAL_START, horizon; decremental = decremental)
                    scaled = get_scaled_fcas_trapezium(d, bid_type, REAL_START, horizon; decremental = decremental)
                    n_regulation_trapeziums += length(raw)
                    n_regulation_trapeziums_scaled += count(
                        i -> !isequal(Tuple(raw[i]), Tuple(scaled[i])), eachindex(raw),
                    )
                end
                direction == :both && (n_two_sided_pairs += horizon; push!(both_names, PSY.get_name(d)))

                status = get_fcas_agc_status(d, REAL_START, horizon)
                isnothing(status) || (n_agc_disabled_pairs += count(==(0), status))
            end
            both_names_by_service[bid_type][name] = both_names
        end

        @test !isempty(fcas_registered)
        # AGC telemetry is tighter than the bid for some units on any real window.
        @test n_regulation_trapeziums_scaled > 0

        fcas_template = aemsim_template(sys)
        for gc in buildable
            name = PSY.get_name(gc)
            PSI.set_service_model!(
                fcas_template, name,
                PSI.ServiceModel(GenericConstraint, LinearFactorLimit, name; duals = [NEMConstraintLimit]),
            )
        end
        for name in fcas_registered
            PSI.set_service_model!(
                fcas_template, name,
                PSI.ServiceModel(FCASService, FCASMarket, name; duals = [FCASJointCapacityConstraint]),
            )
        end
        @test isnothing(check_fcas_services(sys, fcas_template))

        fcas_model = PSI.DecisionModel(
            fcas_template, sys;
            optimizer = optimizer_with_attributes(HiGHS.Optimizer, "output_flag" => false),
            horizon = REAL_SPAN,
            resolution = REAL_RESOLUTION,
            interval = REAL_RESOLUTION,
            initial_time = REAL_START,
            name = "real_data_fcas",
        )

        build_time = @elapsed build_status = PSI.build!(fcas_model; output_dir = mktempdir())
        if build_status != PSI.ModelBuildStatus.BUILT
            err = build_error(fcas_model)
            isnothing(err) || @error "FCASMarket build! did not reach BUILT" exception = err
        end
        @test build_status == PSI.ModelBuildStatus.BUILT

        solve_time = @elapsed run_status = PSI.solve!(fcas_model)
        @test run_status == PSI.RunStatus.SUCCESSFULLY_FINALIZED

        container = PSI.get_optimization_container(fcas_model)
        n_enabled_pairs = 0
        for name in fcas_registered
            if PSI.has_container_key(container, FCASCapacityVariable, FCASService, name)
                var = PSI.get_variable(container, FCASCapacityVariable(), FCASService, name)
                n_enabled_pairs += count(k -> PSI.JuMP.upper_bound(var[k...]) > 0.0, Iterators.product(axes(var)...))
            end
            for side in ("gen", "load")
                PSI.has_container_key(container, FCASSideCapacityVariable, FCASService, "$(name)_$side") || continue
                var = PSI.get_variable(container, FCASSideCapacityVariable(), FCASService, "$(name)_$side")
                n_enabled_pairs += count(k -> PSI.JuMP.upper_bound(var[k...]) > 0.0, Iterators.product(axes(var)...))
            end
        end
        @test n_enabled_pairs > 0

        # Per-side regulation reads a battery's discharge and charge separately, so the solve
        # must not charge and discharge a battery in the same interval.
        n_circulating = 0
        if PSI.has_container_key(container, PSI.ActivePowerOutVariable, PSY.EnergyReservoirStorage)
            out_var = PSI.get_variable(container, PSI.ActivePowerOutVariable(), PSY.EnergyReservoirStorage)
            in_var = PSI.get_variable(container, PSI.ActivePowerInVariable(), PSY.EnergyReservoirStorage)
            base_power = PSY.get_base_power(sys)
            for duid in axes(out_var, 1), t in axes(out_var, 2)
                simultaneous_mw = min(PSI.JuMP.value(out_var[duid, t]), PSI.JuMP.value(in_var[duid, t])) * base_power
                simultaneous_mw > 1.0e-3 && (n_circulating += 1)
            end
        end
        @test n_circulating == 0

        # Report-only sanity check (AEMO §7): at t=1, does AEMO's five-term FCAS availability
        # formula, evaluated at the published signed TOTALCLEARED on the combined (amalgamated)
        # two-sided trapezium for a BDU, match published RAISEREG/LOWERREGACTUALAVAILABILITY?
        # Terms (1)-(3) and (5) follow §7.1 directly; term (4), the joint capacity constraint, is
        # approximated here by this build's own implied side bound(s) (further capped by §6.4
        # where attached) rather than AEMO's own per-contingency sum, since published contingency
        # targets are not read by this harness. Reported both with and without term (5), to
        # separate §6.1's own contribution from the change of metric versus the old side-bound
        # proxy this replaced (RAISEREG: 20/42).
        base_power = PSY.get_base_power(sys)

        function regulation_availability_match(bid_type, both_names_by_svc, published_t1; include_term5::Bool)
            n_cmp = 0
            n_ok = 0
            for (name, both_names) in both_names_by_svc
                isempty(both_names) && continue
                gen_var = PSI.get_variable(container, FCASSideCapacityVariable(), FCASService, "$(name)_gen")
                load_var = PSI.get_variable(container, FCASSideCapacityVariable(), FCASService, "$(name)_load")
                for duid in both_names
                    duid in axes(gen_var, 1) || continue
                    rows = filter(:DUID => ==(duid), published_t1)
                    isempty(rows) && continue
                    published = only(rows.ACTUALAVAILABILITY)
                    ismissing(published) && continue
                    energy_target = only(rows.TOTALCLEARED)
                    ismissing(energy_target) && continue

                    battery = PSY.get_component(PSY.EnergyReservoirStorage, sys, duid)
                    gen_trap = only(get_scaled_fcas_trapezium(battery, bid_type, REAL_START, 1))
                    load_trap = only(get_scaled_fcas_trapezium(battery, bid_type, REAL_START, 1; decremental = true))
                    term1 = (get_max_avail(gen_trap) + get_max_avail(load_trap)) * base_power
                    # RAISEREG: upper slope on the generation side, lower slope on the load side.
                    # LOWERREG mirrors this (§7.1's own Regulating Lower formula).
                    upper_trap, lower_trap = bid_type == BidType.RAISEREG ? (gen_trap, load_trap) : (load_trap, gen_trap)
                    upper_slope = get_upper_slope_coeff(upper_trap)
                    term2 = upper_slope > 0.0 ?
                        (get_enablement_max(upper_trap) * base_power - energy_target) / upper_slope : Inf
                    lower_slope = get_lower_slope_coeff(lower_trap)
                    term3 = lower_slope > 0.0 ?
                        (energy_target - get_enablement_min(lower_trap) * base_power) / lower_slope : Inf
                    term4 = (PSI.JuMP.upper_bound(gen_var[duid, 1]) + PSI.JuMP.upper_bound(load_var[duid, 1])) * base_power
                    terms = Float64[term1, term2, term3, term4]
                    if include_term5
                        initial_mw = only(rows.INITIALMW)
                        ramp_cap = get_fcas_agc_ramp_capability(battery, bid_type, REAL_START, 1)
                        joint_ramp = (ismissing(initial_mw) || isnothing(ramp_cap) || isnan(ramp_cap[1])) ?
                            nothing : bid_type == BidType.RAISEREG ?
                            (initial_mw + ramp_cap[1]) * base_power : (initial_mw - ramp_cap[1]) * base_power
                        term5 = isnothing(joint_ramp) ? Inf :
                            (bid_type == BidType.RAISEREG ? joint_ramp - energy_target : energy_target - joint_ramp)
                        push!(terms, term5)
                    end
                    availability = max(0.0, minimum(terms))
                    n_cmp += 1
                    isapprox(availability, published; atol = 1.0) && (n_ok += 1)
                end
            end
            return n_cmp, n_ok
        end

        reg_dispatch = filter(:BIDTYPE => in(AEM.FCAS_REGULATION_MARKETS), AEM.read_fcas_dispatch(db, REAL_DATE_RANGE))
        raisereg_t1 = filter([:SETTLEMENTDATE, :BIDTYPE] => (t, b) -> t == REAL_START && b == BidType.RAISEREG, reg_dispatch)
        lowerreg_t1 = filter([:SETTLEMENTDATE, :BIDTYPE] => (t, b) -> t == REAL_START && b == BidType.LOWERREG, reg_dispatch)
        raisereg_both_names = both_names_by_service[BidType.RAISEREG]
        lowerreg_both_names = both_names_by_service[BidType.LOWERREG]

        raise_cmp5, raise_ok5 = regulation_availability_match(BidType.RAISEREG, raisereg_both_names, raisereg_t1; include_term5 = true)
        raise_cmp4, raise_ok4 = regulation_availability_match(BidType.RAISEREG, raisereg_both_names, raisereg_t1; include_term5 = false)
        lower_cmp5, lower_ok5 = regulation_availability_match(BidType.LOWERREG, lowerreg_both_names, lowerreg_t1; include_term5 = true)
        lower_cmp4, lower_ok4 = regulation_availability_match(BidType.LOWERREG, lowerreg_both_names, lowerreg_t1; include_term5 = false)
        raisereg_match_rate = raise_cmp5 > 0 ? raise_ok5 / raise_cmp5 : NaN
        raisereg_match_rate_no_term5 = raise_cmp4 > 0 ? raise_ok4 / raise_cmp4 : NaN
        lowerreg_match_rate = lower_cmp5 > 0 ? lower_ok5 / lower_cmp5 : NaN
        lowerreg_match_rate_no_term5 = lower_cmp4 > 0 ? lower_ok4 / lower_cmp4 : NaN

        @info "Real-data FCASMarket DecisionModel" build_time solve_time n_services = length(fcas_registered) n_enabled_pairs n_regulation_trapeziums_scaled n_regulation_trapeziums n_two_sided_pairs n_agc_disabled_pairs raise_cmp5 raise_ok5 raisereg_match_rate raisereg_match_rate_no_term5 lower_cmp5 lower_ok5 lowerreg_match_rate lowerreg_match_rate_no_term5

        # AEMO §6.1 fidelity: evaluate every non-placeholder FCASJointRampingConstraint row this
        # build actually constructs (both RAISEREG and LOWERREG services, generators and
        # storage), at NEMDE's own published solution (TOTALCLEARED and the published regulation
        # TARGET), against the row's own right-hand side - this build's InitialMW and ramp
        # capability, read straight off the built JuMP constraint rather than recomputed.
        published_lookup = Dict(
            (row.BIDTYPE, row.DUID, row.SETTLEMENTDATE) => row for row in eachrow(reg_dispatch)
        )
        joint_ramping_rows = NamedTuple[]
        for svc in PSY.get_components(FCASService, sys)
            bid_type = get_bid_type(svc)
            bid_type in AEM.FCAS_REGULATION_MARKETS || continue
            name = PSY.get_name(svc)
            PSI.has_container_key(container, FCASJointRampingConstraint, FCASService, name) || continue
            con = PSI.get_constraint(container, FCASJointRampingConstraint(), FCASService, name)
            devices_by_name = Dict(PSY.get_name(d) => d for d in PSY.get_contributing_devices(sys, svc))
            for duid in axes(con, 1), t in axes(con, 2)
                row = PSI.JuMP.constraint_object(con[duid, t])
                isempty(row.func.terms) && continue  # gated placeholder: nothing to check
                settlement = REAL_START + (t - 1) * REAL_RESOLUTION
                haskey(published_lookup, (bid_type, duid, settlement)) || continue
                prow = published_lookup[(bid_type, duid, settlement)]
                (ismissing(prow.TOTALCLEARED) || ismissing(prow.TARGET) || ismissing(prow.INITIALMW)) && continue

                energy_mw = prow.TOTALCLEARED
                target_mw = prow.TARGET
                initial_mw = prow.INITIALMW
                if bid_type == BidType.RAISEREG
                    lhs_mw = energy_mw + target_mw
                    rhs_mw = row.set.upper * base_power
                    diff_mw = lhs_mw - rhs_mw
                    violated = diff_mw > 1.0
                    ramp_cap_mw = rhs_mw - initial_mw
                else
                    lhs_mw = energy_mw - target_mw
                    rhs_mw = row.set.lower * base_power
                    diff_mw = lhs_mw - rhs_mw
                    violated = diff_mw < -1.0
                    ramp_cap_mw = initial_mw - rhs_mw
                end
                device = devices_by_name[duid]
                # Whether the unit's own energy ramp already sits at the bid-capped floor this
                # build's `InitialMW + RampUp`/`InitialMW - RampDown` gives, with zero headroom
                # left for the published regulation target - the signature of the row's known
                # departure (DISPATCHLOAD's bid-capped ramp rate standing in for the unpublished
                # telemetered SCADA rate).
                energy_at_own_ramp_floor = isapprox(
                    energy_mw, bid_type == BidType.RAISEREG ? initial_mw + ramp_cap_mw : initial_mw - ramp_cap_mw;
                    atol = 1.0,
                )
                push!(
                    joint_ramping_rows,
                    (;
                        service = name, bid_type, duid, device_type = nameof(typeof(device)),
                        settlement, initial_mw, energy_mw, target_mw, ramp_cap_mw,
                        lhs_mw, rhs_mw, diff_mw, violated,
                        agc_status = prow.AGCSTATUS, energy_at_own_ramp_floor,
                    ),
                )
            end
        end
        n_joint_ramping_rows = length(joint_ramping_rows)
        violations = filter(r -> r.violated, joint_ramping_rows)
        n_joint_ramping_violations = length(violations)

        n_ramp_floor_violations = count(r -> r.energy_at_own_ramp_floor, violations)
        n_unexplained_violations = n_joint_ramping_violations - n_ramp_floor_violations
        if !isempty(violations)
            println("§6.1 fidelity violations at the published solution ($(n_joint_ramping_violations)/$(n_joint_ramping_rows)):")
            println(
                rpad("service", 22), rpad("duid", 12), rpad("type", 22), rpad("bidtype", 10),
                rpad("initial_mw", 11), rpad("energy_mw", 10), rpad("target_mw", 10),
                rpad("ramp_mw", 9), rpad("diff_mw", 9), rpad("agc", 4), "at_ramp_floor",
            )
            for r in violations
                agc = ismissing(r.agc_status) ? "?" : string(r.agc_status)
                println(
                    rpad(r.service, 22), rpad(r.duid, 12), rpad(string(r.device_type), 22), rpad(string(r.bid_type), 10),
                    rpad(string(round(r.initial_mw; digits = 1)), 11), rpad(string(round(r.energy_mw; digits = 1)), 10),
                    rpad(string(round(r.target_mw; digits = 1)), 10), rpad(string(round(r.ramp_cap_mw; digits = 1)), 9),
                    rpad(string(round(r.diff_mw; digits = 1)), 9), rpad(agc, 4), r.energy_at_own_ramp_floor,
                )
            end
        end
        @info "§6.1 fidelity" n_joint_ramping_rows n_joint_ramping_violations n_ramp_floor_violations n_unexplained_violations

        # On 2026-06-04 all 10 violations (out of 1520 rows) are VIC1's LYA2 (a large coal
        # ThermalStandard) over ten consecutive LOWERREG intervals while it ramps down at exactly
        # its bid-capped RAMPDOWNRATE floor (TOTALCLEARED == InitialMW - RampDown·Delta each
        # time, confirmed above), yet still carries a small published LOWERREG target. A battery
        # crossing zero (checked, zero found) is not the cause here; a continuously-ramping
        # generator with no energy headroom left under the bid-capped rate is exactly the
        # documented departure - DISPATCHLOAD's RAMPDOWNRATE is "lesser of bid or telemetered", so
        # our row is tighter than NEMDE's true telemetered-rate row whenever the bid rate binds
        # every interval. No other category (fast start, intervention, AGC-disabled, or a
        # units/time-basis mismatch) appears in this window.
        @test n_unexplained_violations == 0
    end
end
