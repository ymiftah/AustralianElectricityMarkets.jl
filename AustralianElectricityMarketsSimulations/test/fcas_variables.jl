@testset "FCAS decision variables" begin
    using AustralianElectricityMarketsSimulations
    using AustralianElectricityMarkets
    using PowerSystems
    using JuMP
    using HiGHS
    using Dates
    using DataFrames

    import PowerSimulations as PSI

    hive = mktempdir()
    create_pscb_nemweb_data(hive)
    config = HiveConfiguration(hive_location = hive, filesystem = "file")
    db = aem_connect(config)
    start_date = DateTime(2025, 1, 1, 0, 0)
    date_range = start_date:Minute(5):(start_date + Hour(2) + Minute(5))

    sys = augmented_pscb_system()
    add_nem_constraints!(sys, db, date_range)
    set_fcas_bids!(sys, db, date_range)

    # `resolution`/`interval` must be pinned explicitly: `augmented_pscb_system()` carries its
    # own hourly Deterministic forecasts (from PowerSystemCaseBuilder) alongside the 5-minute
    # NEM series `set_fcas_bids!`/`add_nem_constraints!` just attached, and PSI's
    # `validate_time_series!` throws `ConflictingInputsError` for both resolution and interval
    # if a `DecisionModel` doesn't say which one it means - the spike that de-risked this task.
    template = build_template(T0CopperPlate())
    model = PSI.DecisionModel(
        template, sys; optimizer = HiGHS.Optimizer, resolution = Hour(1), interval = Hour(1),
    )
    PSI.build!(model; output_dir = mktempdir())

    variables = add_fcas_variables!(model, sys)

    @testset "variable count equals offering units x timesteps, per service" begin
        checked = 0
        for bid_type in FCAS_BID_TYPES
            service = string(bid_type)
            series_name = "fcas_trapezium_$(service)"
            offering = [
                get_name(comp) for comp in get_components(Device, sys)
                    if has_time_series(comp, Deterministic, series_name)
            ]
            @test !isempty(offering)  # sanity: the fixture actually offers this service
            for duid in offering
                key = (duid, service)
                @test haskey(variables, key)
                comp = get_component(Device, sys, duid)
                rows = first(values(get_data(get_time_series(Deterministic, comp, series_name))))
                @test length(variables[key]) == length(rows)
                checked += 1
            end
        end
        @test checked > 0  # guard: an empty offering/lookup must not pass silently
    end

    @testset "upper bounds equal the series' max_avail values, lower bound is 0" begin
        checked = 0
        for ((duid, service), vars) in variables
            comp = get_component(Device, sys, duid)
            series_name = "fcas_trapezium_$(service)"
            rows = first(values(get_data(get_time_series(Deterministic, comp, series_name))))
            @test length(vars) == length(rows)
            for (var, row) in zip(vars, rows)
                @test JuMP.has_upper_bound(var)
                @test JuMP.upper_bound(var) == row[5]
                @test JuMP.has_lower_bound(var)
                @test JuMP.lower_bound(var) == 0.0
                checked += 1
            end
        end
        @test checked > 0
    end

    @testset "a unit with no trapezium for a service has no variable for it" begin
        # The PSCB NEMWEB fixture (create_pscb_nemweb_data) gives every unit every service, so
        # there is no such gap "by construction" to observe - strip one to exercise the skip
        # path directly instead of only asserting it never fires.
        sys2 = augmented_pscb_system()
        add_nem_constraints!(sys2, db, date_range)
        set_fcas_bids!(sys2, db, date_range)
        alta = get_component(ThermalStandard, sys2, "Alta")
        @test has_time_series(alta, Deterministic, "fcas_trapezium_RAISE60SEC")
        remove_time_series!(sys2, Deterministic, alta, "fcas_trapezium_RAISE60SEC")
        @test !has_time_series(alta, Deterministic, "fcas_trapezium_RAISE60SEC")

        model2 = PSI.DecisionModel(
            build_template(T0CopperPlate()), sys2;
            optimizer = HiGHS.Optimizer, resolution = Hour(1), interval = Hour(1),
        )
        PSI.build!(model2; output_dir = mktempdir())
        variables2 = add_fcas_variables!(model2, sys2)

        @test !haskey(variables2, ("Alta", "RAISE60SEC"))
        # sanity: a sibling unit that still carries the series does get one - the absence above
        # is because the series was removed, not because RAISE60SEC vanished from the model.
        @test haskey(variables2, ("Brighton", "RAISE60SEC"))
    end

    @testset "decremental variables are deferred, not created" begin
        # BAT1 carries "fcas_trapezium_<SERVICE>_decremental" series (LOAD-direction bids);
        # add_fcas_variables! documents deferring these, so no key's service string may carry
        # the "_decremental" suffix, for BAT1 or anyone else.
        bat_keys = [k for k in keys(variables) if k[1] == "BAT1"]
        @test !isempty(bat_keys)  # sanity: BAT1 does get incremental variables
        @test all(k -> !occursin("_decremental", k[2]), keys(variables))
    end
end
