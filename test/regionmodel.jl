@testset "Test RegionModel" begin

    required_tables = table_requirements(RegionalNetworkConfiguration())

    hive_dir = get(ENV, "AEM_TEST_HIVE_DIR", "")
    config = isempty(hive_dir) ? HiveConfiguration() : HiveConfiguration(hive_location = hive_dir, filesystem = "file")
    db = aem_connect(duckdb(), config)

    map(
        required_tables
    ) do table
        if isempty(hive_dir)
            fetch_table_data(table, Date(2025, 1, 1):Date(2025, 1, 1))
        end
        table = read_hive(db, table) |> x -> (
            TidierDB.@collect(
                TidierDB.@head(
                    x, 5
                )
            )
        )
        @test nrow(table) == 5
    end

    system = nem_system(db, RegionalNetworkConfiguration())

    areas = get_components(Area, system) |> collect .|> get_name |> sort!
    @test areas == ["NSW1", "QLD1", "SA1", "SNOWY1", "TAS1", "VIC1"]

    hydro_generators = get_components(HydroDispatch, system)
    @test !isempty(hydro_generators)

end
