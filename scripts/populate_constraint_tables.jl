using AustralianElectricityMarkets
using Dates

db = aem_connect()  # default HiveConfiguration(): ~/.nemdb_cache, local filesystem

start_date = Date(2015, 1, 1)
end_date = Dates.today()

# GENCONDATA, GENCONSET, GENCONSETTRK were already fully force-re-downloaded
# with the new (wide) schema in a prior run of this script, 2015-01..today.
# A plain gap-fill call just tops up any new trailing months since then.
populate(db, start_date, end_date; tables = [:GENCONDATA, :GENCONSET, :GENCONSETTRK])

# DISPATCHCONSTRAINT: 2015-01..2019-08 were already re-downloaded with the
# new schema by the same prior run. Gap-fill covers everything never
# cached at all (it gets the new schema automatically). The one range that
# needs an explicit force is 2025-01..2026-05 -- the pre-existing cache
# from before this whole operation, still on the old narrow schema.
populate(db, start_date, end_date; tables = [:DISPATCHCONSTRAINT])
populate(db, Date(2025, 1, 1), Date(2026, 5, 31); tables = [:DISPATCHCONSTRAINT], force_new = true)

# Column definitions unchanged for these -> idempotent gap-fill only, skips
# whatever is already cached.
unchanged_tables = [
    :GENCONSETINVOKE, :SPDCONNECTIONPOINTCONSTRAINT,
    :SPDINTERCONNECTORCONSTRAINT, :SPDREGIONCONSTRAINT,
]
populate(db, start_date, end_date; tables = unchanged_tables)

show(stdout, MIME"text/plain"(), db)
println()
