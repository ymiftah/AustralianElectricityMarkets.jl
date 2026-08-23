using DataFrames
using Dates
using DuckDB

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

    # 5. DUDETAILSUMMARY. CONNECTIONPOINTID groups BW01-04 under Bayswater's connection
    # point and ER01-02 under Eraring's - exercises the constraint-term reader's 1:many
    # connection-point -> DUID expansion. A 7th, PHANTOM1 row shares no other table (never
    # becomes a System component) - exercises add_nem_constraints!'s unresolvable-term skip
    # path (see test/constraints.jl).
    connection_points = ["CP_BAYSW", "CP_BAYSW", "CP_BAYSW", "CP_BAYSW", "CP_ERARING", "CP_ERARING"]
    save_hive(
        vcat(
            DataFrame(
                DUID = duids,
                START_DATE = fill(DateTime(2020, 1, 1), n),
                END_DATE = Union{DateTime, Missing}[missing for i in 1:n],
                STATIONID = station_ids,
                CONNECTIONPOINTID = connection_points,
                REGIONID = regions,
                archive_month = fill("2025-01", n)
            ),
            DataFrame(
                DUID = ["PHANTOM1"],
                START_DATE = [DateTime(2020, 1, 1)],
                END_DATE = Union{DateTime, Missing}[missing],
                STATIONID = ["PHANTOM"],
                CONNECTIONPOINTID = ["CP_PHANTOM"],
                REGIONID = ["VIC1"],
                archive_month = ["2025-01"]
            ),
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
    contingency_types = ["RAISE6SEC", "LOWER6SEC", "RAISE60SEC", "LOWER60SEC", "RAISE5MIN", "LOWER5MIN"]
    regulation_types = ["RAISEREG", "LOWERREG"]
    requirement_mw(bid_type) = bid_type in regulation_types ? 30.0 : 50.0
    marginal_value(bid_type) = bid_type in regulation_types ? 2.25 : 5.5
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

        # FCAS LOAD bids for the battery (BW01) - exercises set_fcas_bids!'s decremental path,
        # real NEMWEB data has substantial LOAD/BIDIRECTIONAL FCAS bid volume that an
        # earlier version of set_fcas_bids! silently dropped.
        tmp_fcas_load = DataFrame()
        for bid_type in fcas_bid_types
            block = DataFrame(
                SETTLEMENTDATE = [test_date],
                BIDTYPE = [bid_type],
                INTERVAL_DATETIME = [t],
                VERSIONNO = [1],
                DUID = ["BW01"],
                DIRECTION = ["LOAD"],
                MAXAVAIL = [20.0 + i],
                archive_month = ["2025-01"],
                ENABLEMENTMIN = [20.0],
                LOWBREAKPOINT = [30.0],
                HIGHBREAKPOINT = [90.0],
                ENABLEMENTMAX = [100.0],
                ROCUP = [bid_type in ("RAISEREG", "LOWERREG") ? 1.0 : missing],
                ROCDOWN = [bid_type in ("RAISEREG", "LOWERREG") ? 1.0 : missing],
            )
            for b in 1:10
                block[!, "BANDAVAIL$b"] = fill(10.0, nrow(block))
            end
            append!(tmp_fcas_load, block; promote = true)
        end

        append!(df_bid_per_offer, vcat(tmp, tmp_fcas, tmp_fcas_load); promote = true)
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
    # LOAD-direction FCAS price bands for BW01, matching the BIDPEROFFER_D LOAD block above -
    # _massage_bids inner-joins on (SETTLEMENTDATE, DUID, DIRECTION).
    bid_day_offer_fcas_load = DataFrame()
    for bid_type in fcas_bid_types
        append!(
            bid_day_offer_fcas_load, DataFrame(
                BIDTYPE = [bid_type],
                SETTLEMENTDATE = [test_date],
                DUID = ["BW01"],
                DIRECTION = ["LOAD"],
                MINIMUMLOAD = [0.0],
                DAILYENERGYCONSTRAINT = [1000.0],
                VERSIONNO = [1],
                archive_month = ["2025-01"]
            )
        )
    end
    bid_day_offer = vcat(bid_day_offer_gen, bid_day_offer_load, bid_day_offer_fcas, bid_day_offer_fcas_load)
    for i in 1:10
        bid_day_offer[!, "PRICEBAND$i"] = fill(50.0 + i, nrow(bid_day_offer))
    end
    save_hive(bid_day_offer, :BIDDAYOFFER_D)

    # FCAS requirements are generic-constraint-based (RESERVE has been unpopulated by AEMO
    # since Dec 2003 - see read_fcas_requirements docstring): one governing GENCONID per
    # (region, market), DISPATCHCONSTRAINT.RHS carries the enforced requirement quantity, and
    # DISPATCH_FCAS_REQ.MARGINALVALUE sums (trivially here, one constraint per region/market)
    # to the DISPATCHPRICE regional FCAS price.

    # 12. GENCONDATA. One FCAS-requirement constraint per (region, market) plus one pure
    # network constraint (N_BAYSW_THERMAL, no DISPATCH_FCAS_REQ row), one
    # unresolvable-term constraint (N_PHANTOM_TEST, references DUDETAILSUMMARY's PHANTOM1
    # DUID, which is never built into a System component), and one partial-coverage
    # constraint (N_PARTIAL_COVERAGE, invoked in DISPATCHCONSTRAINT for only every other
    # interval - exercises add_nem_constraints!'s rhs-padding/"invoked"-mask path, see
    # test/constraints.jl).
    gencon_ids = ["F_$(region)_$(bid_type)" for region in regions for bid_type in fcas_bid_types]
    all_gencon_ids = vcat(gencon_ids, ["N_BAYSW_THERMAL", "N_PHANTOM_TEST", "N_PARTIAL_COVERAGE"])
    n_all = length(all_gencon_ids)
    save_hive(
        DataFrame(
            GENCONID = all_gencon_ids,
            EFFECTIVEDATE = fill(test_date, n_all),
            VERSIONNO = fill(1, n_all),
            DESCRIPTION = ["$(gc) requirement" for gc in all_gencon_ids],
            CONSTRAINTTYPE = fill(">=", n_all),
            LASTCHANGED = fill(base_datetime, n_all),
            GENERICCONSTRAINTWEIGHT = fill(1.0, n_all),
            CONSTRAINTVALUE = [
                gc in gencon_ids ? requirement_mw(split(gc, "_")[end]) : 100.0
                    for gc in all_gencon_ids
            ],
            DYNAMICRHS = fill(0, n_all),
            LIMITTYPE = fill("FCAS", n_all),
            SOURCE = fill("mock", n_all),
            archive_month = fill("2025-01", n_all)
        ), :GENCONDATA
    )

    # 13. The dispatch FCAS requirement table, in BOTH of AEMO's generations - it maps each
    # region/market to its governing constraint. AEMO last published DISPATCH_FCAS_REQ for
    # the 2025-05 archive month and replaced it with DISPATCH_FCAS_REQ_CONSTRAINT (GENCONID
    # -> CONSTRAINTID, SETTLEMENTDATE -> INTERVAL_DATETIME, no INTERVENTION, no
    # GENCONEFFECTIVEDATE/GENCONVERSIONNO), backfilling the new table rather than starting it
    # at the changeover. The fixture reproduces that shape: the old table stops halfway
    # through the interval range while the new one spans all of it, so the two overlap on
    # the first half and only the new one covers the second. That exercises both halves of
    # the union in `_fcas_req_union_sql` - the takeover AND the overlap dedup.
    fcas_req_old_intervals = 0:24
    df_fcas_req = DataFrame()
    for i in fcas_req_old_intervals
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

    df_fcas_req_constraint = DataFrame()
    df_fcas_req_run = DataFrame()
    for i in intervals
        t = base_datetime + Minute(5 * i)
        append!(
            df_fcas_req_run, DataFrame(
                RUN_DATETIME = [t], RUNNO = [1], LASTCHANGED = [t],
                archive_month = ["2025-01"]
            )
        )
        for bid_type in fcas_bid_types
            append!(
                df_fcas_req_constraint, DataFrame(
                    RUN_DATETIME = fill(t, n),
                    RUNNO = fill(1, n),
                    INTERVAL_DATETIME = fill(t, n),
                    CONSTRAINTID = ["F_$(region)_$(bid_type)" for region in regions],
                    REGIONID = regions,
                    BIDTYPE = fill(bid_type, n),
                    LHS = fill(requirement_mw(bid_type) + 0.1 * i, n),
                    RHS = fill(requirement_mw(bid_type) + 0.1 * i, n),
                    MARGINALVALUE = fill(marginal_value(bid_type), n),
                    RRP = fill(marginal_value(bid_type), n),
                    REGIONAL_ENABLEMENT = fill(120.0, n),
                    CONSTRAINT_ENABLEMENT = fill(100.0, n),
                    REGION_BASE_COST = fill(0.0, n),
                    BASE_COST = fill(0.0, n),
                    ADJUSTED_COST = fill(0.0, n),
                    P_REGULATION = fill(0.0, n),
                    archive_month = fill("2025-01", n)
                )
            )
        end
    end
    save_hive(df_fcas_req_constraint, :DISPATCH_FCAS_REQ_CONSTRAINT)
    save_hive(df_fcas_req_run, :DISPATCH_FCAS_REQ_RUN)

    # 14. DISPATCHCONSTRAINT. RHS varies per interval (requirement_mw + 0.1*i) to exercise
    # the "rhs" Deterministic time series, not just a flat default. GENCONID_EFFECTIVEDATE/
    # GENCONID_VERSIONNO pin the exact GENCONDATA version, matching test_date/1 above -
    # AEMO's own mechanism for exact-equality constraint-term joins (no date-window
    # heuristic). N_BAYSW_THERMAL and N_PHANTOM_TEST are invoked here too, so they're
    # eligible for add_nem_constraints! despite not appearing in DISPATCH_FCAS_REQ.
    # N_PARTIAL_COVERAGE is invoked for only every other interval - real AEMO constraints
    # invoked less than every dispatch interval within a date_range, unlike this mock's other
    # (fully-covered-by-construction) synthetic constraints.
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
                    RHS = fill(requirement_mw(bid_type) + 0.1 * i, n),
                    LHS = fill(requirement_mw(bid_type) + 0.1 * i, n),
                    MARGINALVALUE = fill(marginal_value(bid_type), n),
                    GENCONID_EFFECTIVEDATE = fill(test_date, n),
                    GENCONID_VERSIONNO = fill(1, n),
                    LASTCHANGED = fill(t, n),
                    archive_month = fill("2025-01", n)
                )
            )
        end
        append!(
            df_constraint, DataFrame(
                SETTLEMENTDATE = [t, t],
                RUNNO = [1, 1],
                INTERVENTION = [0, 0],
                CONSTRAINTID = ["N_BAYSW_THERMAL", "N_PHANTOM_TEST"],
                RHS = [200.0, 100.0],
                LHS = [180.0, 90.0],
                MARGINALVALUE = [0.0, 0.0],
                GENCONID_EFFECTIVEDATE = [test_date, test_date],
                GENCONID_VERSIONNO = [1, 1],
                LASTCHANGED = [t, t],
                archive_month = ["2025-01", "2025-01"]
            )
        )
        if iseven(i)
            append!(
                df_constraint, DataFrame(
                    SETTLEMENTDATE = [t],
                    RUNNO = [1],
                    INTERVENTION = [0],
                    CONSTRAINTID = ["N_PARTIAL_COVERAGE"],
                    RHS = [150.0],
                    LHS = [140.0],
                    MARGINALVALUE = [0.0],
                    GENCONID_EFFECTIVEDATE = [test_date],
                    GENCONID_VERSIONNO = [1],
                    LASTCHANGED = [t],
                    archive_month = ["2025-01"]
                )
            )
        end
    end
    save_hive(df_constraint, :DISPATCHCONSTRAINT)

    # 17. SPDCONNECTIONPOINTCONSTRAINT. F_$(region)_$(bid_type) constraints reference their
    # own region's DUIDs (one FCAS-market UnitTerm each, factor 1.0). N_BAYSW_THERMAL and
    # N_PARTIAL_COVERAGE both reference CP_BAYSW - the connection point behind BW01-04 -
    # exercising the 1:many connection-point -> DUID expansion. N_PHANTOM_TEST references
    # CP_PHANTOM (PHANTOM1 only, which is never built into the System).
    save_hive(
        vcat(
            DataFrame(
                CONNECTIONPOINTID = [cp for cp in connection_points for _ in fcas_bid_types],
                EFFECTIVEDATE = fill(test_date, n * length(fcas_bid_types)),
                VERSIONNO = fill(1, n * length(fcas_bid_types)),
                GENCONID = ["F_$(r)_$(bt)" for r in regions for bt in fcas_bid_types],
                PERIODID = fill(1, n * length(fcas_bid_types)),
                FACTOR = fill(1.0, n * length(fcas_bid_types)),
                BIDTYPE = [bt for _ in regions for bt in fcas_bid_types],
                LASTCHANGED = fill(base_datetime, n * length(fcas_bid_types)),
                archive_month = fill("2025-01", n * length(fcas_bid_types))
            ),
            DataFrame(
                CONNECTIONPOINTID = ["CP_BAYSW"],
                EFFECTIVEDATE = [test_date], VERSIONNO = [1], GENCONID = ["N_BAYSW_THERMAL"],
                PERIODID = [1], FACTOR = [1.0], BIDTYPE = ["ENERGY"],
                LASTCHANGED = [base_datetime], archive_month = ["2025-01"]
            ),
            DataFrame(
                CONNECTIONPOINTID = ["CP_PHANTOM"],
                EFFECTIVEDATE = [test_date], VERSIONNO = [1], GENCONID = ["N_PHANTOM_TEST"],
                PERIODID = [1], FACTOR = [1.0], BIDTYPE = ["ENERGY"],
                LASTCHANGED = [base_datetime], archive_month = ["2025-01"]
            ),
            DataFrame(
                CONNECTIONPOINTID = ["CP_BAYSW"],
                EFFECTIVEDATE = [test_date], VERSIONNO = [1], GENCONID = ["N_PARTIAL_COVERAGE"],
                PERIODID = [1], FACTOR = [1.0], BIDTYPE = ["ENERGY"],
                LASTCHANGED = [base_datetime], archive_month = ["2025-01"]
            ),
        ), :SPDCONNECTIONPOINTCONSTRAINT
    )

    # 18. SPDREGIONCONSTRAINT (regulation FCAS's region-level term, one per region/market)
    save_hive(
        DataFrame(
            REGIONID = [r for r in regions for _ in regulation_types],
            EFFECTIVEDATE = fill(test_date, n * length(regulation_types)),
            VERSIONNO = fill(1, n * length(regulation_types)),
            GENCONID = ["F_$(r)_$(bt)" for r in regions for bt in regulation_types],
            BIDTYPE = [bt for _ in regions for bt in regulation_types],
            FACTOR = fill(1.0, n * length(regulation_types)),
            LASTCHANGED = fill(base_datetime, n * length(regulation_types)),
            archive_month = fill("2025-01", n * length(regulation_types))
        ), :SPDREGIONCONSTRAINT
    )

    # 19. SPDINTERCONNECTORCONSTRAINT (RAISE6SEC's NSW1 requirement additionally nets an
    # interconnector flow term, mirroring the real F_T++ Basslink-netting pattern)
    save_hive(
        DataFrame(
            INTERCONNECTORID = ["IC1"],
            EFFECTIVEDATE = [test_date],
            VERSIONNO = [1],
            GENCONID = ["F_NSW1_RAISE6SEC"],
            FACTOR = [-1.0],
            LASTCHANGED = [base_datetime],
            archive_month = ["2025-01"]
        ), :SPDINTERCONNECTORCONSTRAINT
    )

    # 15. DISPATCHLOAD (per-unit FCAS dispatch outcomes - cleared counterpart to the
    # BIDPEROFFER_D trapezium; contingency markets get an ACTUALAVAILABILITY, regulation
    # markets don't, matching what AEMO actually publishes). UIGF is populated only for the
    # two semi-scheduled units (BW03 Solar, BW04 Wind - see GENUNITS above) and `missing` for
    # the scheduled coal/battery/hydro DUIDs, matching what real NEMWEB publishes. Both
    # profiles vary across intervals and stay strictly below the 100 MW REGISTEREDCAPACITY, so
    # a setter that pins a unit's ceiling to its nameplate is detectable.
    uigf_for(duid, i) = duid == "BW03" ? 40.0 + i : (duid == "BW04" ? 70.0 - i : missing)
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
            UIGF = Union{Float64, Missing}[uigf_for(d, i) for d in duids],
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
