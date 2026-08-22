using DataFrames
using Dates
using DuckDB

# NEMWEB fixture keyed to `augmented_pscb_system()`'s component names, for testing the FCAS and
# constraint types against a real system. Only the tables `set_fcas_bids!` and
# `add_nem_constraints!` read are written - `nem_system` is never called on this hive, so the
# unit/station/interconnector build tables are deliberately absent.
#
# `mock_data.jl` remains the fixture for the NEMWEB-quirk reader tests; this one exists so the
# FCAS/constraint types are exercised against PowerSystemCaseBuilder's system rather than
# hand-rolled scaffolding.

const PSCB_REGION_OF = Dict(
    "Alta" => "1", "Brighton" => "1", "Park City" => "1", "Sundance" => "1",
    "HydroDispatch1" => "1", "HydroDispatch2" => "1", "HydroDispatch3" => "1", "BAT1" => "1",
    "Solitude" => "2", "SOLAR1" => "2",
)

# Several DUIDs share a connection point, so the constraint-term reader's 1:many
# CONNECTIONPOINTID -> DUID expansion is exercised rather than assumed.
const PSCB_CONNECTION_POINTS = [
    "CP_A" => ["Alta", "Brighton"],
    "CP_B" => ["Park City", "Sundance"],
    "CP_C" => ["Solitude"],
    "CP_HYD" => ["HydroDispatch1", "HydroDispatch2", "HydroDispatch3"],
    "CP_SOLAR" => ["SOLAR1"],
    "CP_BAT" => ["BAT1"],
]

const PSCB_DUIDS = collect(keys(PSCB_REGION_OF))
const PSCB_FCAS_BID_TYPES = [
    "RAISE6SEC", "LOWER6SEC", "RAISE60SEC", "LOWER60SEC",
    "RAISE5MIN", "LOWER5MIN", "RAISEREG", "LOWERREG",
]
const PSCB_REGULATION_TYPES = ["RAISEREG", "LOWERREG"]

# The interval `N_PARTIAL` first appears in DISPATCHCONSTRAINT; before it, the constraint is
# simply not invoked. Drives add_nem_constraints!'s rhs padding and "invoked" mask.
const PSCB_PARTIAL_FROM = 10

