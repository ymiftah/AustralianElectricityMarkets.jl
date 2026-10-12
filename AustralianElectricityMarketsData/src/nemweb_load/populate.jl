# ── DataSource-based fetch/write pipeline ─────────────────────────────────────

"""
    _clear_local_partition(source::DataSource, partition_dir::String)

Remove `partition_dir` if it exists — but only for local sources. `_add_data`
is only ever called when `populate` has already decided to (re)fetch this
month (not cached, or `force_new=true`); for local filesystems, clearing the
partition unconditionally here is always correct and removes any risk of
stale files from a previous run coexisting with fresh ones. For remote
filesystems there is deliberately no equivalent clear step, remote rewrites
rely solely on COPY's OVERWRITE_OR_IGNORE.
"""
function _clear_local_partition(source::DataSource, partition_dir::String)
    islocal(source) || return
    return isdir(partition_dir) && rm(partition_dir; recursive = true, force = true)
end


"""
    _add_data(source::DataSource, year::Int, month::Int)

Download the NEMWEB archive for the given month and write it to the
Hive-partitioned parquet cache.
"""
function _add_data(source::DataSource, year::Int, month::Int)
    partition_dir = joinpath(source.path, "$ARCHIVE_MONTH_PARTITION=$(Date(year, month, 1))")
    _clear_local_partition(source, partition_dir)

    return try
        @info "Fetching data" table = source.table_name year month
        zip_paths = _get_archive(source.table_name, year, month)
        lo, hi = isnothing(source.month_filter_column) ? (nothing, nothing) : _month_filter_bounds(year, month)
        d_only_path, available_cols = try
            _extract_d_lines(zip_paths; month_filter_column = source.month_filter_column, lo, hi)
        finally
            # Every part's zip is deleted as soon as the combined D-lines-only
            # CSV has been extracted from it.
            foreach(p -> rm(p; force = true), zip_paths)
        end

        try
            @info "Writing Hive-partitioned parquet" path = source.path
            conn = _new_duckdb_connection(get_filesystem(source))
            try
                _csv_to_parquet(
                    conn, d_only_path, available_cols, source.table_columns, source.path,
                    source.partitions, source.table_sort_by, year, month;
                    islocal = islocal(source), month_filter_column = source.month_filter_column,
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
            @error "No data available (HTTP 404 - not published by AEMO)" table = source.table_name year month
        else
            rethrow(e)
        end
    end
end


"""
    populate(source::DataSource, date_range::StepRange{Date}; force_new::Bool=false)

Populate table with data from a date range.
"""
function populate(source::DataSource, date_range::StepRange{Date}; force_new::Bool = false)
    start = first(date_range)
    stop = last(date_range)
    @info "Populating table" table = source.table_name start = start stop = stop
    date_range = start:Month(1):stop
    for date in date_range
        year, month = Dates.year(date), Dates.month(date)

        data_exists = false
        if !force_new
            # Check for Hive-partitioned data
            partition_date = Date(year, month, 1)
            partition_dir = joinpath(source.path, "$ARCHIVE_MONTH_PARTITION=$(partition_date)")
            data_exists = _partition_has_data(source, partition_dir)
        end

        if !data_exists
            _add_data(source, year, month)
        else
            @info "Data already exists, skipping" table = source.table_name year month
        end
    end
    return
end


"""
    populate(db::AEMDB, table_name::Symbol, start_date::Date, end_date::Date; force_new::Bool=false)

Populate `table_name`'s Hive-partitioned parquet cache (under `db.config.hive_location`)
with data for a date range.

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
