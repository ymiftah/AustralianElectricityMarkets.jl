using DataFrames, Statistics

@testset "Historical regions and loss-reader keywords" begin
    db = damaged_cache(
        AEM_TEST_HIVE_DIR, :DISPATCHREGIONSUM,
        "DELETE FROM input WHERE REGIONID = 'SNOWY1' AND SETTLEMENTDATE >= TIMESTAMP '2025-01-01 00:15'",
    )
    early = DateTime(2025, 1, 1, 0, 10)
    late = DateTime(2025, 1, 1, 0, 20)
    regions(df) = Set(vcat(df.REGIONFROM, df.REGIONTO))
    @test "SNOWY1" in regions(read_interconnectors(db; as_of = early))
    @test !("SNOWY1" in regions(read_interconnectors(db; as_of = late)))
    @test !("SNOWY1" in regions(read_interconnectors(db)))
    buses = AustralianElectricityMarkets.RegionModel.get_bus_dataframe(db; as_of = early)
    @test "SNOWY1" in buses.region
    late_buses = AustralianElectricityMarkets.RegionModel.get_bus_dataframe(db; as_of = late)
    @test !("SNOWY1" in late_buses.region)
    @test_throws ArgumentError read_interconnectors(db; as_of = Date(2024, 1, 1))
    for reader in (
            read_interconnector_loss_breakpoints, read_interconnector_demand_coefficients,
            read_interconnector_loss_parameters,
        )
        @test isequal(reader(db; as_of = early), reader(db, early))
        @test isequal(reader(db; as_of = Date(early)), reader(db, Date(early)))
    end
end

@testset "SQL ceiling preserves Julia bucket boundaries" begin
    db = aem_connect(HiveConfiguration(hive_location = AEM_TEST_HIVE_DIR))
    stamps = [
        DateTime(2024, 12, 31, 23, 59), DateTime(2025, 1, 1),
        DateTime(2025, 1, 1, 0, 5), DateTime(2025, 1, 1, 0, 15),
        DateTime(2025, 1, 1, 23, 59), DateTime(2025, 2, 1),
    ]
    reader = AustralianElectricityMarkets.Readers
    DuckDB.register_data_frame(db.db, DataFrame(stamp = stamps), "bucket_stamps")
    try
        for resolution in (Millisecond(7), Minute(5), Minute(15), Hour(7), Day(3), Week(2), Month(2), Year(2))
            bucket = reader._ceil_timestamp_sql("stamp", resolution)
            got = DataFrame(DuckDB.execute(db.db, "SELECT $bucket AS stamp FROM bucket_stamps"))
            @test got.stamp == ceil.(stamps, resolution)
        end
        @test_throws ArgumentError reader._ceil_timestamp_sql("stamp", Minute(0))
    finally
        DuckDB.unregister_table(db.db, "bucket_stamps")
    end
end

@testset "Demand aggregation keeps nulls, charging and range boundaries" begin
    db = damaged_cache(
        AEM_TEST_HIVE_DIR, :DISPATCHREGIONSUM,
        "UPDATE input SET INITIALSUPPLY = NULL WHERE REGIONID = 'NSW1'",
    )
    start = DateTime(2025, 1, 1)
    df = read_demand(db, (start + Minute(7), start + Minute(31)); resolution = Minute(15))
    nsw = df[df.REGIONID .== "NSW1", :]
    @test nsw.SETTLEMENTDATE == [start + Minute(15), start + Minute(30)]
    @test nsw.TOTALDEMAND == [1020.0, 1050.0]
    @test all(isnan, nsw.LOSSDEMAND)
    @test isempty(read_demand(db, (start + Day(1), start + Day(2))))
end

@testset "Bid aggregation preserves band order, directions and missing values" begin
    db = damaged_cache(
        AEM_TEST_HIVE_DIR, :BIDDAYOFFER_D,
        "CREATE OR REPLACE TABLE input AS SELECT PRICEBAND10, * EXCLUDE (PRICEBAND10) FROM input",
    )
    db = damaged_cache(
        db.config.hive_location, :BIDPEROFFER_D,
        "CREATE OR REPLACE TABLE input AS SELECT BANDAVAIL10, * EXCLUDE (BANDAVAIL10) REPLACE (INTERVAL_DATETIME - INTERVAL '10 minutes' AS INTERVAL_DATETIME) FROM input",
    )
    db = damaged_cache(
        db.config.hive_location, :BIDPEROFFER_D,
        "UPDATE input SET BANDAVAIL1 = EXTRACT(MINUTE FROM INTERVAL_DATETIME), BANDAVAIL2 = NULL WHERE BIDTYPE = 'ENERGY'",
    )
    start = DateTime(2025, 1, 1)
    bids = read_bids(db, (start - Minute(15), start + Minute(16)); resolution = Minute(15))
    unit = sort(bids[bids.DUID .== "BW01", :], [:INTERVAL_DATETIME, :DIRECTION])
    @test Set(unit.DIRECTION) == Set(["GEN", "LOAD"])
    for direction in ("GEN", "LOAD")
        rows = unit[unit.DIRECTION .== direction, :]
        @test rows.INTERVAL_DATETIME == [start, start + Minute(15)]
        @test rows.MAXAVAIL ≈ [101.0, 104.0]
        @test rows.BANDAVAILARRAY[2][1] == 10.0
        @test isnan(rows.BANDAVAILARRAY[2][2])
        @test rows.PRICEBANDARRAY[2] == collect(51.0:60.0)
    end
    @test isempty(read_bids(db, (start + Day(1), start + Day(2))))
    missing_prices = damaged_cache(
        db.config.hive_location, :BIDDAYOFFER_D,
        "DELETE FROM input WHERE DUID = 'BW01' AND DIRECTION = 'LOAD' AND BIDTYPE = 'ENERGY'",
    )
    @test_throws r"missing price bids.*BW01" read_bids(missing_prices, (start, start + Minute(16)); resolution = Minute(15))
