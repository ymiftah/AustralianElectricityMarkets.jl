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
    # Same t0 as augmented_pscb_system()'s own PowerSystemCaseBuilder forecast (2020-01-01T00:00),
    # so add_fcas_variables! can align FCAS trapezium rows to the model's own dispatch timesteps
    # by absolute timestamp - the series stays 5-minutely though (see pscb_nemweb_data.jl):
    # augmented_pscb_system()'s native forecast is a genuine rolling 2015-window Deterministic at
    # (resolution, interval) = (Hour(1), Hour(1)), and InfrastructureSystems requires every
    # Deterministic sharing a System's (resolution, interval) key to also share its
    # count/initial_timestamp/horizon - confirmed directly, attaching this fixture's series at
    # resolution = Hour(1) raises ConflictingInputsError("forecast count 1 does not match system
    # count 2015"). Every model dispatch timestep is still a whole-hour multiple, so it lands
    # exactly on one of this fixture's 5-minute rows regardless.
    start_date = DateTime(2020, 1, 1, 0, 0)
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

    # The fixture's FCAS series and `model`'s own dispatch timesteps share t0 but not
    # resolution (5-minute series, hourly model - see the date_range comment above), so model
    # timestep `t`'s trapezium row isn't row `t` itself; it's whichever row that timestep's
    # elapsed time from `start_date` lands on at the series' own (5-minute) resolution - the
    # same arithmetic `add_fcas_variables!` uses.
    model_timestamps = PSI.get_timestamps(model)
    n_timesteps = length(model_timestamps)
    series_resolution = step(date_range)
    expected_row_indices = [
        Dates.value(ts - start_date) ÷ Dates.value(Millisecond(series_resolution)) + 1
            for ts in model_timestamps
    ]

    @testset "variable count equals offering units x model timesteps, per service" begin
        checked = 0
        for bid_type in FCAS_BID_TYPES
            service = string(bid_type)
            series_name = "fcas_trapezium_$(service)"
            offering = [
                get_name(comp) for comp in get_components(Device, sys)
                    if has_time_series(comp, Deterministic, series_name)
            ]
            @test !isempty(offering)  # sanity: the fixture actually offers this service
            keys_ = [(duid, service) for duid in offering]
            @test all(k -> haskey(variables, k), keys_)
            counts = [length(get(variables, k, JuMP.VariableRef[])) for k in keys_]
            @test all(==(n_timesteps), counts)
            checked += length(offering)
        end
        @test checked > 0  # guard: an empty offering/lookup must not pass silently
    end

    @testset "upper bounds equal the model-aligned max_avail values, lower bound is 0" begin
        checked = 0
        for ((duid, service), vars) in variables
            comp = get_component(Device, sys, duid)
            series_name = "fcas_trapezium_$(service)"
            rows = first(values(get_data(get_time_series(Deterministic, comp, series_name))))
            @test length(vars) == n_timesteps
            expected_ub = getindex.(rows[expected_row_indices], 5)
            @test all(JuMP.has_upper_bound, vars)
            @test JuMP.upper_bound.(vars) == expected_ub
            @test all(JuMP.has_lower_bound, vars)
            @test all(==(0.0), JuMP.lower_bound.(vars))
            checked += length(vars)
        end
        @test checked > 0  # guard: an empty variable set must not pass silently
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
