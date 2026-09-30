let
    hive_dir = AEM_TEST_HIVE_DIR
    @test isdir(hive_dir)

    config = HiveConfiguration(hive_location = hive_dir, filesystem = "file")
    db = aem_connect(config)

    @testset "read_interconnectors" begin
        df = read_interconnectors(db)
        @test df isa DataFrame
        @test nrow(df) > 0
        @test "INTERCONNECTORID" in names(df)
    end

    @testset "read_interconnectors drops an interconnector with a retired endpoint region" begin
        # A region absent from DISPATCHREGIONSUM (the authoritative "currently active" source)
        # must never resurrect as a phantom, zero-demand area - see AustralianElectricityMarkets
        # `get_bus_dataframe`, which builds its region set straight from this function's output.
        retired_dir = mktempdir()
        cp(joinpath(hive_dir, "INTERCONNECTORCONSTRAINT"), joinpath(retired_dir, "INTERCONNECTORCONSTRAINT"); force = true)
        cp(joinpath(hive_dir, "DISPATCHREGIONSUM"), joinpath(retired_dir, "DISPATCHREGIONSUM"); force = true)
        let ddb = DuckDB.DB(), conn = DuckDB.connect(ddb)
            DuckDB.execute(conn, "SET preserve_identifier_case=true")
            ic_table = joinpath(hive_dir, "INTERCONNECTOR", "archive_month=2025-01")
            df_ic = DataFrame(DuckDB.execute(conn, "SELECT * FROM read_parquet('$ic_table/*.parquet')"))
            push!(
                df_ic,
                (INTERCONNECTORID = "V-SN", REGIONFROM = "VIC1", REGIONTO = "SNOWY_RETIRED", archive_month = "2025-01"),
            )
            DuckDB.register_data_frame(conn, df_ic, "tmp_table")
            table_dir = joinpath(retired_dir, "INTERCONNECTOR")
            mkpath(table_dir)
            DuckDB.execute(conn, "COPY (SELECT * FROM tmp_table) TO '$table_dir' (FORMAT 'PARQUET', PARTITION_BY (archive_month))")
            DuckDB.execute(
                conn,
                """
                COPY (SELECT 'V-SN' AS INTERCONNECTORID, DATE '2025-01-01' AS EFFECTIVEDATE, 1 AS VERSIONNO,
                             500.0 AS MAXMWIN, 500.0 AS MAXMWOUT, 0.5 AS FROMREGIONLOSSSHARE,
                             0.01 AS LOSSCONSTANT, 0.001 AS LOSSFLOWCOEFFICIENT, 'MNSP' AS ICTYPE,
                             '2025-01' AS archive_month)
                TO '$(joinpath(retired_dir, "INTERCONNECTORCONSTRAINT"))' (FORMAT 'PARQUET', PARTITION_BY (archive_month), APPEND)
                """,
            )
        end
        retired_config = HiveConfiguration(hive_location = retired_dir, filesystem = "file")
        retired_db = aem_connect(retired_config)
        df = read_interconnectors(retired_db)
        @test !("V-SN" in df.INTERCONNECTORID)
        @test !("SNOWY_RETIRED" in vcat(df.REGIONFROM, df.REGIONTO))
    end

    @testset "read_demand" begin
        df = read_demand(db)
        @test df isa DataFrame
        @test nrow(df) > 0
        @test "REGIONID" in names(df)
        @test df.REGIONID[1] == "VIC1"
        @test df.TOTALDEMAND[1] == 1000.0
    end

    @testset "read_units" begin
        df = read_units(db)
        @test df isa DataFrame
        @test nrow(df) > 0
        @test "DUID" in names(df)
        @test "CO2E_ENERGY_SOURCE" in names(df)
        @test !("TECHNOLOGY" in names(df))
        @test !("FUELTYPE" in names(df))
        @test df.DUID[1] == "BW01"
        @test df.CO2E_ENERGY_SOURCE[1] == "Battery Storage"

        # BAYSW (station for BW01-BW04) is renamed in a later STATION archive_month
        # partition (mock_data.jl). read_units() must resolve one name per DUID —
        # not fan out into duplicate rows via the STATIONID -> STATIONNAME join.
        @test allunique(df.DUID)
        bw01_names = df.STATIONNAME[df.DUID .== "BW01"]
        @test length(bw01_names) == 1
        @test only(bw01_names) == "Bayswater Power Station"
    end

    @testset "read_energy_bids" begin
        # Use 2025 to match mock data
        date_range = DateTime(2025, 1, 1, 0, 0):Dates.Minute(5):DateTime(2025, 1, 1, 1, 0)
        df = read_energy_bids(db, date_range)
        @test df isa DataFrame
        @test nrow(df) > 0
        @test "DUID" in names(df)
        @test "MAXAVAIL" in names(df)
        @test "BW01" in df.DUID
    end

    @testset "max-partition filtering excludes stale partitions" begin
        # All other mock tables only ever have a single archive_month value, so
        # the "keep only the max partition" query idiom used throughout queries.jl
        # has never actually been exercised against genuinely stale data. Write a
        # dedicated 2-partition table directly into the test hive dir to close that gap.
        conn = DuckDB.connect(db.db)
        DuckDB.execute(conn, "SET preserve_identifier_case=true")
        table_dir = joinpath(hive_dir, "LATESTTEST")
        mkpath(table_dir)
        df = vcat(
            DataFrame(id = [1, 2], marker = ["stale", "stale"], archive_month = ["2024-01", "2024-01"]),
            DataFrame(id = [3], marker = ["current"], archive_month = ["2025-01"]),
        )
        DuckDB.register_data_frame(conn, df, "tmp_latest_test")
        DuckDB.execute(conn, "COPY (SELECT * FROM tmp_latest_test) TO '$table_dir' (FORMAT 'PARQUET', PARTITION_BY (archive_month))")
        DuckDB.unregister_table(conn, "tmp_latest_test")
        DuckDB.disconnect(conn)

        table = read_hive(db, :LATESTTEST)
        filtered = AustralianElectricityMarketsData._query(
            db,
            "SELECT * FROM $table WHERE archive_month = (SELECT max(archive_month) FROM $table)",
        )
        @test nrow(filtered) == 1
        @test filtered.marker[1] == "current"
        @test filtered.archive_month[1] == "2025-01"
    end
end
