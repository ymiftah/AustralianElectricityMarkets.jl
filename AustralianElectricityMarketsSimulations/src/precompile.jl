# Precompile workload: replicate_range and replicate_interval on a generated mock hive in a temporary directory.
@setup_workload begin
    t1, t2 = DateTime(2025, 1, 1, 0, 5), DateTime(2025, 1, 1, 0, 10)
    @compile_workload begin
        mktempdir() do dir
            hive = joinpath(dir, "hive")
            AustralianElectricityMarkets._write_mock_hive(hive; complete_inputs = true)
            AustralianElectricityMarkets._write_mock_interconnector_results(hive)
            db = aem_connect(HiveConfiguration(hive_location = hive, filesystem = "file"))
            Logging.with_logger(Logging.NullLogger()) do
                replicate_range(db, t1, t2; output_dir = joinpath(dir, "range"))
                replicate_interval(db, t1)
            end
            close(db.db)
        end
    end
end
