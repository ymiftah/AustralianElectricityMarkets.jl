# Integration tests against real AEMO data from a local NEMWEB hive cache. Not part of
# `Pkg.test`, and not run in CI. From the repository root:
#
#     julia --project=AustralianElectricityMarketsSimulations/test \
#         AustralianElectricityMarketsSimulations/test/real_data/runtests.jl [hive_location]
#
# `hive_location` defaults to `~/.nemdb_cache`.
#
# Every solve goes through the replay API. Data AEMO did not publish (a unit without a DISPATCHLOAD
# row, a constraint without rows) is left out of the comparisons and reported with `@info`.

using Test
using Chain
using Dates
using DataFrames
using DuckDB
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
const REAL_STEPS = (REAL_START + REAL_RESOLUTION):REAL_RESOLUTION:(REAL_START + REAL_SPAN)

const VIOLATION_START = DateTime(2026, 6, 9, 5, 0)
const VIOLATION_STEPS = VIOLATION_START:REAL_RESOLUTION:(VIOLATION_START + REAL_SPAN)

const db = aem_connect(HiveConfiguration(hive_location = REAL_HIVE))

# Pre-flight checks, the system over `steps` and the two intervals after them, then the built and
# executed replay of `template`; throws unless both the build and the execution succeed.
function replay_real(steps; template = template_nemde())
    date_range = first(steps):DISPATCH_INTERVAL:(last(steps) + 2DISPATCH_INTERVAL)
    sys = nem_system(db, NEMDEConfiguration(); date_range)
    skipped = prepare_replay!(sys, template, steps)
    model = PSI.DecisionModel(
        NEMDispatchProblem, template, sys; optimizer = nemde_optimizer(), initial_time = first(steps), name = "dispatch",
    )
    models = PSI.SimulationModels(; decision_models = [model])
    sequence = PSI.SimulationSequence(; models, ini_cond_chronology = PSI.InterProblemChronology())
    simulation = PSI.Simulation(;
        name = "real_data", steps = length(steps), models, sequence,
        simulation_folder = mktempdir(), initial_time = first(steps),
    )
    build_status = PSI.build!(simulation; store_systems_in_results = false)
    @test build_status == PSI.SimulationBuildStatus.BUILT
    build_status == PSI.SimulationBuildStatus.BUILT ||
        error("Replay from $(first(steps)) failed to build ($build_status); see the simulation logs.")
    run_status = PSI.execute!(simulation)
    @test run_status == PSI.RunStatus.SUCCESSFULLY_FINALIZED
    run_status == PSI.RunStatus.SUCCESSFULLY_FINALIZED ||
        error("Replay from $(first(steps)) failed to execute ($run_status); see the simulation logs.")
    results = PSI.get_decision_problem_results(PSI.SimulationResults(simulation), "dispatch")
    return (; sys, template, skipped, model, results, date_range)
end

# An unbounded capacity variable means a nonzero effective MaxAvail somewhere in the window.
enabled(v) = !PSI.JuMP.has_upper_bound(v) || PSI.JuMP.upper_bound(v) > 0.0

# The rows of the SQL `statement` with positional `params`.
query(db, statement, params) = DataFrame(DuckDB.execute(db.db, statement, params))

# The variable keys of `results` with entry type `V` on component type `C`.
function variable_keys(results, V::Type, C::Type)
    return [
        k for k in PSI.list_variable_keys(results)
            if PSI.IS.Optimization.get_entry_type(k) === V && PSI.IS.Optimization.get_component_type(k) === C
    ]
end

# The §6.1 joint ramping check of one unit and interval at NEMDE's published solution against the
# right-hand side `rhs_mw`; `nothing` where the dispatch row or one of its values was not published.
function joint_ramping_row(published, service, bid_type, device, settlement, rhs_mw)
    prow = get(published, (bid_type, PSY.get_name(device), settlement), nothing)
    (isnothing(prow) || ismissing(prow.TOTALCLEARED) || ismissing(prow.TARGET) || ismissing(prow.INITIALMW)) && return nothing
    energy_mw, target_mw, initial_mw = prow.TOTALCLEARED, prow.TARGET, prow.INITIALMW
    upper = bid_type == fcas_upper_regulation_service(device)
    lhs_mw = upper ? energy_mw + target_mw : energy_mw - target_mw
    diff_mw = lhs_mw - rhs_mw
    violated = upper ? diff_mw > 1.0 : diff_mw < -1.0
    ramp_cap_mw = upper ? rhs_mw - initial_mw : initial_mw - rhs_mw
    # The unit's energy already sits on the bid-capped ramp floor, with no headroom for the target.
    energy_at_own_ramp_floor = isapprox(energy_mw, upper ? initial_mw + ramp_cap_mw : initial_mw - ramp_cap_mw; atol = 1.0)
    return (;
        service, bid_type, duid = PSY.get_name(device), device_type = nameof(typeof(device)), settlement,
        initial_mw, energy_mw, target_mw, ramp_cap_mw, lhs_mw, rhs_mw, diff_mw, violated,
        agc_status = prow.AGCSTATUS, energy_at_own_ramp_floor,
    )
