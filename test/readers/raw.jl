let
    hive_dir = AEM_TEST_HIVE_DIR
    db = aem_connect(HiveConfiguration(hive_location = hive_dir, filesystem = "file"))

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
        df = read_interconnectors(retired_db, MOCK_DATE_RANGE)
        @test !("V-SN" in df.INTERCONNECTORID)
        @test !("SNOWY_RETIRED" in vcat(df.REGIONFROM, df.REGIONTO))
    end

    @testset "read_interconnectors requires a populated DISPATCHREGIONSUM" begin
        bare_dir = mktempdir()
        for table in ("INTERCONNECTOR", "INTERCONNECTORCONSTRAINT")
            cp(joinpath(hive_dir, table), joinpath(bare_dir, table); force = true)
        end
        bare_db = aem_connect(HiveConfiguration(hive_location = bare_dir, filesystem = "file"))
        err = (@test_throws ArgumentError read_interconnectors(bare_db, MOCK_DATE_RANGE)).value
        @test occursin("DISPATCHREGIONSUM", sprint(showerror, err))
    end

    @testset "static tables resolve as of the interval" begin
        versioned_dir = mktempdir()
        create_versioned_static_data(hive_dir, versioned_dir)
        vdb = aem_connect(HiveConfiguration(hive_location = versioned_dir, filesystem = "file"))
        early = DateTime(2025, 3, 1)

        maxmwin(df) = only(df[df.INTERCONNECTORID .== "IC1", :MAXMWIN])
        @test maxmwin(read_interconnectors(vdb, mock_range_at(early))) == 500.0
        @test maxmwin(read_interconnectors(vdb, mock_range_at(DateTime(2025, 8, 1)))) == 300.0

        cp_of(df) = only(df[df.DUID .== "BW01", :CONNECTIONPOINTID])
        @test cp_of(read_units(vdb, mock_range_at(early))) == "CP_BAYSW"
        @test cp_of(read_units(vdb, mock_range_at(DateTime(2025, 8, 1)))) == "CP_NEW"
        @test allunique(read_units(vdb, mock_range_at(early)).DUID)
        for units in (read_units(vdb, MOCK_DATE_RANGE), read_units(vdb, mock_range_at(early)))
            @test eltype(units.REGISTERED_FROM) == DateTime
            @test eltype(units.REGISTERED_UNTIL) == DateTime
        end
        # The older archive's stale open rows must not leak into either as-of read.
        @test only(read_units(vdb, mock_range_at(early))[read_units(vdb, mock_range_at(early)).DUID .== "BW01", :REGISTEREDCAPACITY]) == 100.0
        # A unit not yet registered as of the date is omitted.
        @test isempty(read_units(vdb, mock_range_at(DateTime(2019, 1, 1))))
    end

    @testset "read_units over a registration window" begin
        vdir = mktempdir()
        create_versioned_static_data(hive_dir, vdir)
        vwin = aem_connect(HiveConfiguration(hive_location = vdir, filesystem = "file"))
        window = read_units(vwin, DateTime(2025, 3, 1):Minute(5):(DateTime(2025, 8, 1) + Minute(5)))
        bw01 = window[window.DUID .== "BW01", :]
        # Both BW01 rows overlap the window: the earlier one supplies the attributes, the span covers both.
        @test only(bw01.CONNECTIONPOINTID) == "CP_BAYSW"
        @test only(bw01.REGISTERED_FROM) == DateTime(2020, 1, 1)
        @test only(bw01.REGISTERED_UNTIL) == DateTime(2999, 12, 31)
        @test allunique(window.DUID)
        # Production and mock types agree: the span is always TIMESTAMP, whichever reader path.
        @test eltype(window.REGISTERED_FROM) == DateTime
        @test eltype(window.REGISTERED_UNTIL) == DateTime
        # Only the first row overlaps a window ending before the change.
        before = read_units(vwin, DateTime(2025, 3, 1):Minute(5):(DateTime(2025, 6, 1) + Minute(5)))
        @test only(before[before.DUID .== "BW01", :REGISTERED_UNTIL]) == DateTime(2025, 7, 1)
        @test isempty(read_units(vwin, DateTime(2019, 1, 1):Minute(5):(DateTime(2019, 12, 31) + Minute(5))))
    end

    @testset "a mid-window region change is flagged and a loss factor change warns" begin
        # A second BW03 row from 00:10 in another region (BW03 is in QLD1), the first row left open.
        moved = damaged_cache(
            hive_dir, :DUDETAILSUMMARY,
            "INSERT INTO input SELECT * REPLACE (TIMESTAMP '2025-01-01 00:10:00' AS START_DATE, 'NSW1' AS REGIONID) FROM input WHERE DUID = 'BW03'",
        )
        window = DateTime(2025, 1, 1, 0, 5):Minute(5):DateTime(2025, 1, 1, 0, 20)
        # The earliest row is kept and the unit flagged; the NEMDE build refuses the range.
        units = @test_logs (:warn, r"change REGIONID") match_mode = :any read_units(moved, window)
        @test only(units[units.DUID .== "BW03", :REGIONID]) == "QLD1"
        @test only(subset(units, :CHANGES_IN_RANGE).DUID) == "BW03"
        @test_throws r"BW03 change REGIONID" nem_network(moved; date_range = window)
        # A changed loss factor is not an error: the earlier row's factor is used, with a warning.
        lossy = damaged_cache(
            hive_dir, :DUDETAILSUMMARY,
            "INSERT INTO input SELECT * REPLACE (TIMESTAMP '2025-01-01 00:10:00' AS START_DATE, 0.9 AS TRANSMISSIONLOSSFACTOR) FROM input WHERE DUID = 'BW03'",
        )
        @test read_units(lossy, window) isa DataFrame
        factors = @test_logs (:warn, r"Loss factors change") match_mode = :any read_loss_factors(lossy, window)
        @test only(factors[factors.DUID .== "BW03", :LOAD_LOSS_FACTOR]) == 1.0
        # Identical factors across the window stay quiet.
        same = damaged_cache(
            hive_dir, :DUDETAILSUMMARY,
            "INSERT INTO input SELECT * REPLACE (TIMESTAMP '2025-01-01 00:10:00' AS START_DATE) FROM input WHERE DUID = 'BW03'",
        )
        quiet = Test.TestLogger()
        Base.CoreLogging.with_logger(quiet) do
            read_loss_factors(same, window)
        end
        @test !any(occursin("Loss factors change", string(record.message)) for record in quiet.logs)
    end

    @testset "read_demand" begin
        df = read_demand(db, MOCK_DATE_RANGE)
        first_vic = df[(df.REGIONID .== "VIC1") .& (df.SETTLEMENTDATE .== minimum(df.SETTLEMENTDATE)), :]
        @test only(first_vic.TOTALDEMAND) == 1000.0
        # Loss-equation demand is INITIALSUPPLY + DEMANDFORECAST (mock: 990 + 10 i + 25) plus the
        # initial charging of BIDIRECTIONAL units (BW01, VIC1, INITIALMW -30 in the last interval).
        @test only(first_vic.LOSSDEMAND) == 1015.0
        last_rows = df[df.SETTLEMENTDATE .== maximum(df.SETTLEMENTDATE), :]
        @test only(last_rows[last_rows.REGIONID .== "VIC1", :LOSSDEMAND]) == 990.0 + 480 + 25 - 30
        @test all(last_rows[last_rows.REGIONID .!= "VIC1", :LOSSDEMAND] .== 990.0 + 480 + 25)
    end

    @testset "read_units" begin
        df = read_units(db, MOCK_DATE_RANGE)
        @test isdisjoint(("TECHNOLOGY", "FUELTYPE"), names(df))
        @test only(df.CO2E_ENERGY_SOURCE[df.DUID .== "BW01"]) == "Battery Storage"

        # BAYSW (station for BW01-BW04) is renamed in a later STATION archive_month
        # partition (mock_data.jl). read_units() must resolve one name per DUID —
        # not fan out into duplicate rows via the STATIONID -> STATIONNAME join.
        @test allunique(df.DUID)
        @test only(df.STATIONNAME[df.DUID .== "BW01"]) == "Bayswater Power Station"
    end

    @testset "read_bids rejects period offers without a price-band row" begin
        partial = mktempdir()
        for table in ("BIDPEROFFER_D", "BIDDAYOFFER_D", "BIDDAYOFFER")
            cp(joinpath(hive_dir, table), joinpath(partial, table))
        end
        let ddb = DuckDB.DB(), conn = DuckDB.connect(ddb)
            DuckDB.execute(conn, "SET preserve_identifier_case=true")
            table_dir = joinpath(partial, "BIDDAYOFFER_D")
            kept = DataFrame(DuckDB.execute(conn, "SELECT * FROM read_parquet('$table_dir/**/*.parquet', hive_partitioning=true)"))
            subset!(kept, :DUID => ByRow(!=("BW03")))
            rm(table_dir; recursive = true)
            DuckDB.register_data_frame(conn, kept, "tmp_table")
            DuckDB.execute(conn, "COPY (SELECT * FROM tmp_table) TO '$table_dir' (FORMAT 'PARQUET', PARTITION_BY (archive_month))")
            DuckDB.disconnect(conn)
            DuckDB.close(ddb)
        end
        partial_db = aem_connect(HiveConfiguration(hive_location = partial, filesystem = "file"))
        date_range = DateTime(2025, 1, 1, 0, 0):Dates.Minute(5):DateTime(2025, 1, 1, 1, 0)
        err = (@test_throws ArgumentError read_bids(partial_db, date_range)).value
        @test occursin("BW03", err.msg)
    end

    @testset "offer curves keep empty bands as zero-width segments" begin
        curve(direction) = offer_curve([10.0, 20.0, 30.0], [5.0, 0.0, 7.0], direction)
        kept = curve("GEN")
        @test PowerSystems.get_x_coords(kept) == [0.0, 5.0, 5.0, 12.0]
        @test PowerSystems.get_y_coords(kept) == [10.0, 20.0, 30.0]
        # LOAD curves list the bands in reverse, so segment k stays the same price band.
        load = curve("LOAD")
        @test PowerSystems.get_y_coords(load) == [30.0, 20.0, 10.0]
        @test PowerSystems.get_x_coords(load) == [0.0, 7.0, 7.0, 12.0]
    end

    @testset "read_fixed_loads" begin
        date_range = DateTime(2025, 1, 1, 0, 0):Dates.Minute(5):DateTime(2025, 1, 1, 1, 0)
        df = read_fixed_loads(db, date_range)
        @test names(df) == ["INTERVAL_DATETIME", "DUID", "DIRECTION", "FIXEDLOAD"]
        @test df.INTERVAL_DATETIME == [DateTime(2025, 1, 1, 0, 10), DateTime(2025, 1, 1, 0, 10), DateTime(2025, 1, 1, 0, 15), DateTime(2025, 1, 1, 0, 15)]
        @test df.DUID == ["BW02", "BW04", "BW02", "BW04"]
        @test all(==(50.0), df.FIXEDLOAD)
        # The stop bound is exclusive.
        @test nrow(read_fixed_loads(db, DateTime(2025, 1, 1, 0, 0):Dates.Minute(5):DateTime(2025, 1, 1, 0, 15))) == 2
        @test isempty(read_fixed_loads(db, DateTime(2025, 1, 1, 2, 0):Dates.Minute(5):DateTime(2025, 1, 1, 2, 5)))
    end

    @testset "read_mnsp_offers" begin
        # Interval ending 12:00 uses the second (rebid) offer, 11:55 the first; period = steps since 04:00.
        range = DateTime(2025, 1, 1, 11, 55):Dates.Minute(5):DateTime(2025, 1, 1, 12, 5)
        df = read_mnsp_offers(db, range)
        @test nrow(df) == 4  # intervals 11:55 and 12:00, two links; the stop bound is exclusive
        @test sort(unique(df.LINKID)) == ["BLNKTAS", "BLNKVIC"]
        @test all(==("BASSLINK"), df.PARTICIPANTID)
        before = df[(df.INTERVAL_DATETIME .== DateTime(2025, 1, 1, 11, 55)) .& (df.LINKID .== "BLNKTAS"), :]
        after = df[(df.INTERVAL_DATETIME .== DateTime(2025, 1, 1, 12, 0)) .& (df.LINKID .== "BLNKTAS"), :]
        @test only(before.MAXAVAIL) == 594
        @test only(after.MAXAVAIL) == 400
        @test only(before.PRICEBAND2) == 40
        @test only(after.PRICEBAND2) == 80
        @test only(after.BANDAVAIL2) == 100
        @test ismissing(only(after.FIXEDLOAD))
        # The last interval of the trading day ends at 04:00 the next calendar day.
        edge = read_mnsp_offers(db, DateTime(2025, 1, 2, 3, 55):Dates.Minute(5):DateTime(2025, 1, 2, 4, 5))
        @test nrow(edge) == 4
        @test_throws ArgumentError read_mnsp_offers(db, DateTime(2030, 1, 1):Dates.Minute(5):DateTime(2030, 1, 1, 1))
    end

    @testset "read_mnsp_links" begin
        links = read_mnsp_links(db, DateTime(2025, 1, 1))
        @test isempty(read_mnsp_links(db, DateTime(2020, 1, 1)))
        @test sort(links.LINKID) == ["BLNKTAS", "BLNKVIC"]
        tas = only(links[links.LINKID .== "BLNKTAS", :])
        @test (tas.INTERCONNECTORID, tas.FROMREGION, tas.TOREGION) == ("IC2", "NSW1", "VIC1")
        @test tas.TO_REGION_TLF == 0.9907
        @test tas.MAXCAPACITY == 594
    end

    @testset "months without the 1-second FCAS or regional UIGF columns read them as missing" begin
        BT = AustralianElectricityMarkets.BidType
        one_second = ("RAISE1SEC", "LOWER1SEC")
        drop(columns) = ["ALTER TABLE input DROP COLUMN IF EXISTS $c" for c in columns]
        one_second_market(df) = df.BIDTYPE .∈ Ref((BT.RAISE1SEC, BT.LOWER1SEC))
        range = MOCK_DATE_RANGE

        prices = read_fcas_prices(db, range)
        old_prices = read_fcas_prices(
            damaged_cache(hive_dir, :DISPATCHPRICE, drop([m * c for m in one_second for c in ("RRP", "ROP", "APCFLAG")])), range,
        )
        @test nrow(old_prices) == nrow(prices)
        @test all(ismissing, old_prices.RRP[one_second_market(old_prices)])
        @test isequal(old_prices[.!one_second_market(old_prices), :], prices[.!one_second_market(prices), :])

        dispatch = read_fcas_dispatch(db, range)
        old_dispatch = read_fcas_dispatch(
            damaged_cache(hive_dir, :DISPATCHLOAD, drop([m * c for m in one_second for c in ("", "ACTUALAVAILABILITY")])), range,
        )
        @test nrow(old_dispatch) == nrow(dispatch)
        @test all(ismissing, old_dispatch.TARGET[one_second_market(old_dispatch)])
        @test isequal(old_dispatch[.!one_second_market(old_dispatch), :], dispatch[.!one_second_market(dispatch), :])

        demand = read_demand(db, range)
        old_demand = read_demand(damaged_cache(hive_dir, :DISPATCHREGIONSUM, drop(["SS_SOLAR_UIGF", "SS_WIND_UIGF"])), range)
        @test all(ismissing, old_demand.SS_SOLAR_UIGF) && all(ismissing, old_demand.SS_WIND_UIGF)
        @test isequal(old_demand.TOTALDEMAND, demand.TOTALDEMAND)
    end

    @testset "read_hive date range" begin
        # The mock names months YYYY-MM and the real cache YYYY-MM-01; both must match by month.
        # DUDETAIL is cached for 2025-01 only; MNSP_DAYOFFER for 2024-12 and 2025-01.
        named_files(sql) = [m.captures[1] for m in eachmatch(r"'([^']+\.parquet)'", sql)]
        partition_files(table, month) = readdir(joinpath(hive_dir, table, "archive_month=$month"); join = true)
        partition_dirs(files) = unique(basename.(dirname.(files)))
        inside = named_files(read_hive(db, :DUDETAIL, DateTime(2025, 1, 15, 4, 5):Dates.Minute(5):DateTime(2025, 1, 15, 9)))
        @test partition_dirs(inside) == ["archive_month=2025-01"]
        @test sort(inside) == sort(partition_files("DUDETAIL", "2025-01"))
        edge = named_files(read_hive(db, :MNSP_DAYOFFER, DateTime(2024, 12, 31, 22):Dates.Minute(5):DateTime(2025, 1, 1, 2)))
        @test sort(partition_dirs(edge)) == ["archive_month=2024-12", "archive_month=2025-01"]
        @test sort(edge) == sort(vcat(partition_files("MNSP_DAYOFFER", "2024-12"), partition_files("MNSP_DAYOFFER", "2025-01")))
        # No cached month in range: the error names the months and the populate call, with no all-partitions fallback.
        uncached = (@test_throws ArgumentError read_hive(db, :DISPATCHLOAD, DateTime(2030, 1, 1):Dates.Minute(5):DateTime(2030, 1, 1, 1))).value
        @test occursin("2029-12, 2030-01", uncached.msg) && occursin("populate(db, :DISPATCHLOAD, 2029-12-01, 2030-01-31)", uncached.msg)
    end
end
