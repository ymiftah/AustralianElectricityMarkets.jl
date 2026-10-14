"""
    read_hive(db::AEMDB, table_name::Symbol)

Builds the SQL `read_parquet(...)` source fragment for a hive-partitioned
parquet dataset, for use as a `FROM` source in a larger query.

Uses `union_by_name=true`: a table's `_TABLE_SPECS` entry can grow new columns over time
(AEMO widens NEMWEB tables, or this repo starts ingesting a column it previously skipped)
without invalidating partitions already on disk under the old, narrower schema - those
partitions just read back with `NULL` in the new columns instead of the glob raising a
schema-mismatch error.

# Arguments
- `db::AEMDB`: The database connection wrapper to use.
- `table_name::Symbol`: The name of the table to read.
"""
function read_hive(
        db::AEMDB,
        table_name::Symbol,
    )
    hive_root = _parse_hive_root(db.config)
    return "read_parquet('$hive_root/$table_name/**/*.parquet', hive_partitioning=true, union_by_name=true)"
end