end

@testset "Real NEM data, $(Date(REAL_START))" begin
    replay = replay_real(REAL_STEPS)
    (; sys, template, skipped, model, results, date_range) = replay
    devices = AEM.nem_dispatch_devices(sys)

    @testset "the NEMDE System builds" begin
        areas = Set(PSY.get_name.(PSY.get_components(PSY.Area, sys)))
        @test issubset(Set(["NSW1", "QLD1", "SA1", "TAS1", "VIC1"]), areas)
        for T in (NEMThermalGen, NEMHydroGen, NEMRenewableGen, PSY.AreaInterchange)
            @test !isempty(PSY.get_components(T, sys))
        end
        @test !isempty(PSY.get_components(GenericConstraint, sys))
    end

    @testset "dispatch limits" begin
        limits = read_dispatch_limits(db, date_range)

        @test all(AEMS._has_nem_dispatch_limits, devices)
        @test all(d -> PSY.get_name(d) in Set(limits.DUID) || AEM.is_non_scheduled_load(d), devices)

        @testset "the stored ramp rate yields AEMO's per-interval ramp" begin
            first_stamp = first(date_range)
            row = first(
                filter(
                    r -> r.SETTLEMENTDATE == first_stamp && coalesce(r.RAMPUPRATE, 0.0) > 0 &&
                        !isnothing(PSY.get_component(NEMThermalGen, sys, r.DUID)) &&
                        PSY.get_available(PSY.get_component(NEMThermalGen, sys, r.DUID)),
                    limits,
                ),
            )
            device = PSY.get_component(NEMThermalGen, sys, row.DUID)
            stored = first(PSY.get_time_series_values(PSY.SingleTimeSeries, device, "ramp_up_rate"))
            minutes = Dates.value(Minute(REAL_RESOLUTION))
            # The formulation multiplies the stored rate by the interval in minutes.
            @test stored * minutes ≈
                row.RAMPUPRATE * interval_hours(DISPATCH_INTERVAL) / PSY.get_base_power(sys) rtol = 1.0e-9
        end

        @testset "the stored dispatch ceiling is max(AVAILABILITY, ramp-down floor)" begin
            checked = 0
            unpublished = 0
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
                stamps = PSY.get_time_series_timestamps(PSY.SingleTimeSeries, device, "max_active_power")
                rows = filter(:DUID => ==(duid), limits)
                by_time = Dict(zip(rows.SETTLEMENTDATE, eachrow(rows)))
                pinned = AEM.is_non_scheduled_load(device)
                for (t, value) in zip(stamps, series)
                    row = get(by_time, t, nothing)
                    # A non-scheduled load, or a unit with no DISPATCHLOAD row, is pinned to zero.
                    if pinned || isnothing(row)
                        unpublished += 1
                        iszero(value) || push!(mismatches, "$duid at $t: $value vs 0 (no published limit)")
                        continue
                    end
                    expected = max(row.AVAILABILITY, row.INITIALMW - row.RAMPDOWNRATE * interval_hours(DISPATCH_INTERVAL))
                    checked += 1
                    isapprox(value * static_max_active_power, expected; atol = 1.0e-6) ||
                        push!(mismatches, "$duid at $t: $(value * static_max_active_power) vs $expected")
                end
            end
            @info "Dispatch ceiling coverage" checked unpublished
            @test checked > 0
            @test isempty(mismatches)
        end
    end

    @testset "the pre-flight constraint check" begin
        @test names(skipped) == ["constraint", "reason", "n_missing"]
        known = (:unmodeled_fcas_service, :missing_component, :unmodeled_device_type, :no_available_device, :never_invoked)
        @test all(in(known), skipped.reason)
        # Every constraint term names a device in the System.
        @test !(:missing_component in skipped.reason)
        # Some GenericConstraint is modelled: the results record its NEMConstraintLimit dual.
        @test any(k -> PSI.IS.Optimization.get_entry_type(k) === NEMConstraintLimit, PSI.list_dual_keys(results))
        @info "Constraints left out of the replay, by reason" counts = Dict(r => count(==(r), skipped.reason) for r in unique(skipped.reason))
    end

    solved = read_solved_interval(results, sys)
    violations = read_constraint_violations(results, sys)

    @testset "the replay builds and solves" begin
        comparison = compare_intervals(read_published_interval(db, REAL_STEPS), solved)
        @test !isempty(comparison.prices)
        @test !isempty(comparison.dispatch)
        @test !isempty(comparison.interconnectors)
        total_area_slack_mw = sum(violations.MW[violations.family .== "area_balance"]; init = 0.0)
        @info "Real-data replay" summary = sprint(show, comparison_summary(comparison); context = :limit => false) total_area_slack_mw
    end

    @testset "interconnector loss gap" begin
        table = read_interconnector_loss_gaps(results, sys)

        @test !isempty(table)
        # Negative weighted prices included, loss must stay on the curve at the solved flow.
        @test all(abs.(table.gap_mw) .< 1.0e-3)

        report = join(
            [
                let rows = table[table.interconnector .== name, :]
                    "$name: max|gap| $(round(maximum(abs, rows.gap_mw); digits = 4)) MW, " *
                        "t1 weighted price $(rows.weighted_loss_price[1] >= 0 ? "non-negative" : "NEGATIVE"), " *
                        "$(count(<(0), rows.weighted_loss_price)) negative interval(s)"
                end for name in sort(unique(table.interconnector))
            ], "; ",
        )
        @info "Interconnector over-dissipation gap (solved LP loss - curve at solved flow) and weighted price sign" report
    end

    @testset "FCAS" begin
        fcas_registered = PSY.get_name.(PSY.get_components(FCASService, sys))
        n_regulation_trapeziums = 0
        n_regulation_trapeziums_scaled = 0
        horizon = length(REAL_STEPS)
        for svc in PSY.get_components(FCASService, sys)
            bid_type = get_bid_type(svc)
            # Count how many (device, t) regulation trapeziums AEMO's §4 scaling actually
            # narrowed; contingency bid types are never scaled for a scheduled unit.
            bid_type in AEM.FCAS_REGULATION_MARKETS || continue
            for d in PSY.get_contributing_devices(sys, svc)
                direction = AEM.fcas_bid_direction(d, bid_type)
                for decremental in (direction == FCASBidDirection.BOTH ? (false, true) : (direction == FCASBidDirection.DECREMENTAL,))
                    raw = AEM._get_fcas_trapezium(d, bid_type, first(date_range), horizon; decremental = decremental)
                    scaled = get_scaled_fcas_trapezium(d, bid_type, first(date_range), horizon; decremental = decremental)
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

        # The FCAS prices the solve's constraint duals imply, against AEMO's published ROP (the sum
        # of the requirement constraints' MARGINALVALUE) per (region, service, interval).
        fcas_prices = AEM.read_fcas_prices(results, sys)
        published_prices = AEM.read_fcas_prices(db, date_range)
        compared = innerjoin(fcas_prices, published_prices; on = [:SETTLEMENTDATE, :REGIONID, :BIDTYPE], makeunique = true)
        n_price_cmp = nrow(compared)
        n_price_ok = count(r -> isapprox(r.ROP, r.ROP_1; atol = 0.5, rtol = 0.01), eachrow(compared))
        fcas_price_match_rate = n_price_cmp > 0 ? n_price_ok / n_price_cmp : NaN
        @info "Real-data FCAS prices from constraint duals vs published ROP" n_price_cmp n_price_ok fcas_price_match_rate
        @test n_price_cmp > 0

        # Per-side regulation reads a battery's discharge and charge separately, so the solve
        # must not charge and discharge a battery in the same interval.
        out_keys = variable_keys(results, PSI.ActivePowerOutVariable, NEMStorage)
        in_keys = variable_keys(results, PSI.ActivePowerInVariable, NEMStorage)
        n_circulating = 0
        @test !isempty(out_keys) && !isempty(in_keys)
        if !isempty(out_keys) && !isempty(in_keys)
            realized = PSI.read_realized_variables(
                results, PSI.IS.Optimization.encode_key_as_string.([only(out_keys), only(in_keys)]),
            )
            out_df, in_df = (realized[PSI.IS.Optimization.encode_key_as_string(k)] for k in (only(out_keys), only(in_keys)))
            both = innerjoin(out_df, in_df; on = [:DateTime, :name], makeunique = true)
            n_circulating = count(r -> min(r.value, r.value_1) > 1.0e-3, eachrow(both))
        end
        @test n_circulating == 0
        @info "Real-data FCAS" n_services = length(fcas_registered) n_regulation_trapeziums_scaled n_regulation_trapeziums
    end

    # AEMO §6.1 fidelity: each active joint ramping row (a regulation service, unit and interval),
    # evaluated at NEMDE's own published TOTALCLEARED and regulation TARGET against the row's
    # right-hand side. The series check covers every step; the container check covers the last step.
    @testset "§6.1 joint ramping at the published solution" begin
        container = PSI.get_optimization_container(model)
        settlement = last(REAL_STEPS)
        base_power = PSY.get_base_power(sys)

        n_enabled_pairs = 0
        for name in PSY.get_name.(PSY.get_components(FCASService, sys))
            if PSI.has_container_key(container, FCASCapacityVariable, FCASService, name)
                var = PSI.get_variable(container, FCASCapacityVariable(), FCASService, name)
                n_enabled_pairs += count(k -> enabled(var[k...]), Iterators.product(axes(var)...))
            end
            for side in ("gen", "load")
                PSI.has_container_key(container, FCASSideCapacityVariable, FCASService, "$(name)_$side") || continue
                var = PSI.get_variable(container, FCASSideCapacityVariable(), FCASService, "$(name)_$side")
                n_enabled_pairs += count(k -> enabled(var[k...]), Iterators.product(axes(var)...))
            end
        end
        @test n_enabled_pairs > 0

        reg_dispatch = filter(
            :BIDTYPE => in(AEM.FCAS_REGULATION_MARKETS),
            AEM.read_fcas_dispatch(db, first(REAL_STEPS):DISPATCH_INTERVAL:(last(REAL_STEPS) + DISPATCH_INTERVAL)),
        )
        published = Dict((row.BIDTYPE, row.DUID, row.SETTLEMENTDATE) => row for row in eachrow(reg_dispatch))

        # The last step: the right-hand side of the built row is its set bound less the fixed (parameter) terms.
        last_step = NamedTuple[]
        n_inactive_last = 0
        for svc in PSY.get_components(FCASService, sys)
            bid_type = get_bid_type(svc)
            bid_type in AEM.FCAS_REGULATION_MARKETS || continue
            name = PSY.get_name(svc)
            PSI.has_container_key(container, FCASJointRampingConstraint, FCASService, name) || continue
            con = PSI.get_constraint(container, FCASJointRampingConstraint(), FCASService, name)
            for device in PSY.get_contributing_devices(sys, svc)
                duid = PSY.get_name(device)
                duid in axes(con, 1) || continue
                row = PSI.JuMP.constraint_object(con[duid, 1])
                fixed = [v for v in keys(row.func.terms) if PSI.JuMP.is_fixed(v)]
                fixed_pu = row.func.constant + sum(row.func.terms[v] * PSI.JuMP.fix_value(v) for v in fixed; init = 0.0)
                upper = bid_type == fcas_upper_regulation_service(device)
                rhs_mw = ((upper ? row.set.upper : row.set.lower) - fixed_pu) * base_power
                if abs(rhs_mw) >= FCAS_INACTIVE_LIMIT_MW - 1
                    n_inactive_last += 1
                    continue
                end
                checked = joint_ramping_row(published, name, bid_type, device, settlement, rhs_mw)
                isnothing(checked) || push!(last_step, checked)
                # The built row reads the device's fcas_ramping_limits series at that interval.
                series = PSY.get_time_series_values(PSY.SingleTimeSeries, device, fcas_ramping_series_name(bid_type))
                stamps = PSY.get_time_series_timestamps(PSY.SingleTimeSeries, device, fcas_ramping_series_name(bid_type))
                @test rhs_mw ≈ first(series[findfirst(==(settlement), stamps)]) * base_power atol = 1.0e-6
            end
        end

        # Every step, from the device series that the formulation reads as the right-hand side.
        all_steps = NamedTuple[]
        n_inactive_all = 0
        for svc in PSY.get_components(FCASService, sys)
            bid_type = get_bid_type(svc)
            bid_type in AEM.FCAS_REGULATION_MARKETS || continue
            name = PSY.get_name(svc)
            for device in PSY.get_contributing_devices(sys, svc)
                PSY.has_time_series(device, PSY.SingleTimeSeries, fcas_ramping_series_name(bid_type)) || continue
                series = PSY.get_time_series_values(PSY.SingleTimeSeries, device, fcas_ramping_series_name(bid_type))
                stamps = PSY.get_time_series_timestamps(PSY.SingleTimeSeries, device, fcas_ramping_series_name(bid_type))
                for (t, value) in zip(stamps, series)
                    t in REAL_STEPS || continue
                    rhs_mw = first(value) * base_power
                    if abs(rhs_mw) >= FCAS_INACTIVE_LIMIT_MW - 1
                        n_inactive_all += 1
                        continue
                    end
                    checked = joint_ramping_row(published, name, bid_type, device, t, rhs_mw)
                    isnothing(checked) || push!(all_steps, checked)
                end
            end
        end

        for (label, rows) in (("last step", last_step), ("all steps", all_steps))
            violations = filter(r -> r.violated, rows)
            if !isempty(violations)
                println("§6.1 fidelity violations at the published solution, $label ($(length(violations))/$(length(rows))):")
                println(
                    rpad("service", 22), rpad("duid", 12), rpad("type", 22), rpad("settlement", 21),
                    rpad("initial_mw", 11), rpad("energy_mw", 10), rpad("target_mw", 10),
                    rpad("ramp_mw", 9), rpad("diff_mw", 9), rpad("agc", 4), "at_ramp_floor",
                )
                for r in violations
                    agc = ismissing(r.agc_status) ? "?" : string(r.agc_status)
                    println(
                        rpad(r.service, 22), rpad(r.duid, 12), rpad(string(r.device_type), 22), rpad(string(r.settlement), 21),
                        rpad(string(round(r.initial_mw; digits = 1)), 11), rpad(string(round(r.energy_mw; digits = 1)), 10),
                        rpad(string(round(r.target_mw; digits = 1)), 10), rpad(string(round(r.ramp_cap_mw; digits = 1)), 9),
                        rpad(string(round(r.diff_mw; digits = 1)), 9), rpad(agc, 4), r.energy_at_own_ramp_floor,
                    )
                end
            end
            n_rows = length(rows)
            n_violations = length(violations)
            n_ramp_floor_violations = count(r -> r.energy_at_own_ramp_floor, violations)
            n_unexplained_violations = n_violations - n_ramp_floor_violations
            n_inactive = label == "last step" ? n_inactive_last : n_inactive_all
            @info "§6.1 fidelity, $label" n_enabled_pairs n_rows n_inactive n_violations n_ramp_floor_violations n_unexplained_violations
            @test n_rows > 0
            @test n_unexplained_violations == 0
        end
    end
