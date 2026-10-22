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


"""
    _partition_dir_names(source::DataSource) -> Vector{String}

Bare directory names (e.g. `"archive_month=2024-01-01"`, no path prefix)
directly under `source.path`. Local filesystems use `readdir` directly;
remote filesystems query DuckDB's `glob()` over `httpfs`.
"""
function _partition_dir_names(source::DataSource)::Vector{String}
    if islocal(source)
        isdir(source.path) || return String[]
        return readdir(source.path)
    end
    conn = _new_duckdb_connection(get_filesystem(source))
    try
        df = DataFrame(DBInterface.execute(conn, "SELECT file FROM glob('$(source.path)/*/')"))
        return [basename(rstrip(f, '/')) for f in df.file]
    finally
        DBInterface.close!(conn)
    end
end


"""
    cached_date_range(source::DataSource) -> Union{Nothing, Tuple{Date, Date}}

Scan `source.path` for Hive-partitioned `archive_month=YYYY-MM-DD` directories that
contain parquet data, and return `(first_day_of_earliest_month, last_day_of_latest_month)`.
Returns `nothing` if no cached data is found. Does not assume the cached months are
contiguous — only the outer bounds are reported.
"""
function cached_date_range(source::DataSource)::Union{Nothing, Tuple{Date, Date}}
    pattern = Regex("^$(ARCHIVE_MONTH_PARTITION)=(\\d{4}-\\d{2}-\\d{2})\$")
    months = Date[]
    for entry in _partition_dir_names(source)
        m = match(pattern, entry)
        m === nothing && continue
        partition_dir = joinpath(source.path, entry)
        if _partition_has_data(source, partition_dir)
            push!(months, Date(m.captures[1]))
        end
    end

    isempty(months) && return nothing
    return (minimum(months), Dates.lastdayofmonth(maximum(months)))
end