"""
    create_pscb_nemweb_data(hive_root)

Writes the FCAS and constraint tables keyed to [`augmented_pscb_system`](@ref)'s component
names into a Hive-partitioned parquet cache rooted at `hive_root`.

Five constraints are defined, each reaching a distinct code path:

| `GENCONID` | sense | terms | FCAS requirement |
| --- | --- | --- | --- |
| `F_R1_RAISE6SEC` | `>=` | unit (`CP_A`), region `"1"` | yes |
| `F_R2_LOWERREG` | `>=` | unit (`CP_C`), region `"2"` | yes |
| `N_IC1_LIMIT` | `<=` | interconnector `IC1`, unit (`CP_B`) | no |
| `N_HYDRO_LIMIT` | `<=` | unit (`CP_HYD`) | no |
| `N_PARTIAL` | `<=` | unit (`CP_SOLAR`) | no, and invoked for only part of the grid |

Intervals are 5-minutely over `2020-01-01T00:00` -> `02:00`, matching real `DISPATCHCONSTRAINT`
(the resolution `add_nem_constraints!` builds its series at is inferred from the data, not
hardcoded, since commit 9466d9d).

`t0` is deliberately the same as [`augmented_pscb_system`](@ref)'s own `PowerSystemCaseBuilder`
forecast (`2020-01-01T00:00`, see `get_forecast_initial_timestamp`), so a `PSI.DecisionModel`
built on the augmented system runs its dispatch timesteps on the same origin this fixture's
FCAS/constraint series start from - letting a later milestone couple FCAS capacity to energy
dispatch by looking up each dispatch timestep's exact row in these series. Resolution is *not*
also matched to that forecast's hourly one: `augmented_pscb_system()`'s native forecast is a
genuine rolling 2015-window `Deterministic` at `(resolution, interval) = (Hour(1), Hour(1))`, and
`PowerSystems`/`InfrastructureSystems` require every `Deterministic` series sharing a `System`'s
`(resolution, interval)` key to also share its `count`/`initial_timestamp`/`horizon` - confirmed
directly: attaching this fixture's single-window series at `resolution = Hour(1)` raises
`InfrastructureSystems.ConflictingInputsError("forecast count 1 does not match system count
2015")`. Staying 5-minutely keeps this fixture in its own `(Minute(5), Minute(5))` group (no
collision) while every model dispatch timestep (whole-hour multiples) still lands exactly on one
of this fixture's rows, since 60 minutes is an exact multiple of 5.
"""
function create_pscb_nemweb_data(hive_root::String)
    db = DuckDB.DB()
    conn = DuckDB.connect(db)
    DuckDB.execute(conn, "SET preserve_identifier_case=true")

    function save_hive(df, table_name)
        DuckDB.register_data_frame(conn, df, "tmp_table")
        table_dir = joinpath(hive_root, string(table_name))
        mkpath(table_dir)
        DuckDB.execute(
            conn,
            "COPY (SELECT * FROM tmp_table) TO '$table_dir' (FORMAT 'PARQUET', PARTITION_BY (archive_month))",
        )
        return DuckDB.unregister_table(conn, "tmp_table")
    end

    test_date = Date(2020, 1, 1)
    base_datetime = DateTime(2020, 1, 1, 0, 0)
    intervals = 0:24
    am = "2020-01"

    # DUDETAILSUMMARY - only the CONNECTIONPOINTID -> DUID mapping is read here.
    dudetail_rows = DataFrame()
    for (cp, duids) in PSCB_CONNECTION_POINTS
        append!(
            dudetail_rows, DataFrame(
                DUID = duids,
                START_DATE = fill(DateTime(2020, 1, 1), length(duids)),
                END_DATE = Union{DateTime, Missing}[missing for _ in duids],
                STATIONID = fill(replace(cp, "CP_" => "ST_"), length(duids)),
                CONNECTIONPOINTID = fill(cp, length(duids)),
                REGIONID = [PSCB_REGION_OF[d] for d in duids],
                archive_month = fill(am, length(duids)),
            )
        )
    end
    save_hive(dudetail_rows, :DUDETAILSUMMARY)

    # GENCONDATA - definitions, joined by exact (GENCONID, EFFECTIVEDATE, VERSIONNO).
    gencon_ids = ["F_R1_RAISE6SEC", "F_R2_LOWERREG", "N_IC1_LIMIT", "N_HYDRO_LIMIT", "N_PARTIAL"]
    senses = [">=", ">=", "<=", "<=", "<="]
    # F_R2_LOWERREG's only offering unit is Solitude (MAXAVAIL = 20.0 + i); 15.0 keeps
    # rhs = 15.0 + 0.1*i below that at every i in 0:24, with headroom that only grows.
    values = [30.0, 15.0, 100.0, 60.0, 40.0]
    n_gc = length(gencon_ids)
    save_hive(
        DataFrame(
            GENCONID = gencon_ids,
            EFFECTIVEDATE = fill(test_date, n_gc),
            VERSIONNO = fill(1, n_gc),
            DESCRIPTION = ["$(gc) (PSCB fixture)" for gc in gencon_ids],
            CONSTRAINTTYPE = senses,
            LASTCHANGED = fill(base_datetime, n_gc),
            GENERICCONSTRAINTWEIGHT = fill(1.0, n_gc),
            CONSTRAINTVALUE = values,
            DYNAMICRHS = fill(0, n_gc),
            LIMITTYPE = ["FCAS", "FCAS", "TRANSIENT STABILITY", "THERMAL", "THERMAL"],
            SOURCE = fill("pscb", n_gc),
            archive_month = fill(am, n_gc),
        ), :GENCONDATA
    )

    # SPDCONNECTIONPOINTCONSTRAINT -> UNIT terms.
    cp_terms = [
        ("CP_A", "F_R1_RAISE6SEC", "RAISE6SEC", 1.0),
        ("CP_C", "F_R2_LOWERREG", "LOWERREG", 1.0),
        ("CP_B", "N_IC1_LIMIT", "ENERGY", 1.0),
        ("CP_HYD", "N_HYDRO_LIMIT", "ENERGY", 1.0),
        ("CP_SOLAR", "N_PARTIAL", "ENERGY", 1.0),
    ]
    save_hive(
        DataFrame(
            CONNECTIONPOINTID = [t[1] for t in cp_terms],
            EFFECTIVEDATE = fill(test_date, length(cp_terms)),
            VERSIONNO = fill(1, length(cp_terms)),
            GENCONID = [t[2] for t in cp_terms],
            PERIODID = fill(1, length(cp_terms)),
            FACTOR = [t[4] for t in cp_terms],
            BIDTYPE = [t[3] for t in cp_terms],
            LASTCHANGED = fill(base_datetime, length(cp_terms)),
            archive_month = fill(am, length(cp_terms)),
        ), :SPDCONNECTIONPOINTCONSTRAINT
    )

    # SPDREGIONCONSTRAINT -> REGION terms.
    region_terms = [("1", "F_R1_RAISE6SEC", "RAISE6SEC"), ("2", "F_R2_LOWERREG", "LOWERREG")]
    save_hive(
        DataFrame(
            REGIONID = [t[1] for t in region_terms],
            EFFECTIVEDATE = fill(test_date, length(region_terms)),
            VERSIONNO = fill(1, length(region_terms)),
            GENCONID = [t[2] for t in region_terms],
            BIDTYPE = [t[3] for t in region_terms],
            FACTOR = fill(1.0, length(region_terms)),
            LASTCHANGED = fill(base_datetime, length(region_terms)),
            archive_month = fill(am, length(region_terms)),
        ), :SPDREGIONCONSTRAINT
    )

    # SPDINTERCONNECTORCONSTRAINT -> INTERCONNECTOR term (netting IC1's flow, the real F_T++
    # Basslink pattern).
    save_hive(
        DataFrame(
            INTERCONNECTORID = ["IC1"],
            EFFECTIVEDATE = [test_date],
            VERSIONNO = [1],
            GENCONID = ["N_IC1_LIMIT"],
            FACTOR = [-1.0],
            LASTCHANGED = [base_datetime],
            archive_month = [am],
        ), :SPDINTERCONNECTORCONSTRAINT
    )

    # DISPATCHCONSTRAINT - RHS varies per interval so the "rhs" series is not flat.
    df_constraint = DataFrame()
    for i in intervals
        t = base_datetime + Minute(5 * i)
        ids = gencon_ids[1:4]
        rhs = values[1:4] .+ 0.1 * i
        append!(
            df_constraint, DataFrame(
                SETTLEMENTDATE = fill(t, length(ids)),
                RUNNO = fill(1, length(ids)),
                INTERVENTION = fill(0, length(ids)),
                CONSTRAINTID = ids,
                RHS = rhs,
                LHS = rhs .- 1.0,
                MARGINALVALUE = fill(0.0, length(ids)),
                GENCONID_EFFECTIVEDATE = fill(test_date, length(ids)),
                GENCONID_VERSIONNO = fill(1, length(ids)),
                LASTCHANGED = fill(t, length(ids)),
                archive_month = fill(am, length(ids)),
            )
        )
        if i >= PSCB_PARTIAL_FROM
            append!(
                df_constraint, DataFrame(
                    SETTLEMENTDATE = [t], RUNNO = [1], INTERVENTION = [0],
                    CONSTRAINTID = ["N_PARTIAL"], RHS = [40.0 + 0.1 * i], LHS = [39.0 + 0.1 * i],
                    MARGINALVALUE = [0.0], GENCONID_EFFECTIVEDATE = [test_date],
                    GENCONID_VERSIONNO = [1], LASTCHANGED = [t], archive_month = [am],
                )
            )
        end
    end
    save_hive(df_constraint, :DISPATCHCONSTRAINT)

    # DISPATCH_FCAS_REQ - only the two F_ constraints have a requirement row, so the two N_
    # constraints exercise the pure-network path.
    fcas_reqs = [("F_R1_RAISE6SEC", "1", "RAISE6SEC", 5.5), ("F_R2_LOWERREG", "2", "LOWERREG", 2.25)]
    df_fcas_req = DataFrame()
    for i in intervals
        t = base_datetime + Minute(5 * i)
        append!(
            df_fcas_req, DataFrame(
                SETTLEMENTDATE = fill(t, length(fcas_reqs)),
                RUNNO = fill(1, length(fcas_reqs)),
                INTERVENTION = fill(0, length(fcas_reqs)),
                GENCONID = [r[1] for r in fcas_reqs],
                REGIONID = [r[2] for r in fcas_reqs],
                BIDTYPE = [r[3] for r in fcas_reqs],
                GENCONEFFECTIVEDATE = fill(test_date, length(fcas_reqs)),
                GENCONVERSIONNO = fill(1, length(fcas_reqs)),
                MARGINALVALUE = [r[4] for r in fcas_reqs],
                LASTCHANGED = fill(t, length(fcas_reqs)),
                archive_month = fill(am, length(fcas_reqs)),
            )
        )
    end
    save_hive(df_fcas_req, :DISPATCH_FCAS_REQ)

    # BIDPEROFFER_D / BIDDAYOFFER_D. BAT1 additionally gets DIRECTION="LOAD" rows - the only
    # way set_fcas_bids!'s decremental branch is reached.
    bid_types = vcat(["ENERGY"], PSCB_FCAS_BID_TYPES)
    df_per_offer = DataFrame()
    for i in intervals
        t = base_datetime + Minute(5 * i)
        for bt in bid_types
            for (duids, direction) in ((PSCB_DUIDS, "GEN"), (["BAT1"], "LOAD"))
                nd = length(duids)
                block = DataFrame(
                    SETTLEMENTDATE = fill(test_date, nd),
                    BIDTYPE = fill(bt, nd),
                    INTERVAL_DATETIME = fill(t, nd),
                    VERSIONNO = fill(1, nd),
                    DUID = duids,
                    DIRECTION = fill(direction, nd),
                    MAXAVAIL = fill(bt == "ENERGY" ? 100.0 + i : 20.0 + i, nd),
                    archive_month = fill(am, nd),
                    ENABLEMENTMIN = fill(bt == "ENERGY" ? missing : 20.0, nd),
                    LOWBREAKPOINT = fill(bt == "ENERGY" ? missing : 30.0, nd),
                    HIGHBREAKPOINT = fill(bt == "ENERGY" ? missing : 90.0, nd),
                    ENABLEMENTMAX = fill(bt == "ENERGY" ? missing : 100.0, nd),
                    ROCUP = fill(bt in PSCB_REGULATION_TYPES ? 1.0 : missing, nd),
                    ROCDOWN = fill(bt in PSCB_REGULATION_TYPES ? 1.0 : missing, nd),
                )
                for b in 1:10
                    block[!, "BANDAVAIL$b"] = fill(10.0, nd)
                end
                append!(df_per_offer, block; promote = true)
            end
        end
    end
    save_hive(df_per_offer, :BIDPEROFFER_D)

    # `_massage_bids` inner-joins price bands on (SETTLEMENTDATE, DUID, DIRECTION), so every
    # (DUID, DIRECTION, BIDTYPE) above needs a matching daily row.
    df_day_offer = DataFrame()
    for bt in bid_types
        for (duids, direction) in ((PSCB_DUIDS, "GEN"), (["BAT1"], "LOAD"))
            nd = length(duids)
            append!(
                df_day_offer, DataFrame(
                    BIDTYPE = fill(bt, nd),
                    SETTLEMENTDATE = fill(test_date, nd),
                    DUID = duids,
                    DIRECTION = fill(direction, nd),
                    MINIMUMLOAD = fill(0.0, nd),
                    DAILYENERGYCONSTRAINT = fill(1000.0, nd),
                    VERSIONNO = fill(1, nd),
                    archive_month = fill(am, nd),
                )
            )
        end
    end
    for b in 1:10
        df_day_offer[!, "PRICEBAND$b"] = fill(50.0 + b, nrow(df_day_offer))
    end
    save_hive(df_day_offer, :BIDDAYOFFER_D)

    DuckDB.disconnect(conn)
    return hive_root
end
