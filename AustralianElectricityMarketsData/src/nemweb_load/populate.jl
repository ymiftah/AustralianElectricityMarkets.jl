# ── DataSource-based fetch/write pipeline ─────────────────────────────────────

"""
    _clear_local_partition(source::DataSource, partition_dir::String) -> Nothing

Remove `partition_dir` if it exists, for local sources only. Remote partitions are left to
`COPY`'s `OVERWRITE_OR_IGNORE`.

# Arguments
- `source::DataSource`: The table being populated.
- `partition_dir::String`: The month's partition directory.

# Returns
- `Nothing`.
"""
function _clear_local_partition(source::DataSource, partition_dir::String)
    islocal(source) || return
    isdir(partition_dir) && rm(partition_dir; recursive = true, force = true)
    return
end


"""
    _add_data(source::DataSource, year::Int, month::Int; fetch_archive = _get_archive) -> Nothing

Download the NEMWEB archive for the given month and write it to the Hive-partitioned parquet
cache, replacing the month's local partition. A month AEMO does not publish is logged and
skipped; any other failure is rethrown.

# Arguments
- `source::DataSource`: The table to fetch and where to write it.
- `year::Int`, `month::Int`: The archive month.
- `fetch_archive`: `fetch_archive(table_name, year, month)` returns the downloaded ZIP path(s).

# Returns
- `Nothing`.
"""
function _add_data(source::DataSource, year::Int, month::Int; fetch_archive = _get_archive)
    partition_dir = joinpath(source.path, "$ARCHIVE_MONTH_PARTITION=$(Date(year, month, 1))")

    try
        @info "Fetching data" table = source.table_name year month
        zip_paths = fetch_archive(source.table_name, year, month)
        lo, hi = isnothing(source.month_filter_column) ? (nothing, nothing) : _month_filter_bounds(year, month)
        d_only_path, available_cols = try
            _extract_d_lines(zip_paths; month_filter_column = source.month_filter_column, lo, hi)
        finally
            # Every part's zip is deleted as soon as the combined D-lines-only
            # CSV has been extracted from it.
            foreach(p -> rm(p; force = true), zip_paths)
        end

        try
            # Clearing only here keeps the existing partition if the download or extraction fails.
            _clear_local_partition(source, partition_dir)
            @info "Writing Hive-partitioned parquet" path = source.path
            conn = _new_duckdb_connection(get_filesystem(source))
            try
                _csv_to_parquet(
                    conn, d_only_path, available_cols, source.table_columns, source.path,
                    source.partitions, source.table_sort_by, year, month;
                    islocal = islocal(source), month_filter_column = source.month_filter_column,
                    row_filter = source.row_filter,
                )
            finally
                DBInterface.close!(conn)
            end
        finally
            # Delete the csv file
            rm(d_only_path; force = true)
        end

    catch e
        if isa(e, MissingDataError)
            # 404 under every known URL pattern: AEMO does not publish this month, so
            # skipping is correct. A TransientDownloadError is NOT caught here - it must
            # abort rather than leave a silent hole (see errors.jl).
            @error "No data available (not published by AEMO)" table = source.table_name year month
        else
            rethrow(e)
        end
    end
    return
end


"""
    populate(source::DataSource, date_range::StepRange{Date}; force_new::Bool=false, fetch_archive=_get_archive)

Populate one table's cache with each month of `date_range`, skipping months already cached
unless `force_new` is set.

# Arguments
- `source::DataSource`: The table to populate.
- `date_range::StepRange{Date}`: Dates whose months are populated; only the first and last
  dates matter.
- `force_new::Bool`: Refetch months that are already cached.
- `fetch_archive`: `fetch_archive(table_name, year, month)` returns the downloaded ZIP path(s).

# Returns
- `Nothing`.
"""
function populate(
        source::DataSource, date_range::StepRange{Date};
        force_new::Bool = false, fetch_archive = _get_archive,
    )
    start = first(date_range)
    stop = last(date_range)
    @info "Populating table" table = source.table_name start = start stop = stop
    date_range = start:Month(1):stop
    # One partition listing replaces a per-month existence check (a connection each on a remote filesystem).
    cached = force_new ? Date[] : _cached_months(source)
    for date in date_range
        year, month = Dates.year(date), Dates.month(date)
        if Date(year, month, 1) in cached
            @info "Data already exists, skipping" table = source.table_name year month
        else
            _add_data(source, year, month; fetch_archive)
        end
    end
    return
end


"""
    populate(db::AEMDB, table_name::Symbol, start_date::Date, end_date::Date; force_new::Bool=false)

Populate `table_name`'s Hive-partitioned parquet cache (under `db.config.hive_location`)
with data for a date range.

# Arguments
- `db::AEMDB`: Database whose configuration locates the cache.
- `table_name::Symbol`: Table to populate.
- `start_date::Date`, `end_date::Date`: First and last dates; their months are populated.
- `force_new::Bool`: Refetch months that are already cached.

# Returns
- `Nothing`.

# Examples
```julia
db = aem_connect(HiveConfiguration(hive_location = "~/.nemdb_cache"))
populate(db, :DISPATCHPRICE, Date(2025, 1, 1), Date(2025, 3, 31))
```
"""
function populate(
        db::AEMDB, table_name::Symbol, start_date::Date, end_date::Date;
        force_new::Bool = false,
    )
    @info "Processing table" table = table_name
    source = get_table(db, table_name)
    return populate(source, start_date:Month(1):end_date; force_new)
end


"""
    populate(db::AEMDB, start_date::Date, end_date::Date;
             tables::Vector{Symbol}=Symbol.(list_available_tables()),
             force_new::Bool=false)

Populate `tables` (or all known tables when unspecified) for a date range.

# Arguments
- `db::AEMDB`: Database whose configuration locates the cache.
- `start_date::Date`, `end_date::Date`: First and last dates; their months are populated.
- `tables::Vector{Symbol}`: Tables to populate.
- `force_new::Bool`: Refetch months that are already cached.

# Returns
- `Nothing`.

# Examples
```julia
populate(db, Date(2025, 1, 1), Date(2025, 3, 31))
populate(db, Date(2025, 1, 1), Date(2025, 3, 31); tables=[:DISPATCHPRICE, :DISPATCHLOAD])
```
"""
function populate(
        db::AEMDB, start_date::Date, end_date::Date;
        tables::Vector{Symbol} = Symbol.(list_available_tables()),
        force_new::Bool = false,
    )
    @info "Populating cache" start = start_date stop = end_date tables
    for table_name in tables
        populate(db, table_name, start_date, end_date; force_new)
    end
    return
end
