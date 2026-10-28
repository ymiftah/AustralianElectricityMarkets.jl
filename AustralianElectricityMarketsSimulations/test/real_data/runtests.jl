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

const VIOLATION_START = DateTime(2026, 6, 9, 5, 0)
const VIOLATION_SPAN = Hour(1)
const VIOLATION_DATE_RANGE = VIOLATION_START:REAL_RESOLUTION:(VIOLATION_START + VIOLATION_SPAN)

# Either table carries the dispatch FCAS requirements, depending on the archive month.
const FCAS_REQ_TABLES = (:DISPATCH_FCAS_REQ, :DISPATCH_FCAS_REQ_CONSTRAINT)

const db = aem_connect(HiveConfiguration(hive_location = REAL_HIVE))

function month_cached(table)
    root = AEM._parse_hive_root(db.config)
    glob = "$root/$table/archive_month=$REAL_MONTH/*.parquet"
    return only(DataFrame(DuckDB.execute(db.db, "SELECT COUNT(*) AS n FROM glob('$glob')")).n) > 0
end

let
    required = union(
        AEM.table_requirements(NEMDEConfiguration()),
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

# Builds and solves `model`, asserting each reaches its terminal status; returns the build and solve times in seconds.
function build_and_solve!(model)
    build_time = @elapsed build_status = PSI.build!(model; output_dir = mktempdir())
    if build_status != PSI.ModelBuildStatus.BUILT
        err = build_error(model)
        isnothing(err) || @error "build! did not reach BUILT" exception = err
    end
    @test build_status == PSI.ModelBuildStatus.BUILT
    solve_time = @elapsed run_status = PSI.solve!(model)
    @test run_status == PSI.RunStatus.SUCCESSFULLY_FINALIZED
    return (; build_time, solve_time)
end

function term_device_names(gc; energy_only::Bool = false)
    names = String[]
    for term in get_terms(gc)
        energy_only && term isa Union{UnitTerm, RegionTerm} && get_bid_type(term) != BidType.ENERGY && continue
        term isa UnitTerm && push!(names, get_duid(term))
        term isa RegionTerm && append!(names, get_devices(term))
    end
    return names
end

@testset "Real NEM data, $(Date(REAL_START))" begin
    sys, _ = AEM.RegionModel._constrained_system(db; date_range = REAL_DATE_RANGE)

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
    devices = AEM.nem_dispatch_devices(sys)

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
            d -> !PSY.get_available(d) || AEMS._has_nem_dispatch_limits(d),
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
                row.RAMPUPRATE * interval_hours(DISPATCH_INTERVAL) / PSY.get_base_power(sys) rtol = 1.0e-9
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
                expected = max(row.AVAILABILITY, row.INITIALMW - row.RAMPDOWNRATE * interval_hours(DISPATCH_INTERVAL))
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
    buildable = AEMS._filter_buildable_generic_constraints(
        sys, template, constraints; allow_partial_coverage = true,
    )

    @testset "the pre-flight constraint check" begin
        @test_throws ArgumentError AEMS._filter_buildable_generic_constraints(
            sys, template, constraints,
        )
        @test !isempty(buildable)
        @test issubset(Set(PSY.get_name.(buildable)), Set(PSY.get_name.(constraints)))

        modeled = AEMS._modeled_device_types(template)
        interconnector_modeled = AEMS._interconnector_modeled(template)
        buildable_names = Set(PSY.get_name.(buildable))
        diagnoses = [
            AEMS._constraint_diagnosis(sys, gc, modeled, interconnector_modeled, AEMS._modeled_fcas_services(template))
                for gc in constraints if !(PSY.get_name(gc) in buildable_names)
        ]

        @testset "every constraint term names a device in the System" begin
            @test issubset(Set(first.(diagnoses)), Set([:unmodeled_fcas_service, :unmodeled_device_type]))
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

        build_time, solve_time = build_and_solve!(model)

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

    @testset "interconnector loss gap and regional price signs" begin
        # NEMInterconnectorLoss in place of the main model's lossless StaticBranch; the solved loss
        # is compared with the breakpoint interpolation at the same solved flow.
        loss_template = aemsim_template(sys)
        PSI.set_device_model!(loss_template, PSY.AreaInterchange, NEMInterconnectorLoss)
        loss_model = PSI.DecisionModel(
            loss_template, sys;
            optimizer = optimizer_with_attributes(
                HiGHS.Optimizer, "output_flag" => false, "mip_rel_gap" => 0.0, "mip_abs_gap" => 1.0e-10,
            ),
            horizon = REAL_SPAN,
            resolution = REAL_RESOLUTION,
            interval = REAL_RESOLUTION,
            initial_time = REAL_START,
            name = "real_data_losses",
        )
        build_and_solve!(loss_model)

        loss_res = PSI.OptimizationProblemResults(loss_model)
        gaps = check_interconnector_loss_segments(loss_res, sys; tolerance = 1.0e-3)
        timestamps = collect(REAL_DATE_RANGE)[1:(end - 1)]

        # Weighted marginal price of a unit of loss: share * price_from + (1 - share) * price_to.
        # The contiguous-fill encoding is exact at any sign of this price.
        dual_df = PSI.read_dual(loss_res, "CopperPlateBalanceConstraint__Area")
        price = Dict((r.name, r.DateTime) => r.value for r in eachrow(dual_df))
        weighted_price = Dict{Tuple{String, Int}, Float64}()
        for ic in PSY.get_components(PSY.AreaInterchange, sys)
            models = PSY.get_supplemental_attributes(InterconnectorLossModel, ic)
            length(models) == 1 || continue
            model = only(models)
            for (t, stamp) in enumerate(timestamps)
                pf = get(price, (model.from_region, stamp), NaN)
                pt = get(price, (model.to_region, stamp), NaN)
                weighted_price[(PSY.get_name(ic), t)] =
                    model.from_region_loss_share * pf + (1 - model.from_region_loss_share) * pt
            end
        end

        @test !isempty(gaps)
        # Negative weighted prices included, loss must stay on the curve at the solved flow.
        @test all(abs(gap) < 1.0e-3 for gap in values(gaps))

        names = sort(unique(first.(keys(gaps))))
        report = join(
            [
                "$n: max|gap| $(round(maximum(abs(gaps[(n, t)]) for t in eachindex(timestamps)); digits = 4)) MW, " *
                    "t1 weighted price $(weighted_price[(n, 1)] >= 0 ? "non-negative" : "NEGATIVE"), " *
                    "$(count(t -> weighted_price[(n, t)] < 0, eachindex(timestamps))) negative interval(s)"
                    for n in names
            ], "; ",
        )
        @info "Interconnector over-dissipation gap (solved LP loss - curve at solved flow) and weighted price sign" report
    end

    @testset "FCASMarket builds and solves alongside the constrained System" begin
        # The constrained layer's add_fcas_services! built one FCASService per bid
        # (region, bid type), attaching only the bids FCASMarket models.
        fcas_registered = PSY.get_name.(PSY.get_components(FCASService, sys))
        n_regulation_trapeziums = 0
        n_regulation_trapeziums_scaled = 0
        horizon = Int(REAL_SPAN / REAL_RESOLUTION)
        for svc in PSY.get_components(FCASService, sys)
            bid_type = get_bid_type(svc)
            name = PSY.get_name(svc)
            # Count how many (device, t) regulation trapeziums AEMO's §4 scaling actually
            # narrowed - contingency bid types are never scaled for a scheduled unit.
            bid_type in AEM.FCAS_REGULATION_MARKETS || continue
            for d in PSY.get_contributing_devices(sys, svc)
                direction = AEM.fcas_bid_direction(d, bid_type)
                for decremental in (direction == FCASBidDirection.BOTH ? (false, true) : (direction == FCASBidDirection.DECREMENTAL,))
                    raw = AustralianElectricityMarkets._get_fcas_trapezium(d, bid_type, REAL_START, horizon; decremental = decremental)
                    scaled = get_scaled_fcas_trapezium(d, bid_type, REAL_START, horizon; decremental = decremental)
                    n_regulation_trapeziums += length(raw)
                    n_regulation_trapeziums_scaled += count(
                        i -> !isequal(Tuple(raw[i]), Tuple(scaled[i])), eachindex(raw),
                    )
                end
            end
        end

        @test !isempty(fcas_registered)
        # AGC telemetry is tighter than the bid for some units on any real window.
        @test n_regulation_trapeziums_scaled > 0

        fcas_template = aemsim_template(sys)
        for name in fcas_registered
            PSI.set_service_model!(
                fcas_template, name,
                PSI.ServiceModel(FCASService, FCASMarket, name; duals = [FCASJointCapacityConstraint], use_slacks = true),
            )
        end
        # Buildable against this template, so constraints with FCAS terms are in play.
        fcas_buildable = AEMS._filter_buildable_generic_constraints(
            sys, fcas_template, PSY.get_components(GenericConstraint, sys); allow_partial_coverage = true,
        )
        n_fcas_constraints = count(gc -> !isempty(get_fcas_requirements(gc)), fcas_buildable)
        for gc in fcas_buildable
            name = PSY.get_name(gc)
            PSI.set_service_model!(
                fcas_template, name,
                PSI.ServiceModel(
                    GenericConstraint, LinearFactorLimit, name; duals = [NEMConstraintLimit], use_slacks = true,
                ),
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

        build_time, solve_time = build_and_solve!(fcas_model)

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

        @info "Real-data FCASMarket DecisionModel" build_time solve_time n_services = length(fcas_registered) n_enabled_pairs n_regulation_trapeziums_scaled n_regulation_trapeziums

        # Report-only: the FCAS prices this solve's constraint duals imply, against AEMO's published
        # ROP (the sum of the requirement constraints' MARGINALVALUE) per (region, service, interval).
        fcas_prices = compute_fcas_prices(PSI.OptimizationProblemResults(fcas_model), sys)
        published_prices = AEM.read_fcas_prices(db, REAL_DATE_RANGE)
        compared = innerjoin(fcas_prices, published_prices; on = [:SETTLEMENTDATE, :REGIONID, :BIDTYPE], makeunique = true)
        n_price_cmp = nrow(compared)
        n_price_ok = count(r -> isapprox(r.ROP, r.ROP_1; atol = 0.5, rtol = 0.01), eachrow(compared))
        fcas_price_match_rate = n_price_cmp > 0 ? n_price_ok / n_price_cmp : NaN
        @info "Real-data FCAS prices from constraint duals vs published ROP" n_fcas_constraints n_price_cmp n_price_ok fcas_price_match_rate
        @test n_price_cmp > 0

        reg_dispatch = filter(:BIDTYPE => in(AEM.FCAS_REGULATION_MARKETS), AEM.read_fcas_dispatch(db, REAL_DATE_RANGE))

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

@testset "Elastic GenericConstraint slack matches AEMO's published violation, $(Date(VIOLATION_START))" begin
    sys, _ = AEM.RegionModel._constrained_system(db; date_range = VIOLATION_DATE_RANGE)
    set_demand!(sys, db, VIOLATION_DATE_RANGE; resolution = REAL_RESOLUTION)
    set_market_bids!(sys, db, VIOLATION_DATE_RANGE; resolution = REAL_RESOLUTION)
    set_nem_dispatch_limits!(sys, db, VIOLATION_DATE_RANGE)
    PSY.transform_single_time_series!(sys, VIOLATION_SPAN, REAL_RESOLUTION)

    target_gencon_ids = ("Q_STR_ALDSF_ZERO", "Q_BRDDSF01_1INV")
    gcs = [gc for gc in PSY.get_components(GenericConstraint, sys) if get_gencon_id(gc) in target_gencon_ids]
    @test length(gcs) == length(target_gencon_ids)

    template = aemsim_template(sys)
    for gc in gcs
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
        horizon = VIOLATION_SPAN,
        resolution = REAL_RESOLUTION,
        interval = REAL_RESOLUTION,
        initial_time = VIOLATION_START,
        name = "real_data_violation",
    )

    build_and_solve!(model)

    results = PSI.OptimizationProblemResults(model)
    base_power = PSY.get_base_power(sys)

    dc_table = AustralianElectricityMarkets.Readers.read_hive(db, :DISPATCHCONSTRAINT)
    for gc in gcs
        name = PSY.get_name(gc)
        gencon_id = get_gencon_id(gc)
        var_type = get_sense(gc) == ConstraintSense.LE ? "GenericConstraintSlackUp" : "GenericConstraintSlackDown"
        slack_df = PSI.read_variable(results, "$(var_type)__GenericConstraint__$name")
        dual_df = PSI.read_dual(results, "NEMConstraintLimit__GenericConstraint__$name")
        invoked_timestamps = PSY.get_time_series_timestamps(
            PSY.SingleTimeSeries, gc, "invoked";
            start_time = VIOLATION_START, len = nrow(slack_df),
        )
        invoked_values = PSY.get_time_series_values(
            PSY.SingleTimeSeries, gc, "invoked";
            start_time = VIOLATION_START, len = nrow(slack_df),
        )
        @test length(invoked_values) == nrow(slack_df)
        @test invoked_timestamps == slack_df.DateTime
        @test invoked_timestamps == dual_df.DateTime
        invoked_df = DataFrame(DateTime = invoked_timestamps, invoked = invoked_values .> 0.0)
        invoked_slack = innerjoin(slack_df, invoked_df; on = :DateTime, validate = (true, true))
        @test nrow(invoked_slack) == nrow(slack_df)
        @test any(.!invoked_slack.invoked)
        @test all(abs.(invoked_slack.value[.!invoked_slack.invoked]) .<= 1.0e-6)
        invoked_slack = subset(invoked_slack, :invoked => ByRow(identity))

        published = DataFrame(
            DuckDB.execute(
                db.db,
                """
                SELECT SETTLEMENTDATE, VIOLATIONDEGREE, MARGINALVALUE FROM $dc_table
                WHERE CONSTRAINTID = ? AND SETTLEMENTDATE BETWEEN ? AND ? AND INTERVENTION = 0
                ORDER BY SETTLEMENTDATE
                """,
                [gencon_id, VIOLATION_START, VIOLATION_START + VIOLATION_SPAN],
            ),
        )
        invoked_dates = invoked_timestamps[invoked_values .> 0.0]
        published_invoked = subset(published, :SETTLEMENTDATE => ByRow(in(invoked_dates)))
        @test Set(published_invoked.SETTLEMENTDATE) == Set(invoked_dates)
        @test nrow(published_invoked) == length(invoked_dates)
        comparison = innerjoin(
            invoked_slack, select(published_invoked, :SETTLEMENTDATE => :DateTime, :VIOLATIONDEGREE, :MARGINALVALUE);
            on = :DateTime, validate = (true, true),
        )
        comparison = innerjoin(
            comparison, select(dual_df, :DateTime, :value => :dual);
            on = :DateTime, validate = (true, true),
        )
        @test nrow(comparison) == length(invoked_dates)
        @test any(v -> v > 0.0, comparison.value)
        @test any(v -> v > 0.0, comparison.VIOLATIONDEGREE)
        # slack_df.value is already natural-unit MW (GenericConstraintSlackUp/Down convert on
        # read); dual_df.value is left in $ per pu of RHS per interval by PSI, so divide by
        # base_power and the interval length for a $/MW comparison against AEMO's MARGINALVALUE.
        @test all(isapprox.(comparison.value, comparison.VIOLATIONDEGREE; atol = 1.0e-6))
        violated = subset(comparison, :VIOLATIONDEGREE => ByRow(>(1.0e-6)))
        @test nrow(violated) > 0
        @test all(
            isapprox.(
                abs.(violated.dual) ./ (base_power * interval_hours(REAL_RESOLUTION)),
                abs.(violated.MARGINALVALUE); rtol = 1.0e-6,
            )
        )
    end

    @testset "interconnector losses: published MWFLOW -> modelled loss vs published MWLOSSES" begin
        # Direct curve evaluation, no LP: isolates the loss model from dispatch. Each
        # AreaInterchange's own attached model is used (already per-unit, so undone to MW below).
        table = read_hive(db, :DISPATCHINTERCONNECTORRES)
        flows_losses = AEM._query(
            db,
            """
            SELECT SETTLEMENTDATE, INTERCONNECTORID,
                   TRY_CAST(MWFLOW AS DOUBLE) AS MWFLOW, TRY_CAST(MWLOSSES AS DOUBLE) AS MWLOSSES
            FROM $table
            WHERE SETTLEMENTDATE >= ? AND SETTLEMENTDATE <= ? AND INTERVENTION = 0
            QUALIFY row_number() OVER (
                PARTITION BY SETTLEMENTDATE, INTERCONNECTORID ORDER BY archive_month DESC
            ) = 1
            """,
            [REAL_START, last(REAL_DATE_RANGE)],
        )
        filter!(row -> !ismissing(row.MWFLOW) && !ismissing(row.MWLOSSES), flows_losses)

        # Two demand definitions: this package's TOTALDEMAND, and nempy's INITIALSUPPLY +
        # DEMANDFORECAST. Keyed by `t.SETTLEMENTDATE`: a GroupKey never equals a DateTime.
        region_sum = read_hive(db, :DISPATCHREGIONSUM)
        demand_rows = AEM._query(
            db,
            """
            SELECT SETTLEMENTDATE, REGIONID,
                   TRY_CAST(TOTALDEMAND AS DOUBLE) AS TOTALDEMAND,
                   TRY_CAST(INITIALSUPPLY AS DOUBLE) + TRY_CAST(DEMANDFORECAST AS DOUBLE) AS NEMPY_DEMAND
            FROM $region_sum
            WHERE SETTLEMENTDATE >= ? AND SETTLEMENTDATE <= ? AND INTERVENTION = 0
            QUALIFY row_number() OVER (
                PARTITION BY SETTLEMENTDATE, REGIONID ORDER BY archive_month DESC
            ) = 1
            """,
            [REAL_START, last(REAL_DATE_RANGE)],
        )
        demand_by_time(column) = Dict(
            key.SETTLEMENTDATE => Dict(
                r.REGIONID => r[column] for r in eachrow(rows) if !ismissing(r[column])
            )
                for (key, rows) in pairs(groupby(demand_rows, :SETTLEMENTDATE))
        )
        demands = ("TOTALDEMAND" => demand_by_time(:TOTALDEMAND), "INITIALSUPPLY+DEMANDFORECAST" => demand_by_time(:NEMPY_DEMAND))
        @test !isempty(last(first(demands)))

        base_power = PSY.get_base_power(sys)
        reports = String[]
        for (label, demand_lookup) in demands
            abs_errors = Float64[]
            per_ic_errors = Dict{String, Vector{Float64}}()
            for row in eachrow(flows_losses)
                ic = PSY.get_component(PSY.AreaInterchange, sys, row.INTERCONNECTORID)
                isnothing(ic) && continue
                models = PSY.get_supplemental_attributes(InterconnectorLossModel, ic)
                length(models) == 1 || continue
                model_mw = AEM._to_pu(only(models), 1.0 / base_power)
                demand = get(demand_lookup, row.SETTLEMENTDATE, Dict{String, Float64}())
                err = abs(interconnector_losses(model_mw, row.MWFLOW, demand) - row.MWLOSSES)
                push!(abs_errors, err)
                push!(get!(() -> Float64[], per_ic_errors, row.INTERCONNECTORID), err)
            end
            @test !isempty(abs_errors)
            per_ic = join(
                ["$ic $(round(sum(e) / length(e); digits = 3))" for (ic, e) in sort(collect(per_ic_errors))], ", ",
            )
            push!(
                reports,
                "[$label] n=$(length(abs_errors)) mean|err| $(round(sum(abs_errors) / length(abs_errors); digits = 3)) MW, " *
                    "max|err| $(round(maximum(abs_errors); digits = 3)) MW; per-interconnector mean|err| MW: $per_ic",
            )
        end
        @info "Interconnector loss comparison (published MWFLOW -> modelled loss vs published MWLOSSES)" report = join(reports, "\n")
    end
end
