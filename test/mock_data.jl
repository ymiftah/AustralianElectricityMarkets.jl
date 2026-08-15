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
        DuckDB.execute(conn, "COPY (SELECT * FROM tmp_table) TO '$table_dir' (FORMAT 'PARQUET', PARTITION_BY (archive_month))")
        return DuckDB.unregister_table(conn, "tmp_table")
    end

    n = 6
    regions = ["VIC1", "NSW1", "QLD1", "SA1", "TAS1", "SNOWY1"]
    duids = ["BW01", "BW02", "BW03", "BW04", "ER01", "ER02"]
    stations = ["Bayswater", "Bayswater", "Bayswater", "Bayswater", "Eraring", "Eraring"]
    station_ids = ["BAYSW", "BAYSW", "BAYSW", "BAYSW", "ERARING", "ERARING"]

    test_date = Date(2025, 1, 1)
    base_datetime = DateTime(2025, 1, 1, 0, 0)

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
            EFFECTIVEDATE = fill(base_datetime, n),
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

    # 3. DISPATCHREGIONSUM (49 intervals of 5 minutes = 4 hours)
    intervals = 0:48
    df_demand = DataFrame()
    for i in intervals
        t = base_datetime + Minute(5 * i)
        append!(
            df_demand, DataFrame(
                SETTLEMENTDATE = fill(t, n),
                REGIONID = regions,
                TOTALDEMAND = fill(1000.0 + 10 * i, n),
                SS_SOLAR_AVAILABILITY = fill(100.0 + i, n),
                SS_WIND_AVAILABILITY = fill(200.0 - i, n),
                archive_month = fill("2025-01", n)
            )
        )
    end
    save_hive(df_demand, :DISPATCHREGIONSUM)

    # 4. DUDETAIL
    save_hive(
        DataFrame(
            DUID = duids,
            EFFECTIVEDATE = fill(base_datetime, n),
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

    # 6. STATION. Includes a second, later archive_month partition renaming
    # BAYSW — real NEMWEB STATION data does this over time. Exercises
    # read_units()'s STATIONID -> STATIONNAME "latest archive_month wins"
    # resolution (rather than fanning out into duplicate rows per DUID).
    save_hive(
        vcat(
            DataFrame(
                STATIONID = ["BAYSW", "ERARING", "ST3", "ST4", "ST5", "ST6"],
                STATIONNAME = ["Bayswater", "Eraring", "Station 3", "Station 4", "Station 5", "Station 6"],
                POSTCODE = fill("3000", n),
                archive_month = fill("2025-01", n)
            ),
            DataFrame(
                STATIONID = ["BAYSW"],
                STATIONNAME = ["Bayswater Power Station"],
                POSTCODE = ["3000"],
                archive_month = ["2025-02"]
            ),
        ), :STATION
    )

    # 7. STATIONOPERATINGSTATUS
    save_hive(
        DataFrame(
            STATUS = fill("COMMISSIONED", n),
            STATIONID = ["BAYSW", "ERARING", "ST3", "ST4", "ST5", "ST6"],
            EFFECTIVEDATE = fill(base_datetime, n),
            VERSIONNO = fill(1, n),
            archive_month = fill("2025-01", n)
        ), :STATIONOPERATINGSTATUS
    )

    # 8. GENUNITS
    energy_sources = fill("Black coal", n)
    energy_sources[1] = "Battery Storage"
    energy_sources[2] = "Hydro"
    energy_sources[3] = "Solar"
    energy_sources[4] = "Wind"
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
            LASTCHANGED = fill(base_datetime, n),
            VERSIONNO = fill(1, n),
            archive_month = fill("2025-01", n)
        ), :DUALLOC
    )

    # 10. BIDPEROFFER_D (49 intervals)
    fcas_bid_types = ["RAISE6SEC", "LOWER6SEC", "RAISE60SEC", "LOWER60SEC", "RAISE5MIN", "LOWER5MIN", "RAISEREG", "LOWERREG"]
    trapezium_cols = ["ENABLEMENTMIN", "LOWBREAKPOINT", "HIGHBREAKPOINT", "ENABLEMENTMAX", "ROCUP", "ROCDOWN"]
    df_bid_per_offer = DataFrame()
    for i in intervals
        t = base_datetime + Minute(5 * i)
        # Standard GEN bids for everyone
        tmp_gen = DataFrame(
            SETTLEMENTDATE = fill(test_date, n),
            BIDTYPE = fill("ENERGY", n),
            INTERVAL_DATETIME = fill(t, n),
            VERSIONNO = fill(1, n),
            DUID = duids,
            DIRECTION = fill("GEN", n),
            MAXAVAIL = fill(100.0 + i, n),
            archive_month = fill("2025-01", n)
        )
        # LOAD bids for the battery (BW01)
        tmp_load = DataFrame(
            SETTLEMENTDATE = [test_date],
            BIDTYPE = ["ENERGY"],
            INTERVAL_DATETIME = [t],
            VERSIONNO = [1],
            DUID = ["BW01"],
            DIRECTION = ["LOAD"],
            MAXAVAIL = [100.0 + i],
            archive_month = ["2025-01"]
        )
        tmp = vcat(tmp_gen, tmp_load)
        for b in 1:10
            tmp[!, "BANDAVAIL$b"] = fill(10.0, nrow(tmp))
        end
        for col in trapezium_cols
            tmp[!, col] = fill(missing, nrow(tmp))
        end

        # FCAS GEN bids for everyone, one block per market
        tmp_fcas = DataFrame()
        for bid_type in fcas_bid_types
            block = DataFrame(
                SETTLEMENTDATE = fill(test_date, n),
                BIDTYPE = fill(bid_type, n),
                INTERVAL_DATETIME = fill(t, n),
                VERSIONNO = fill(1, n),
                DUID = duids,
                DIRECTION = fill("GEN", n),
                MAXAVAIL = fill(20.0 + i, n),
                archive_month = fill("2025-01", n),
                ENABLEMENTMIN = fill(20.0, n),
                LOWBREAKPOINT = fill(30.0, n),
                HIGHBREAKPOINT = fill(90.0, n),
                ENABLEMENTMAX = fill(100.0, n),
                ROCUP = fill(bid_type in ("RAISEREG", "LOWERREG") ? 1.0 : missing, n),
                ROCDOWN = fill(bid_type in ("RAISEREG", "LOWERREG") ? 1.0 : missing, n),
            )
            for b in 1:10
                block[!, "BANDAVAIL$b"] = fill(10.0, nrow(block))
            end
            append!(tmp_fcas, block; promote = true)
        end

        append!(df_bid_per_offer, vcat(tmp, tmp_fcas); promote = true)
    end
    save_hive(df_bid_per_offer, :BIDPEROFFER_D)

    # 11. BIDDAYOFFER_D (Daily)
    bid_day_offer_gen = DataFrame(
        BIDTYPE = fill("ENERGY", n),
        SETTLEMENTDATE = fill(test_date, n),
        DUID = duids,
        DIRECTION = fill("GEN", n),
        MINIMUMLOAD = fill(0.0, n),
        DAILYENERGYCONSTRAINT = fill(1000.0, n),
        VERSIONNO = fill(1, n),
        archive_month = fill("2025-01", n)
    )
    bid_day_offer_load = DataFrame(
        BIDTYPE = ["ENERGY"],
        SETTLEMENTDATE = [test_date],
        DUID = ["BW01"],
        DIRECTION = ["LOAD"],
        MINIMUMLOAD = [0.0],
        DAILYENERGYCONSTRAINT = [1000.0],
        VERSIONNO = [1],
        archive_month = ["2025-01"]
    )
    bid_day_offer_fcas = DataFrame()
    for bid_type in fcas_bid_types
        append!(
            bid_day_offer_fcas, DataFrame(
                BIDTYPE = fill(bid_type, n),
                SETTLEMENTDATE = fill(test_date, n),
                DUID = duids,
                DIRECTION = fill("GEN", n),
                MINIMUMLOAD = fill(0.0, n),
                DAILYENERGYCONSTRAINT = fill(1000.0, n),
                VERSIONNO = fill(1, n),
                archive_month = fill("2025-01", n)
            )
        )
    end
    bid_day_offer = vcat(bid_day_offer_gen, bid_day_offer_load, bid_day_offer_fcas)
    for i in 1:10
        bid_day_offer[!, "PRICEBAND$i"] = fill(50.0 + i, nrow(bid_day_offer))
    end
    save_hive(bid_day_offer, :BIDDAYOFFER_D)

    # FCAS requirements are generic-constraint-based (RESERVE has been unpopulated by AEMO
    # since Dec 2003 - see read_fcas_requirements docstring): one governing GENCONID per
    # (region, market), DISPATCHCONSTRAINT.RHS carries the enforced requirement quantity, and
    # DISPATCH_FCAS_REQ.MARGINALVALUE sums (trivially here, one constraint per region/market)
    # to the DISPATCHPRICE regional FCAS price.
    contingency_types = ["RAISE6SEC", "LOWER6SEC", "RAISE60SEC", "LOWER60SEC", "RAISE5MIN", "LOWER5MIN"]
    regulation_types = ["RAISEREG", "LOWERREG"]
    requirement_mw(bid_type) = bid_type in regulation_types ? 30.0 : 50.0
    marginal_value(bid_type) = bid_type in regulation_types ? 2.25 : 5.5

    # 12. GENCONDATA (one generic constraint per region/market, joined only for its
    # human-readable DESCRIPTION/CONSTRAINTTYPE)
    gencon_ids = ["F_$(region)_$(bid_type)" for region in regions for bid_type in fcas_bid_types]
    save_hive(
        DataFrame(
            GENCONID = gencon_ids,
            EFFECTIVEDATE = fill(test_date, length(gencon_ids)),
            VERSIONNO = fill(1, length(gencon_ids)),
            DESCRIPTION = ["$(gc) requirement" for gc in gencon_ids],
            CONSTRAINTTYPE = fill(">=", length(gencon_ids)),
            LASTCHANGED = fill(base_datetime, length(gencon_ids)),
            archive_month = fill("2025-01", length(gencon_ids))
        ), :GENCONDATA
    )

    # 13. DISPATCH_FCAS_REQ (49 intervals, maps each region/market to its governing constraint)
    df_fcas_req = DataFrame()
    for i in intervals
        t = base_datetime + Minute(5 * i)
        for bid_type in fcas_bid_types
            append!(
                df_fcas_req, DataFrame(
                    SETTLEMENTDATE = fill(t, n),
                    RUNNO = fill(1, n),
                    INTERVENTION = fill(0, n),
                    GENCONID = ["F_$(region)_$(bid_type)" for region in regions],
                    REGIONID = regions,
                    BIDTYPE = fill(bid_type, n),
                    GENCONEFFECTIVEDATE = fill(test_date, n),
                    GENCONVERSIONNO = fill(1, n),
                    MARGINALVALUE = fill(marginal_value(bid_type), n),
                    LASTCHANGED = fill(t, n),
                    archive_month = fill("2025-01", n)
                )
            )
        end
    end
    save_hive(df_fcas_req, :DISPATCH_FCAS_REQ)

    # 14. DISPATCHCONSTRAINT (RHS = the FCAS requirement quantity actually enforced)
    df_constraint = DataFrame()
    for i in intervals
        t = base_datetime + Minute(5 * i)
        for bid_type in fcas_bid_types
            append!(
                df_constraint, DataFrame(
                    SETTLEMENTDATE = fill(t, n),
                    RUNNO = fill(1, n),
                    INTERVENTION = fill(0, n),
                    CONSTRAINTID = ["F_$(region)_$(bid_type)" for region in regions],
                    RHS = fill(requirement_mw(bid_type), n),
                    LHS = fill(requirement_mw(bid_type), n),
                    MARGINALVALUE = fill(marginal_value(bid_type), n),
                    LASTCHANGED = fill(t, n),
                    archive_month = fill("2025-01", n)
                )
            )
        end
    end
    save_hive(df_constraint, :DISPATCHCONSTRAINT)

    # 15. DISPATCHLOAD (per-unit FCAS dispatch outcomes - cleared counterpart to the
    # BIDPEROFFER_D trapezium; contingency markets get an ACTUALAVAILABILITY, regulation
    # markets don't, matching what AEMO actually publishes)
    df_dispatchload = DataFrame()
    for i in intervals
        t = base_datetime + Minute(5 * i)
        block = DataFrame(
            SETTLEMENTDATE = fill(t, n),
            RUNNO = fill(1, n),
            INTERVENTION = fill(0, n),
            DUID = duids,
            INITIALMW = fill(50.0, n),
            TOTALCLEARED = fill(50.0, n),
            AVAILABILITY = fill(100.0, n),
            AGCSTATUS = fill(1, n),
            RAISEREGAVAILABILITY = fill(3.0, n),
            LOWERREGAVAILABILITY = fill(3.0, n),
            archive_month = fill("2025-01", n),
        )
        for bid_type in contingency_types
            block[!, bid_type] = fill(5.0, n)
            block[!, "$(bid_type)ACTUALAVAILABILITY"] = fill(5.0, n)
        end
        for bid_type in regulation_types
            block[!, bid_type] = fill(3.0, n)
        end
        append!(df_dispatchload, block; promote = true)
    end
    save_hive(df_dispatchload, :DISPATCHLOAD)

    # 16. DISPATCHPRICE (regional FCAS clearing prices - RRP/ROP set equal to the mock's
    # single governing constraint's MARGINALVALUE, so the price-decomposition identity in
    # read_fcas_requirements/read_fcas_prices holds exactly)
    df_dispatchprice = DataFrame()
    for i in intervals
        t = base_datetime + Minute(5 * i)
        block = DataFrame(
            SETTLEMENTDATE = fill(t, n),
            RUNNO = fill(1, n),
            INTERVENTION = fill(0, n),
            REGIONID = regions,
            RRP = fill(50.0 + i, n),
            ROP = fill(50.0 + i, n),
            APCFLAG = fill(0, n),
            archive_month = fill("2025-01", n),
        )
        for bid_type in fcas_bid_types
            mv = marginal_value(bid_type)
            block[!, "$(bid_type)RRP"] = fill(mv, n)
            block[!, "$(bid_type)ROP"] = fill(mv, n)
            block[!, "$(bid_type)APCFLAG"] = fill(0, n)
        end
        append!(df_dispatchprice, block; promote = true)
    end
    save_hive(df_dispatchprice, :DISPATCHPRICE)

    return DuckDB.disconnect(conn)
end
