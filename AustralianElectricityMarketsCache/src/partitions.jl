"""
    _partition_has_data(source::DataSource, partition_dir::String) -> Bool

True if `partition_dir` exists and contains at least one `.parquet` file.
Local filesystems use `isdir`/`readdir` directly; remote filesystems query
DuckDB's `glob()` over `httpfs`.
"""
function _partition_has_data(source::DataSource, partition_dir::String)::Bool
    if islocal(source)
        return isdir(partition_dir) && any(endswith(f, ".parquet") for f in readdir(partition_dir))
    end
    conn = _new_duckdb_connection(get_filesystem(source))
    try
        df = DataFrame(DBInterface.execute(conn, "SELECT COUNT(*) AS n FROM glob('$partition_dir/*.parquet')"))
        return df.n[1] > 0
    finally
        DBInterface.close!(conn)
    end
end
