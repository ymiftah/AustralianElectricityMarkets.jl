@testset "trace files load once per content and resolve every reference" begin
    mktempdir() do root
        write_isp_trace_fixture(joinpath(root, "source"))
        config = HiveConfiguration(; hive_location = joinpath(root, "cache"))
        build_isp_cache(config, joinpath(root, "source"))
        db = isp_cache(config)
        try
            files = DataFrame(
                DuckDB.execute(
                    db.db,
                    """
                    SELECT scenario, family, filename, table_name, row_count, column_count
                    FROM cache_meta.trace_files ORDER BY filename
                    """,
                ),
            )
            @test nrow(files) == 3
            @test sort(unique(files.table_name)) |> length == 2
            @test count(==("demand"), files.family) == 2
            @test count(==("wind"), files.family) == 1
            @test only(files.scenario[files.filename .== "DEMO.csv"]) == "step_change"
            @test only(files.scenario[files.filename .== "SHARED.csv"]) === missing
            @test all(==(2), files.row_count[files.family .== "demand"])

            layout = DataFrame(
                DuckDB.execute(db.db, "SELECT layout_version FROM cache_meta.cache"),
            )
            @test only(layout.layout_version) == 2

            tables = DataFrame(
                DuckDB.execute(
                    db.db,
                    "SELECT table_name FROM information_schema.tables WHERE table_schema = 'traces'",
                ),
            )
            @test nrow(tables) == 2

            references = DataFrame(
                DuckDB.execute(db.db, "SELECT * FROM cache_meta.trace_references ORDER BY data_file_object_name"),
            )
            @test nrow(references) == 2
            @test sort(references.data_file_object_name) == ["DEMO", "SHARED"]
            @test all(==("step_change"), references.scenario)

            bindings = DataFrame(
                DuckDB.execute(
                    db.db,
                    "SELECT property_name, table_name FROM step_change.trace_bindings ORDER BY table_name",
                ),
            )
            @test nrow(bindings) == 2
            @test all(==("Rating"), bindings.property_name)
            @test all(startswith("f_"), bindings.table_name)
            @test nrow(
                DataFrame(
                    DuckDB.execute(
                        db.db,
                        "SELECT * FROM step_change.trace_bindings WHERE property_name = 'Filename'",
                    ),
                ),
            ) == 0
        finally
            DBInterface.close!(db.db)
        end
    end
end

@testset "an unresolved trace reference fails the build" begin
    mktempdir() do root
        write_isp_trace_fixture(joinpath(root, "source"); missing_reference = true)
        config = HiveConfiguration(; hive_location = joinpath(root, "cache"))
        err = try
            build_isp_cache(config, joinpath(root, "source"))
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("ABSENT", err.msg)
        @test !isfile(isp_cache_path(config))
    end
end

@testset "a ragged trace CSV fails the build" begin
    mktempdir() do root
        source = joinpath(root, "source")
        scenario = joinpath(source, "model", "2026 ISP Model", "2026 ISP Step Change")
        mkpath(joinpath(scenario, "Traces", "demand"))
        write(joinpath(scenario, "Traces", "demand", "BAD.csv"), "Year,Month\n2026,7,1\n")
        records = join(
            [_isp_trace_fixture_record(table) for table in ISP_XML_TABLES], "\n",
        )
        write(
            joinpath(scenario, "2026 ISP Step Change Model.xml"),
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<MasterDataSet>\n$(records)\n</MasterDataSet>\n",
        )
        config = HiveConfiguration(; hive_location = joinpath(root, "cache"))
        err = try
            build_isp_cache(config, source)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("BAD.csv", err.msg)
        @test !isfile(isp_cache_path(config))
    end
end

@testset "an empty source still gets trace_bindings views" begin
    mktempdir() do root
        model = write_isp_cache_fixture(joinpath(root, "model"))
        config = HiveConfiguration(; hive_location = joinpath(root, "cache"))
        build_isp_cache(config, model)
        db = isp_cache(config)
        try
            views = DataFrame(
                DuckDB.execute(
                    db.db,
                    "SELECT schema_name FROM duckdb_views() WHERE view_name = 'trace_bindings'",
                ),
            )
            @test sort(views.schema_name) == ["slower_growth", "step_change"]
            empty = DataFrame(
                DuckDB.execute(db.db, "SELECT count(*) AS n FROM cache_meta.trace_files"),
            )
            @test empty.n[1] == 0
        finally
            DBInterface.close!(db.db)
        end
    end
end
