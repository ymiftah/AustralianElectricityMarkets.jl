@testset "build_isp_cache builds every table of every scenario" begin
    mktempdir() do root
        model = write_isp_cache_fixture(joinpath(root, "model"))
        config = HiveConfiguration(; hive_location = joinpath(root, "cache"))
        path = build_isp_cache(config, model)
        @test path == isp_cache_path(config)
        @test isfile(path)

        db = isp_cache(config; read_only = true)
        try
            inventory = DataFrame(
                DuckDB.execute(
                    db.db,
                    """
                    SELECT scenario, table_name, row_count, column_count, columns_json,
                           source_path, xml_sha256
                    FROM cache_meta.xml_tables ORDER BY scenario, table_name
                    """,
                ),
            )
            @test nrow(inventory) == 2 * length(ISP_XML_TABLES)
            @test sort(unique(inventory.scenario)) == ["slower_growth", "step_change"]
            @test all(>=(1), inventory.column_count)
            @test all(==(3), inventory.column_count[inventory.table_name .== "t_text"])

            for row in eachrow(inventory)
                @test !isabspath(row.source_path)
                @test row.xml_sha256 == AustralianElectricityMarketsData._isp_sha256(
                    joinpath(model, row.source_path)
                )
            end

            for scenario in ("step_change", "slower_growth")
                stored = DataFrame(
                    DuckDB.execute(
                        db.db,
                        """
                        SELECT table_name FROM information_schema.tables
                        WHERE table_schema = '$scenario' AND table_type = 'BASE TABLE'
                        ORDER BY table_name
                        """,
                    ),
                )
                @test sort(stored.table_name) == sort(collect(ISP_XML_TABLES))
            end

            checks = DataFrame(
                DuckDB.execute(
                    db.db,
                    "SELECT count(*) AS n FROM cache_meta.row_count_checks",
                ),
            )
            @test checks.n[1] == 2 * length(ISP_XML_TABLES)
            @test sum(inventory.row_count[inventory.table_name .== "t_object"]) == 5
        finally
            DBInterface.close!(db.db)
        end
    end
end

@testset "build_isp_cache is idempotent and rebuilds on force_new" begin
    mktempdir() do root
        model = write_isp_cache_fixture(joinpath(root, "model"))
        config = HiveConfiguration(; hive_location = joinpath(root, "cache"))
        path = build_isp_cache(config, model)
        first_mtime = mtime(path)
        sleep(1.1)
        @test build_isp_cache(config, model) == path
        @test mtime(path) == first_mtime
        build_isp_cache(config, model; force_new = true)
        @test mtime(path) > first_mtime
    end
end

@testset "a failed build leaves no database" begin
    mktempdir() do root
        model = joinpath(root, "model")
        folder = joinpath(model, "2026 ISP Step Change")
        mkpath(folder)
        write(joinpath(folder, "broken.xml"), "<NotAPlexosExport></NotAPlexosExport>")
        config = HiveConfiguration(; hive_location = joinpath(root, "cache"))
        @test_throws ArgumentError build_isp_cache(config, model)
        @test !isfile(isp_cache_path(config))
        leftovers = filter(
            name -> occursin(".building-", name),
            readdir(dirname(isp_cache_path(config)); join = true),
        )
        @test isempty(leftovers)
    end
end

@testset "scenario names are derived from the folder and must be unique" begin
    mktempdir() do root
        model = joinpath(root, "model")
        a = joinpath(model, "2026 ISP Step Change")
        b = joinpath(model, "2026 ISP step-change")
        mkpath(a)
        mkpath(b)
        write(joinpath(a, "a.xml"), "<MasterDataSet><t_object object_id=\"1\"/></MasterDataSet>")
        write(joinpath(b, "b.xml"), "<MasterDataSet><t_object object_id=\"1\"/></MasterDataSet>")
        config = HiveConfiguration(; hive_location = joinpath(root, "cache"))
        @test_throws ArgumentError build_isp_cache(config, model)
    end
end

@testset "ISP_XML_TABLES holds the 27 PLEXOS tables" begin
    @test length(ISP_XML_TABLES) == 27
    @test all(startswith("t_"), ISP_XML_TABLES)
    @test length(unique(ISP_XML_TABLES)) == 27
end

@testset "_isp_archive_entry_path rejects escapes" begin
    dir = mktempdir()
    @test AustralianElectricityMarketsData._isp_archive_entry_path(dir, "a/b.xml") ==
        normpath(joinpath(dir, "a", "b.xml"))
    @test_throws ArgumentError AustralianElectricityMarketsData._isp_archive_entry_path(
        dir, "../model2/evil.xml",
    )
    @test_throws ArgumentError AustralianElectricityMarketsData._isp_archive_entry_path(
        dir, "/etc/passwd",
    )
end

@testset "a failure in a later scenario leaves no database" begin
    mktempdir() do root
        model = write_isp_cache_fixture(joinpath(root, "model"))
        broken = joinpath(model, "2026 ISP Zebra")
        mkpath(broken)
        write(joinpath(broken, "Broken.xml"), "<NotAPlexosExport></NotAPlexosExport>")
        config = HiveConfiguration(; hive_location = joinpath(root, "cache"))
        @test_throws ArgumentError build_isp_cache(config, model)
        @test !isfile(isp_cache_path(config))
        @test isempty(
            filter(
                name -> occursin(".building-", name),
                readdir(dirname(isp_cache_path(config))),
            ),
        )
    end
