"""
    _add_data(source::DataSource, year::Int, month::Int)

Download the NEMWEB archive for the given month and write it to the
Hive-partitioned parquet cache.
"""
function _add_data(source::DataSource, year::Int, month::Int)
    # `_add_data` is only ever called when `populate` has already decided to
    # (re)fetch this month (not cached, or `force_new=true`). For local
    # filesystems, clearing the partition unconditionally here is always
    # correct and removes any risk of stale files from a previous run
    # coexisting with fresh ones. For remote filesystems there is
    # deliberately no equivalent clear step (see
    # docs/superpowers/specs/2026-08-13-remote-storage-write-support-design.md,
    # "Non-goals") — remote rewrites rely solely on COPY's
    # OVERWRITE_OR_IGNORE, which does not guarantee removal of files left
    # over from a differently-shaped previous write to the same partition.
    partition_dir = joinpath(source.path, "$ARCHIVE_MONTH_PARTITION=$(Date(year, month, 1))")
    if islocal(source.filesystem)
        isdir(partition_dir) && rm(partition_dir; recursive = true, force = true)
    end

    return try
        @info "Fetching data" table = source.table_name year month
        zip_path = _get_archive(source.table_name, year, month)
        csv_path = try
            _extract_csv_entry(zip_path)
        finally
            # Each intermediate file (zip, extracted CSV, D-lines-only CSV) is
            # deleted as soon as the next stage no longer needs it, rather
            # than all at the end, to keep peak disk/page-cache footprint
            # down across the pipeline.
            rm(zip_path; force = true)
        end

        available_cols = _peek_header_columns(csv_path)
        d_only_path = try
            _filter_d_lines(csv_path)
        finally
            rm(csv_path; force = true)
        end

        try
            @info "Writing Hive-partitioned parquet" path = source.path
            conn = _new_duckdb_connection(source.filesystem)
            try
                _csv_to_parquet(
                    conn, d_only_path, available_cols, source.table_columns, source.path,
                    source.partitions, source.table_sort_by, year, month;
                    islocal = islocal(source.filesystem),
                )
            finally
                DBInterface.close!(conn)
            end
        finally
            rm(d_only_path; force = true)
        end

    catch e
        if isa(e, MissingDataError)
            @error "No data available" table = source.table_name year month
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
            data_exists = isdir(partition_dir) && any(endswith(f, ".parquet") for f in readdir(partition_dir))
        end

        if !data_exists
            _add_data(source, year, month)
        else
            @info "Data already exists, skipping" table = source.table_name year month
        end
    end
    return
end