end

@testset "Elastic GenericConstraint slack matches AEMO's published violation, $(Date(VIOLATION_START))" begin
    replay = replay_real(VIOLATION_STEPS)
    (; sys, results, date_range) = replay
    base_power = PSY.get_base_power(sys)

    target_gencon_ids = ("Q_STR_ALDSF_ZERO", "Q_BRDDSF01_1INV")
    gcs = [gc for gc in PSY.get_components(GenericConstraint, sys) if get(gc.ext, "gencon_id", nothing) in target_gencon_ids]
    @test length(gcs) == length(target_gencon_ids)

    dual_keys = Dict(
        k.meta => k for k in PSI.list_dual_keys(results) if PSI.IS.Optimization.get_entry_type(k) === NEMConstraintLimit
    )
    dc_table = read_hive(db, :DISPATCHCONSTRAINT)
    violations = read_constraint_violations(results, sys)
    for gc in gcs
        name = PSY.get_name(gc)
        gencon_id = get(gc.ext, "gencon_id", nothing)
        invoked_values = PSY.IS.get_time_series_values(
            gc, gc.invoked; start_time = first(VIOLATION_STEPS), len = length(VIOLATION_STEPS),
        )
        invoked = invoked_values .> 0.0
        invoked_dates = collect(VIOLATION_STEPS)[invoked]
        @info "Invoked intervals of the violation window" gencon_id n_invoked = count(invoked) n_not_invoked = count(!, invoked)

        slack_type = get_sense(gc) == ConstraintSense.LE ? "GenericConstraintSlackUp" : "GenericConstraintSlackDown"
        slack_name = "$(slack_type)__GenericConstraint__$name"
        slack_df = PSI.read_realized_variables(results, [slack_name])[slack_name]
        @test sort(slack_df.DateTime) == collect(VIOLATION_STEPS)
        # A non-invoked row is vacuous and its slack free, so the violation reader must not report it.
        @test any(!, invoked)
        reported = filter(r -> r.family == "generic_constraint" && r.name == name, violations).DateTime
        @test isempty(setdiff(reported, invoked_dates))

        dual_key = dual_keys[name]
        dual_df = PSI.read_realized_duals(results, [dual_key])[PSI.IS.Optimization.encode_key_as_string(dual_key)]
        published = DataFrame(
            DuckDB.execute(
                db.db,
                """
                SELECT SETTLEMENTDATE, VIOLATIONDEGREE, MARGINALVALUE FROM $dc_table
                WHERE CONSTRAINTID = ? AND SETTLEMENTDATE BETWEEN ? AND ? AND INTERVENTION = 0
                ORDER BY SETTLEMENTDATE
                """,
                [gencon_id, first(VIOLATION_STEPS), last(VIOLATION_STEPS)],
            ),
        )
        published_invoked = subset(published, :SETTLEMENTDATE => ByRow(in(invoked_dates)))
        @test Set(published_invoked.SETTLEMENTDATE) == Set(invoked_dates)
        @test nrow(published_invoked) == length(invoked_dates)
        comparison = innerjoin(
            select(slack_df, :DateTime, :value => :slack_mw),
            select(published_invoked, :SETTLEMENTDATE => :DateTime, :VIOLATIONDEGREE, :MARGINALVALUE);
            on = :DateTime, validate = (true, true),
        )
        comparison = innerjoin(
            comparison, select(dual_df, :DateTime, :value => :dual); on = :DateTime, validate = (true, true),
        )
        # The reader may leave a step without a value; none is a zero slack.
        comparison.slack_mw = coalesce.(comparison.slack_mw, 0.0)
        @test nrow(comparison) == nrow(published_invoked)
        @test any(>(0.0), comparison.slack_mw)
        @test any(>(0.0), comparison.VIOLATIONDEGREE)
        @info "Realized slack vs published VIOLATIONDEGREE" gencon_id comparison
        @test all(isapprox.(comparison.slack_mw, comparison.VIOLATIONDEGREE; atol = 1.0e-6))
        # PSI leaves the dual in $ per pu of RHS per interval; divide by base_power and the interval
        # length for a $/MW comparison against AEMO's MARGINALVALUE.
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
        flows_losses = query(
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
            [first(VIOLATION_STEPS), last(VIOLATION_STEPS)],
        )
        filter!(row -> !ismissing(row.MWFLOW) && !ismissing(row.MWLOSSES), flows_losses)

        # Two demand definitions: this package's TOTALDEMAND, and nempy's INITIALSUPPLY +
        # DEMANDFORECAST. Keyed by `t.SETTLEMENTDATE`: a GroupKey never equals a DateTime.
        region_sum = read_hive(db, :DISPATCHREGIONSUM)
        demand_rows = query(
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
            [first(VIOLATION_STEPS), last(VIOLATION_STEPS)],
        )
        demand_by_time(column) = Dict(
            key.SETTLEMENTDATE => Dict(
                r.REGIONID => r[column] for r in eachrow(rows) if !ismissing(r[column])
            )
                for (key, rows) in pairs(groupby(demand_rows, :SETTLEMENTDATE))
        )
        demands = ("TOTALDEMAND" => demand_by_time(:TOTALDEMAND), "INITIALSUPPLY+DEMANDFORECAST" => demand_by_time(:NEMPY_DEMAND))
        @test !isempty(last(first(demands)))

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
                demand = demand_lookup[row.SETTLEMENTDATE]
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
