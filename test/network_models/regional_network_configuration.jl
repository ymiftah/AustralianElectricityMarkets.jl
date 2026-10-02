@testset "RegionalNetworkConfiguration" begin

    required_tables = table_requirements(RegionalNetworkConfiguration())

    hive_dir = AEM_TEST_HIVE_DIR
    config = isempty(hive_dir) ? HiveConfiguration() : HiveConfiguration(hive_location = hive_dir, filesystem = "file")
    db = aem_connect(config)

    @testset "Table Requirements and Reading" begin
        map(
            required_tables
        ) do table
            if isempty(hive_dir)
                populate(db, table, Date(2025, 1, 1), Date(2025, 1, 1))
            end
            source = read_hive(db, table)
            df = AustralianElectricityMarkets._query(db, "SELECT * FROM $source LIMIT 5")
            @test nrow(df) == 5
        end
    end

end
