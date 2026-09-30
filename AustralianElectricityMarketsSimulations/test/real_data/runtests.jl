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
                PSI.ServiceModel(GenericConstraint, LinearFactorLimit, name; duals = [NEMConstraintLimit]),
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
    end

    @testset "interconnector over-dissipation gap and regional price signs" begin
        # NEMInterconnectorLoss in place of the main model's lossless StaticBranch, so the LP
        # actually allocates loss segments - the self-consistency check ADR-0022 asks for: does
        # the LP's own InterconnectorLossVariable at the solved flow match interconnector_losses
        # evaluated at that same flow (both natural MW), or has the LP over-dissipated?
        loss_template = aemsim_template(sys)
        PSI.set_device_model!(loss_template, PSY.AreaInterchange, NEMInterconnectorLoss)
        loss_model = PSI.DecisionModel(
            loss_template, sys;
            optimizer = optimizer_with_attributes(HiGHS.Optimizer, "output_flag" => false),
            horizon = REAL_SPAN,
            resolution = REAL_RESOLUTION,
            interval = REAL_RESOLUTION,
            initial_time = REAL_START,
            name = "real_data_losses",
        )
        build_status = PSI.build!(loss_model; output_dir = mktempdir())
        if build_status != PSI.ModelBuildStatus.BUILT
            err = build_error(loss_model)
            isnothing(err) || @error "NEMInterconnectorLoss build! did not reach BUILT" exception = err
        end
        @test build_status == PSI.ModelBuildStatus.BUILT
        run_status = PSI.solve!(loss_model)
        @test run_status == PSI.RunStatus.SUCCESSFULLY_FINALIZED

        loss_res = PSI.OptimizationProblemResults(loss_model)
        flow_df = PSI.read_variable(loss_res, "FlowActivePowerVariable__AreaInterchange")
        loss_df = PSI.read_variable(loss_res, "InterconnectorLossVariable__AreaInterchange")
        demand_df2 = read_demand(db; resolution = REAL_RESOLUTION)
        demand_by_time2 = Dict(
            t => Dict(r.REGIONID => r.TOTALDEMAND for r in eachrow(rows))
                for (t, rows) in pairs(groupby(demand_df2, :SETTLEMENTDATE))
        )
        base_power2 = PSY.get_base_power(sys)
        over_dissipation_mw = Dict{String, Float64}()
        for ic in PSY.get_components(PSY.AreaInterchange, sys)
            name = PSY.get_name(ic)
            flow_rows = subset(flow_df, :name => ByRow(==(name)))
            isempty(flow_rows) && continue
            loss_rows = subset(loss_df, :name => ByRow(==(name)))
            models = PSY.get_supplemental_attributes(InterconnectorLossModel, ic)
            length(models) == 1 || continue
            model_mw = AEM._to_pu(only(models), 1.0 / base_power2)
            t1_row_flow = first(sort(flow_rows, :DateTime))
            t1_row_loss = first(sort(loss_rows, :DateTime))
            demand = get(demand_by_time2, t1_row_flow.DateTime, Dict{String, Float64}())
            curve_loss = interconnector_losses(model_mw, t1_row_flow.value, demand)
            over_dissipation_mw[name] = t1_row_loss.value - curve_loss
        end

        # Each region's solved price sign at t1 - context for whether over-dissipation had a
        # negative-price incentive to exploit at all.
        dual_df = PSI.read_dual(loss_res, "CopperPlateBalanceConstraint__Area")
        price_sign = Dict(
            r.name => sign(r.value)
                for r in eachrow(subset(dual_df, :DateTime => ByRow(==(REAL_START))))
        )

        over_dissipation_report = join(
            ["$ic: $(round(gap; digits = 5)) MW" for (ic, gap) in sort(collect(over_dissipation_mw))],
            ", ",
        )
        price_sign_report = join(
            ["$region: $(sign_value > 0 ? "positive" : sign_value < 0 ? "negative" : "zero")" for (region, sign_value) in sort(collect(price_sign))],
            ", ",
        )
        @info "Interconnector over-dissipation gap (LP loss - curve loss at solved flow, MW) and regional price signs" over_dissipation_report price_sign_report
    end

    @testset "FCASMarket builds and solves alongside the constrained System" begin
        # ConstrainedNetworkConfiguration's add_fcas_services! built one FCASService per bid
        # (region, bid type), attaching only the bids FCASMarket models.
        fcas_registered = PSY.get_name.(PSY.get_components(FCASService, sys))
        n_regulation_trapeziums = 0
        n_regulation_trapeziums_scaled = 0
        n_two_sided_pairs = 0
        n_agc_disabled_pairs = 0
        raisereg_both_names = Dict{String, Vector{String}}()  # service name -> two-sided DUIDs
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
            bid_type == BidType.RAISEREG && (raisereg_both_names[name] = both_names)
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

        # Aggregate, report-only sanity check: at t=1, does this build's implied upper bound on
        # each battery's total RAISEREG target (its own side bound(s), further capped by the
        # §6.4 SCADA ramping constraint where attached) match AEMO's published
        # RAISEREGACTUALAVAILABILITY? Not asserted - §6.1 joint ramping is not modelled, so a
        # mismatch is expected wherever it would have bound the real dispatch.
        raisereg_dispatch = filter(
            :BIDTYPE => ==(BidType.RAISEREG), AEM.read_fcas_dispatch(db, REAL_DATE_RANGE),
        )
        raisereg_t1 = filter(:SETTLEMENTDATE => ==(REAL_START), raisereg_dispatch)
        n_compared = 0
        n_matched = 0
        for (name, both_names) in raisereg_both_names
            isempty(both_names) && continue
            PSI.has_container_key(container, FCASBDURampingConstraint, FCASService, name) || continue
            gen_var = PSI.get_variable(container, FCASSideCapacityVariable(), FCASService, "$(name)_gen")
            load_var = PSI.get_variable(container, FCASSideCapacityVariable(), FCASService, "$(name)_load")
            for duid in both_names
                duid in axes(gen_var, 1) || continue
                published_rows = filter(:DUID => ==(duid), raisereg_t1)
                isempty(published_rows) && continue
                published = only(published_rows.ACTUALAVAILABILITY)
                ismissing(published) && continue
                bound = PSI.JuMP.upper_bound(gen_var[duid, 1]) + PSI.JuMP.upper_bound(load_var[duid, 1])
                ramp_cap = get_fcas_agc_ramp_capability(
                    PSY.get_component(PSY.EnergyReservoirStorage, sys, duid), BidType.RAISEREG, REAL_START, 1,
                )
                isnothing(ramp_cap) || isnan(ramp_cap[1]) || iszero(ramp_cap[1]) || (bound = min(bound, ramp_cap[1]))
                bound *= PSY.get_base_power(sys)
                n_compared += 1
                isapprox(bound, published; atol = 1.0) && (n_matched += 1)
            end
        end
        raisereg_match_rate = n_compared > 0 ? n_matched / n_compared : NaN

        @info "Real-data FCASMarket DecisionModel" build_time solve_time n_services = length(fcas_registered) n_enabled_pairs n_regulation_trapeziums_scaled n_regulation_trapeziums n_two_sided_pairs n_agc_disabled_pairs n_compared n_matched raisereg_match_rate
    end

    @testset "interconnector losses: published MWFLOW -> modelled loss vs published MWLOSSES" begin
        # Direct curve evaluation, no LP: isolates the loss model (InterconnectorLossModel,
        # root package) from dispatch. ConstrainedNetworkConfiguration already ran
        # attach_interconnector_losses!, so read each AreaInterchange's own attached model
        # rather than a second `interconnector_loss_models` call.
        table = read_hive(db, :DISPATCHINTERCONNECTORRES)
        flows_losses = AEM._query(
            db,
            """
            SELECT SETTLEMENTDATE, INTERCONNECTORID,
                   TRY_CAST(MWFLOW AS DOUBLE) AS MWFLOW, TRY_CAST(MWLOSSES AS DOUBLE) AS MWLOSSES
            FROM $table
            WHERE SETTLEMENTDATE >= ? AND SETTLEMENTDATE <= ?
            QUALIFY row_number() OVER (
                PARTITION BY SETTLEMENTDATE, INTERCONNECTORID ORDER BY archive_month DESC
            ) = 1
            """,
            [REAL_START, last(REAL_DATE_RANGE)],
        )
        filter!(row -> !ismissing(row.MWFLOW) && !ismissing(row.MWLOSSES), flows_losses)

        demand_df = read_demand(db; resolution = REAL_RESOLUTION)
        demand_by_time = Dict(
            t => Dict(r.REGIONID => r.TOTALDEMAND for r in eachrow(rows))
                for (t, rows) in pairs(groupby(demand_df, :SETTLEMENTDATE))
        )

        base_power = PSY.get_base_power(sys)
        n_compared = 0
        abs_errors = Float64[]
        per_ic_errors = Dict{String, Vector{Float64}}()
        for row in eachrow(flows_losses)
            ic = PSY.get_component(PSY.AreaInterchange, sys, row.INTERCONNECTORID)
            isnothing(ic) && continue
            models = PSY.get_supplemental_attributes(InterconnectorLossModel, ic)
            length(models) == 1 || continue
            model_mw = AEM._to_pu(only(models), 1.0 / base_power)  # undo attach_interconnector_losses!'s pu scaling
            demand = get(demand_by_time, row.SETTLEMENTDATE, Dict{String, Float64}())
            modelled = interconnector_losses(model_mw, row.MWFLOW, demand)
            err = abs(modelled - row.MWLOSSES)
            push!(abs_errors, err)
            push!(get!(() -> Float64[], per_ic_errors, row.INTERCONNECTORID), err)
            n_compared += 1
        end

        @test n_compared > 0
        mean_abs_error_mw = isempty(abs_errors) ? NaN : sum(abs_errors) / length(abs_errors)
        max_abs_error_mw = isempty(abs_errors) ? NaN : maximum(abs_errors)
        per_ic_mean_error_mw = Dict(
            ic => sum(errs) / length(errs) for (ic, errs) in per_ic_errors
        )
        per_ic_report = join(
            ["$ic: $(round(err; digits = 3)) MW" for (ic, err) in sort(collect(per_ic_mean_error_mw))],
            ", ",
        )
        @info "Interconnector loss comparison (published MWFLOW -> modelled loss vs published MWLOSSES)" n_compared mean_abs_error_mw max_abs_error_mw per_ic_report
    end
end