end

@testset "a failed force_new rebuild keeps the previous database" begin
    mktempdir() do root
        model = write_isp_cache_fixture(joinpath(root, "model"))
        config = HiveConfiguration(; hive_location = joinpath(root, "cache"))
        path = build_isp_cache(config, model)
        broken = joinpath(model, "2026 ISP Zebra")
        mkpath(broken)
        write(joinpath(broken, "Broken.xml"), "<NotAPlexosExport></NotAPlexosExport>")
        @test_throws ArgumentError build_isp_cache(config, model; force_new = true)
        @test isfile(path)
        db = isp_cache(config)
        try
            stored = DataFrame(
                DuckDB.execute(db.db, "SELECT count(*) AS n FROM cache_meta.xml_tables"),
            )
            @test stored.n[1] == 2 * length(ISP_XML_TABLES)
        finally
            DBInterface.close!(db.db)
        end
    end
end

@testset "stale build files are swept and foreign databases are rejected" begin
    mktempdir() do root
        model = write_isp_cache_fixture(joinpath(root, "model"))
        config = HiveConfiguration(; hive_location = joinpath(root, "cache"))
        target = isp_cache_path(config)
        mkpath(dirname(target))
        stale = target * ".building-1"
        write(stale, "junk")
        stale_file = Base.Filesystem.open(stale, Base.Filesystem.JL_O_RDONLY)
        try
            Base.Filesystem.futime(stale_file, time() - 7200, time() - 7200)
        finally
            close(stale_file)
        end
        fresh = target * ".building-2"
        write(fresh, "junk")

        foreign = target
        db = DuckDB.DB(foreign)
        DuckDB.execute(db, "CREATE TABLE junk (a INTEGER)")
        DBInterface.close!(db)
        @test_throws ArgumentError build_isp_cache(config, model)
        @test !isfile(stale)
        @test isfile(fresh)

        rm(fresh)
        build_isp_cache(config, model; force_new = true)
        @test isfile(target)
    end
end

@testset "reserved schema names are rejected" begin
    @test_throws ArgumentError AustralianElectricityMarketsData._isp_scenario_name(
        "2026 ISP Cache Meta",
    )
    @test_throws ArgumentError AustralianElectricityMarketsData._isp_scenario_name(
        "2026 ISP Traces",
    )
end

@testset "isp_cache opens read-only by default" begin
    mktempdir() do root
        model = write_isp_cache_fixture(joinpath(root, "model"))
        config = HiveConfiguration(; hive_location = joinpath(root, "cache"))
        build_isp_cache(config, model)
        db = isp_cache(config)
        try
            @test_throws Exception DuckDB.execute(db.db, "CREATE SCHEMA written")
        finally
            DBInterface.close!(db.db)
        end
    end
end

@testset "populate_isp builds from a local archive without downloading" begin
    mktempdir() do root
        source = joinpath(root, "Downloads")
        mkpath(source)
        config = HiveConfiguration(; hive_location = joinpath(root, "cache"))
        xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<MasterDataSet>\n" *
            join([_isp_trace_fixture_record(table) for table in ISP_XML_TABLES], "\n") *
            "\n</MasterDataSet>\n"
        zip_path = joinpath(source, "some browser name.zip")
        ZipArchives = AustralianElectricityMarketsData.ZipArchives
        ZipArchives.ZipWriter(zip_path) do writer
            ZipArchives.zip_writefile(
                writer, "2026 ISP Model/2026 ISP Step Change/2026 ISP Step Change Model.xml", codeunits(xml)
            )
        end
        release = ISPRelease(
            "test release", Date(2026, 9, 28), "https://example.test",
            [
                ISPArchive(
                    :model, "2026-isp-model.zip", filesize(zip_path),
                    AustralianElectricityMarketsData._isp_sha256(zip_path), "rev",
                    "https://example.test/model"
                ),
            ],
        )
        downloaded = Ref(false)
        path = populate_isp(
            config, source; release,
            download! = (url, path) -> (downloaded[] = true; error("download attempted")),
        )
        @test path == isp_cache_path(config)
        @test isfile(path)
        @test !downloaded[]
        db = isp_cache(config)
        try
            stored = DataFrame(
                DuckDB.execute(
                    db.db,
                    "SELECT DISTINCT scenario FROM cache_meta.xml_tables",
                ),
            )
            @test stored.scenario == ["step_change"]
        finally
            DBInterface.close!(db.db)
        end
    end
end

@testset "scenario names come from the XML's folder under a wrapper directory" begin
    mktempdir() do root
        model = joinpath(root, "model")
        folder = joinpath(model, "2026 ISP Model", "2026 ISP Step Change")
        mkpath(folder)
        records = join(
            [_isp_trace_fixture_record(table) for table in ISP_XML_TABLES], "\n",
        )
        write(
            joinpath(folder, "2026 ISP Step Change Model.xml"),
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<MasterDataSet>\n$(records)\n</MasterDataSet>\n",
        )
        config = HiveConfiguration(; hive_location = joinpath(root, "cache"))
        build_isp_cache(config, model)
        db = isp_cache(config)
        try
            stored = DataFrame(
                DuckDB.execute(
                    db.db,
                    "SELECT DISTINCT scenario FROM cache_meta.xml_tables",
                ),
            )
            @test stored.scenario == ["step_change"]
        finally
            DBInterface.close!(db.db)
        end
    end
end
