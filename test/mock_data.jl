using DataFrames
using Dates
using DuckDB
using CSV

function create_mock_data(hive_root::String)
    db = DuckDB.DB()
    conn = DuckDB.connect(db)
    DuckDB.execute(conn, "SET preserve_identifier_case=true")

    # Helper to save a DataFrame as Hive-partitioned parquet
    function save_hive(df, table_name)
        DuckDB.register_data_frame(conn, df, "tmp_table")
        table_dir = joinpath(hive_root, string(table_name))
        mkpath(table_dir)
        DuckDB.execute(conn, "COPY tmp_table TO '$table_dir' (FORMAT 'PARQUET', PARTITION_BY (archive_month))")
        return DuckDB.unregister_table(conn, "tmp_table")
    end

    n = 6
    regions = ["VIC1", "NSW1", "QLD1", "SA1", "TAS1", "SNOWY1"]
    # Use real unit names from ISP CSVs to ensure costs are found
    duids = ["BW01", "BW02", "BW03", "BW04", "ER01", "ER02"]
    stations = ["Bayswater", "Bayswater", "Bayswater", "Bayswater", "Eraring", "Eraring"]
    station_ids = ["BAYSW", "BAYSW", "BAYSW", "BAYSW", "ERARING", "ERARING"]

    # Use 2025-01-01 to match existing tests
    test_date = Date(2025, 1, 1)
    test_datetime = DateTime(2025, 1, 1, 0, 5)

    # 1. INTERCONNECTOR
    save_hive(
        DataFrame(
            INTERCONNECTORID = ["IC$i" for i in 1:n],
            REGIONFROM = regions,
            REGIONTO = circshift(regions, 1),
            archive_month = fill("2025-01", n)
        ), :INTERCONNECTOR
    )

    # 2. INTERCONNECTORCONSTRAINT
    save_hive(
        DataFrame(
            INTERCONNECTORID = ["IC$i" for i in 1:n],
            EFFECTIVEDATE = fill(test_datetime, n),
            VERSIONNO = fill(1, n),
            MAXMWIN = fill(500.0, n),
            MAXMWOUT = fill(500.0, n),
            FROMREGIONLOSSSHARE = fill(0.1, n),
            LOSSCONSTANT = fill(0.01, n),
            LOSSFLOWCOEFFICIENT = fill(0.001, n),
            ICTYPE = fill("MNSP", n),
            archive_month = fill("2025-01", n)
        ), :INTERCONNECTORCONSTRAINT
    )

    # 3. DISPATCHREGIONSUM
    save_hive(
        DataFrame(
            SETTLEMENTDATE = fill(test_datetime, n),
            REGIONID = regions,
            TOTALDEMAND = fill(1000.0, n),
            SS_SOLAR_AVAILABILITY = fill(100.0, n),
            SS_WIND_AVAILABILITY = fill(200.0, n),
            archive_month = fill("2025-01", n)
        ), :DISPATCHREGIONSUM
    )

    # 4. DUDETAIL
    save_hive(
        DataFrame(
            DUID = duids,
            EFFECTIVEDATE = fill(test_datetime, n),
            VERSIONNO = fill(1, n),
            STATIONID = station_ids,
            REGIONID = regions,
            REGISTEREDCAPACITY = fill(100.0, n),
            MINCAPACITY = fill(10.0, n),
            MAXCAPACITY = fill(100.0, n),
            MAXRATEOFCHANGEDOWN = fill(1.0, n),
            MAXRATEOFCHANGEUP = fill(1.0, n),
            MAXSTORAGECAPACITY = fill(200.0, n),
            STORAGEIMPORTEFFICIENCYFACTOR = fill(0.9, n),
            STORAGEEXPORTEFFICIENCYFACTOR = fill(0.9, n),
            archive_month = fill("2025-01", n)
        ), :DUDETAIL
    )

    # 5. DUDETAILSUMMARY
    save_hive(
        DataFrame(
            DUID = duids,
            START_DATE = fill(DateTime(2020, 1, 1), n),
            END_DATE = Union{DateTime, Missing}[missing for i in 1:n],
            STATIONID = station_ids,
            archive_month = fill("2025-01", n)
        ), :DUDETAILSUMMARY
    )

    # 6. STATION
    save_hive(
        DataFrame(
            STATIONID = ["BAYSW", "ERARING", "ST3", "ST4", "ST5", "ST6"],
            STATIONNAME = ["Bayswater", "Eraring", "Station 3", "Station 4", "Station 5", "Station 6"],
            POSTCODE = fill("3000", n),
            archive_month = fill("2025-01", n)
        ), :STATION
    )

    # 7. STATIONOPERATINGSTATUS
    save_hive(
        DataFrame(
            STATUS = fill("COMMISSIONED", n),
            STATIONID = ["BAYSW", "ERARING", "ST3", "ST4", "ST5", "ST6"],
            EFFECTIVEDATE = fill(test_datetime, n),
            VERSIONNO = fill(1, n),
            archive_month = fill("2025-01", n)
        ), :STATIONOPERATINGSTATUS
    )

    # 8. GENUNITS
    energy_sources = fill("Black coal", n)
    energy_sources[1] = "Battery Storage"
    energy_sources[2] = "Hydro"
    genset_ids = ["GEN$i" for i in 1:n]
    save_hive(
        DataFrame(
            GENSETID = genset_ids,
            CO2E_ENERGY_SOURCE = energy_sources,
            CO2E_EMISSIONS_FACTOR = fill(0.5, n),
            archive_month = fill("2025-01", n)
        ), :GENUNITS
    )

    # 9. DUALLOC
    save_hive(
        DataFrame(
            DUID = duids,
            GENSETID = genset_ids,
            LASTCHANGED = fill(test_datetime, n),
            VERSIONNO = fill(1, n),
            archive_month = fill("2025-01", n)
        ), :DUALLOC
    )

    # 10. BIDPEROFFER_D
    bid_per_offer = DataFrame(
        SETTLEMENTDATE = fill(test_date, n),
        BIDTYPE = fill("ENERGY", n),
        INTERVAL_DATETIME = fill(test_datetime, n),
        VERSIONNO = fill(1, n),
        DUID = duids,
        DIRECTION = fill("GEN", n),
        MAXAVAIL = fill(100.0, n),
        archive_month = fill("2025-01", n)
    )
    for i in 1:10
        bid_per_offer[!, "BANDAVAIL$i"] = fill(10.0, n)
    end
    save_hive(bid_per_offer, :BIDPEROFFER_D)

    # 11. BIDDAYOFFER_D
    bid_day_offer = DataFrame(
        BIDTYPE = fill("ENERGY", n),
        SETTLEMENTDATE = fill(test_date, n),
        DUID = duids,
        DIRECTION = fill("GEN", n),
        MINIMUMLOAD = fill(0.0, n),
        DAILYENERGYCONSTRAINT = fill(1000.0, n),
        VERSIONNO = fill(1, n),
        archive_month = fill("2025-01", n)
    )
    for i in 1:10
        bid_day_offer[!, "PRICEBAND$i"] = fill(50.0 + i, n)
    end
    save_hive(bid_day_offer, :BIDDAYOFFER_D)

    return DuckDB.disconnect(conn)
end
