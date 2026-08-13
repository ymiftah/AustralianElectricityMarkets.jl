"""
    DataSource

Immutable description of one NEMWEB MMS table, cached as Hive-partitioned
parquet under `config.hive_location`. Construction is pure — it does not
touch the filesystem; `_add_data` creates `path` lazily on first write.

The filesystem (`"file"`, `"s3"`, `"gs"`) is not stored separately — it's
recovered from `path`'s scheme via `get_filesystem(::String)`, since `path`
already encodes it (`s3://...`, `gs://...`, or a bare local path).

# Fields
- `table_name::String`: Name of the table
- `table_columns::Vector{String}`: Columns to include
- `table_sort_by::Vector{String}`: Columns to sort by within each output file (row-group locality; not an enforced uniqueness constraint)
- `partitions::Vector{String}`: Partition columns
- `path::String`: Path to parquet dataset (local path, or `scheme://...` URI for remote)
"""
struct DataSource
    table_name::String
    table_columns::Vector{String}
    table_sort_by::Vector{String}
    partitions::Vector{String}
    path::String
end

get_filesystem(source::DataSource) = get_filesystem(source.path)
islocal(source::DataSource) = islocal(get_filesystem(source))

"""
    DataSource(table_name, table_columns, config=HiveConfiguration();
               table_sort_by=String[], add_partitions=String[])

Create a new `DataSource` for a NEMWEB table, rooted at `config.hive_location`.
Works for both local and remote (`s3`/`gs`) `config.filesystem` — path
construction is delegated to `_parse_hive_root`.
"""
function DataSource(
        table_name::String,
        table_columns::Vector{String},
        config::HiveConfiguration = HiveConfiguration();
        table_sort_by::Vector{String} = String[],
        add_partitions::Vector{String} = String[],
    )
    return DataSource(
        table_name,
        table_columns,
        table_sort_by,
        vcat(add_partitions, ARCHIVE_MONTH_PARTITION),
        joinpath(_parse_hive_root(config), table_name),
    )
end

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
