# Some cached partitions predate this repo's `_TABLE_SPECS` adding a given column (observed
# directly: RUNNO is entirely absent from every DISPATCHCONSTRAINT/DISPATCHPRICE partition,
# and INTERVENTION from some DISPATCHLOAD/DISPATCHPRICE partitions, in a real, years-old
# cache - apparently a legacy ingestion artifact). `read_hive`'s `union_by_name` only fills
# NULL for a column present in *some* globbed file; referencing a column absent from *every*
# file is still a hard Binder Error. So `INTERVENTION` filtering is built conditionally on
# whether the column is actually in the resolved schema - a partition with no INTERVENTION
# data was written by a pipeline that never distinguished intervention runs, so it is always
# the normal run. RUNNO is "always 1" for ordinary dispatch per AEMO's data model, so it is
# simply never used as a join/filter/partition key by these FCAS readers.
_intervention_where(schema) = "INTERVENTION" in schema ? "AND COALESCE(INTERVENTION, 0) = ?" : ""
_push_intervention!(params, schema, intervention) = "INTERVENTION" in schema ? push!(params, intervention) : params

# `union_by_name` fixes *missing*-column schema drift (see above), but not *conflicting*-type
# drift: observed directly on a real cache, one DISPATCHLOAD partition (out of 19) stores
# TOTALCLEARED as VARCHAR while every other partition stores it as FLOAT, and DuckDB resolves
# that conflict by widening the column to VARCHAR across the *entire* glob - silently turning
# every row's TOTALCLEARED, even from well-typed partitions, into a string. `SELECT *` cannot
# be trusted for a numeric column for this reason; every numeric column these FCAS readers
# return is explicitly `TRY_CAST` to `DOUBLE`.
_cast_double(col) = "TRY_CAST($col AS DOUBLE) AS $col"

"""
    _table_is_cached(db, table_name) -> Bool

Whether `table_name` has at least one parquet file in the cache. `read_hive` only builds a
glob string, so referencing an uncached table is a hard DuckDB error rather than an empty
result - readers that tolerate a partially-populated cache (e.g. only one side of AEMO's
`DISPATCH_FCAS_REQ` split) must check first. Uses DuckDB's `glob` so it works for remote
filesystems too, not just a local `isdir`.

A glob matching zero files is a legitimate, silent `false` - confirmed directly, DuckDB's
`glob` returns an empty result rather than erroring for a nonexistent local path. It is
*not* silent about a genuine failure to check (bad S3/GS credentials, a network drop,
corrupt parquet): those raise DuckDB's own exception uncaught, naming the real cause,
rather than being swallowed into a false "not cached".
"""
function _table_is_cached(db, table_name::Symbol)
    hive_root = AustralianElectricityMarketsData._parse_hive_root(db.config)
    df = _query(db, "SELECT COUNT(*) AS n FROM glob('$hive_root/$table_name/**/*.parquet')")
    return df.n[1] > 0
end
