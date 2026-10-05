@testset "Per-interval inputs" begin
    using PowerSystems
    using Dates
    using DataFrames
    import TimeSeries

    db = aem_connect(HiveConfiguration(hive_location = AEM_TEST_HIVE_DIR, filesystem = "file"))
    start_date = DateTime(2025, 1, 1, 0, 0)
    date_range = start_date:Minute(5):(start_date + Minute(30))
    grid = collect(date_range)[1:(end - 1)]

    @testset "set_interconnector_flow_limits!" begin
        # DISPATCHINTERCONNECTORRES is absent from the shared mock hive: write it to its own.
        limits_dir = mktempdir()
        let ddb = DuckDB.DB(), conn = DuckDB.connect(ddb)
            DuckDB.execute(conn, "SET preserve_identifier_case=true")
            df = DataFrame()
            for (i, t) in enumerate(grid), k in 1:3
                # IC2 is missing at the second interval, IC3 has crossed limits at the third.
                (k == 2 && i == 2) && continue
                crossed = k == 3 && i == 3
                append!(
                    df, DataFrame(
                        SETTLEMENTDATE = [t], INTERCONNECTORID = ["IC$k"], INTERVENTION = [0],
                        METEREDMWFLOW = [10.0 * k],
                        EXPORTLIMIT = [crossed ? -300.0 : 400.0 - 10 * i],
                        # IC1 import limit exceeds the 500 MW static limit and is clipped to it.
                        IMPORTLIMIT = [k == 1 && i == 4 ? -900.0 : (crossed ? -100.0 : -(300.0 + 10 * i))],
                        archive_month = ["2025-01"],
                    ),
                )
            end
            DuckDB.register_data_frame(conn, df, "tmp_table")
            DuckDB.execute(conn, "COPY (SELECT * FROM tmp_table) TO '$(joinpath(limits_dir, "DISPATCHINTERCONNECTORRES"))' (FORMAT 'PARQUET', PARTITION_BY (archive_month))")
        end
        limits_db = aem_connect(HiveConfiguration(hive_location = limits_dir, filesystem = "file"))

        rows = read_interconnector_limits(limits_db, date_range)
        @test Set(names(rows)) == Set(["SETTLEMENTDATE", "INTERCONNECTORID", "METEREDMWFLOW", "EXPORTLIMIT", "IMPORTLIMIT"])
        @test nrow(rows) == 3 * length(grid) - 1

        sys = nem_system(db, RegionalNetworkConfiguration())
        set_interconnector_flow_limits!(sys, limits_db, date_range)
        series(name, kind) = TimeSeries.values(
            get_time_series_array(SingleTimeSeries, get_component(AreaInterchange, sys, name), kind),
        )

        # Static limit is 500 MW; the series is the published limit as a fraction of it.
        @test series("IC1", "from_to_flow_limit")[1:3] ≈ [310.0, 320.0, 330.0] ./ 500
        @test series("IC1", "to_from_flow_limit")[1:3] ≈ [390.0, 380.0, 370.0] ./ 500
        @test series("IC1", "from_to_flow_limit")[4] == 1.0  # clipped to the static limit
        # Missing interval and crossed limits keep the static limit; so does an interconnector with no rows.
        @test series("IC2", "to_from_flow_limit")[2] == 1.0
        @test series("IC3", "from_to_flow_limit")[3] == 1.0
        @test all(==(1.0), series("IC4", "to_from_flow_limit"))
        @test all(has_time_series(d) for d in get_components(AreaInterchange, sys))

        @test_throws ArgumentError read_interconnector_limits(db, date_range)
    end

    @testset "nem_system resolves static tables as of the build start" begin
        versioned_dir = mktempdir()
        create_versioned_static_data(AEM_TEST_HIVE_DIR, versioned_dir)
        vdb = aem_connect(HiveConfiguration(hive_location = versioned_dir, filesystem = "file"))
        from_to(sys) = with_units_base(
            () -> get_flow_limits(get_component(AreaInterchange, sys, "IC1")).from_to, sys, "NATURAL_UNITS",
        )
        @test from_to(nem_system(vdb, RegionalNetworkConfiguration())) == 300.0
        @test from_to(nem_system(vdb, RegionalNetworkConfiguration(); as_of = DateTime(2025, 3, 1))) == 500.0
        constrained = nem_system(vdb, ConstrainedNetworkConfiguration(); date_range = date_range)
        @test from_to(constrained) == 500.0
    end
end
