const _PARTITION_FILE_PATTERN = Regex("$(ARCHIVE_MONTH_PARTITION)=(\\d{4}-\\d{2}-\\d{2})/[^/]*\\.parquet\$")


"""
    _glob_partition_files(conn, root::String) -> Vector{String}

Every `<root>/archive_month=*/*.parquet` path, listed with one DuckDB `glob()` query on `conn`.
"""
function _glob_partition_files(conn, root::String)::Vector{String}
    sql = "SELECT file FROM glob('$root/$(ARCHIVE_MONTH_PARTITION)=*/*.parquet')"
    return String.(DataFrame(DBInterface.execute(conn, sql)).file)
end


"""
    _months_from_paths(files) -> Vector{Date}

The sorted, distinct archive months named by the `archive_month=YYYY-MM-DD` directory of each
parquet path in `files`; other paths are ignored.
"""
function _months_from_paths(files)::Vector{Date}
    months = Set{Date}()
    for file in files
        m = match(_PARTITION_FILE_PATTERN, file)
        m === nothing || push!(months, Date(m.captures[1]))
    end
    return sort!(collect(months))
end

"""
    _cached_months(source::DataSource; conn = nothing) -> Vector{Date}

The archive months of `source` that hold at least one `.parquet` file, sorted. A local source
is read with `readdir`; a remote source is listed with one DuckDB `glob()` query over `httpfs`.

# Arguments
- `source::DataSource`: The table to inspect.
- `conn`: An open DuckDB connection to reuse for a remote source; one is opened and closed
  when omitted. Ignored for a local source.

# Returns
- `Vector{Date}`: The first day of each cached month.
"""
function _cached_months(source::DataSource; conn = nothing)::Vector{Date}
    months = Set{Date}()
    if islocal(source)
        pattern = Regex("^$(ARCHIVE_MONTH_PARTITION)=(\\d{4}-\\d{2}-\\d{2})\$")
        isdir(source.path) || return Date[]
        for entry in readdir(source.path)
            m = match(pattern, entry)
            m === nothing && continue
            partition_dir = joinpath(source.path, entry)
            _partition_has_data(source, partition_dir) && push!(months, Date(m.captures[1]))
        end
    else
        files = _with_connection(c -> _glob_partition_files(c, source.path), conn, source)
        union!(months, _months_from_paths(files))
    end
    return sort!(collect(months))
end


"""
    cached_date_range(source::DataSource; conn = nothing) -> Union{Nothing, Tuple{Date, Date}}

Find the Hive-partitioned `archive_month=YYYY-MM-DD` partitions of `source` that contain
parquet data, and return `(first_day_of_earliest_month, last_day_of_latest_month)`, or
`nothing` if no cached data is found. Only the outer bounds are reported, so the cached months
need not be contiguous.

# Arguments
- `source::DataSource`: The table to inspect.
- `conn`: An open DuckDB connection to reuse for a remote source, see `_cached_months`.

# Returns
- `Union{Nothing, Tuple{Date, Date}}`: The bounds of the cached months, or `nothing`.
"""
function cached_date_range(source::DataSource; conn = nothing)::Union{Nothing, Tuple{Date, Date}}
    months = _cached_months(source; conn)
    isempty(months) && return nothing
    return (first(months), Dates.lastdayofmonth(last(months)))
end


"""
    _with_connection(f, conn, source::DataSource)

Call `f(conn)` on `conn` when it is given, else on a new connection for `source`'s filesystem
that is closed afterwards. Returns the value of `f`.
"""
function _with_connection(f, conn, source::DataSource)
    isnothing(conn) || return f(conn)
    new_conn = _new_duckdb_connection(get_filesystem(source))
    try
        return f(new_conn)
    finally
        DBInterface.close!(new_conn)
    end
end


"""
    _partition_has_data(source::DataSource, partition_dir::String; conn = nothing) -> Bool

True if `partition_dir` exists and contains at least one `.parquet` file. Local filesystems
use `isdir`/`readdir` directly; remote filesystems query DuckDB's `glob()` over `httpfs`,
on `conn` when given.
"""
function _partition_has_data(source::DataSource, partition_dir::String; conn = nothing)::Bool
    if islocal(source)
        return isdir(partition_dir) && any(endswith(f, ".parquet") for f in readdir(partition_dir))
    end
    return _with_connection(conn, source) do c
        df = DataFrame(DBInterface.execute(c, "SELECT COUNT(*) AS n FROM glob('$partition_dir/*.parquet')"))
        return df.n[1] > 0
    end
end
