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
end
