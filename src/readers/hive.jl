"""
    read_hive(db::AEMDB, table_name::Symbol)

Builds the SQL `read_parquet(...)` source fragment for a hive-partitioned parquet dataset, for use
as a `FROM` source in a larger query. Partitions written before a column was added read back
`NULL` for it.

# Arguments
- `db::AEMDB`: The database connection wrapper to use.
- `table_name::Symbol`: The name of the table to read.

# Returns
A `String` SQL fragment.
"""
function read_hive(
        db::AEMDB,
        table_name::Symbol,
    )
    hive_root = _parse_hive_root(db.config)
    return "read_parquet('$hive_root/$table_name/**/*.parquet', hive_partitioning=true, union_by_name=true)"
end