end

@testset "Latest bid versions and aggregation policies remain distinct" begin
    start = DateTime(2025, 1, 1)
    range = (start + Minute(15), start + Minute(16))
    db = damaged_cache(
        AEM_TEST_HIVE_DIR, :BIDPEROFFER_D,
        """
        INSERT INTO input
        SELECT * REPLACE (2 AS VERSIONNO, 222.0 AS MAXAVAIL)
        FROM input WHERE BIDTYPE = 'ENERGY' AND DUID = 'BW01' AND DIRECTION = 'GEN'
            AND INTERVAL_DATETIME = TIMESTAMP '2025-01-01 00:10'
        """,
    )
    db = damaged_cache(
        db.config.hive_location, :BIDDAYOFFER_D,
        """
        INSERT INTO input
        SELECT * REPLACE (2 AS VERSIONNO, 123.0 AS PRICEBAND1)
        FROM input WHERE BIDTYPE = 'ENERGY' AND DUID = 'BW01' AND DIRECTION = 'GEN'
        """,
    )
    averaged = read_bids(db, range; resolution = Minute(15))
    maximums = read_energy_bids(db, range; resolution = Minute(15))
    gen(df) = only(eachrow(df[(df.DUID .== "BW01") .& (df.DIRECTION .== "GEN"), :]))
    load(df) = only(eachrow(df[(df.DUID .== "BW01") .& (df.DIRECTION .== "LOAD"), :]))
    @test gen(averaged).MAXAVAIL == 142.0
    @test gen(maximums).MAXAVAIL == 222.0
    @test gen(averaged).PRICEBANDARRAY[1] == 123.0
    @test load(averaged).MAXAVAIL == 102.0
    @test load(averaged).PRICEBANDARRAY[1] == 51.0
    raw = read_bids(db, (start + Minute(10), start + Minute(11)))
    @test gen(raw).MAXAVAIL == 222.0
end

@testset "Ceiled bids retain their trading-day price keys" begin
    db = damaged_cache(
        AEM_TEST_HIVE_DIR, :BIDPEROFFER_D,
        """
        CREATE OR REPLACE TABLE input AS
        SELECT * REPLACE (
            CASE WHEN INTERVAL_DATETIME = TIMESTAMP '2025-01-01 00:00'
                THEN DATE '2024-12-31' ELSE DATE '2025-01-01' END AS SETTLEMENTDATE,
            INTERVAL_DATETIME + INTERVAL '4 hours' AS INTERVAL_DATETIME
        ) FROM input WHERE DUID = 'BW01' AND BIDTYPE = 'ENERGY'
            AND INTERVAL_DATETIME <= TIMESTAMP '2025-01-01 00:05'
        """,
    )
    db = damaged_cache(
        db.config.hive_location, :BIDDAYOFFER_D,
        """
        INSERT INTO input SELECT * REPLACE (DATE '2024-12-31' AS SETTLEMENTDATE, 777.0 AS PRICEBAND1)
        FROM input WHERE DUID = 'BW01' AND BIDTYPE = 'ENERGY'
        """,
    )
    bids = read_bids(db, (DateTime(2025, 1, 1, 4), DateTime(2025, 1, 1, 4, 16)); resolution = Minute(15))
    gen = sort(bids[bids.DIRECTION .== "GEN", :], :INTERVAL_DATETIME)
    @test gen.INTERVAL_DATETIME == [DateTime(2025, 1, 1, 4), DateTime(2025, 1, 1, 4, 15)]
    @test Date.(gen.SETTLEMENTDATE) == [Date(2024, 12, 31), Date(2025, 1, 1)]
    @test first.(gen.PRICEBANDARRAY) == [777.0, 51.0]
end

@testset "FCAS readers preserve market and direction keys" begin
    db = aem_connect(HiveConfiguration(hive_location = AEM_TEST_HIVE_DIR))
    start = DateTime(2025, 1, 1)
    types = [BidType.RAISE6SEC, BidType.RAISEREG]
    bids = read_fcas_bids(db, (start + Minute(15), start + Minute(16)), types; resolution = Minute(15))
    @test Set(bids.BIDTYPE) == Set(types)
    battery = bids[bids.DUID .== "BW01", :]
    @test nrow(battery) == 4
    @test all(==(collect(51.0:60.0)), battery.PRICEBANDARRAY)
    @test all(==(10), length.(battery.BANDAVAILARRAY))
end
