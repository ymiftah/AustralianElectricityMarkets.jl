# ── HTTP fetch — download and cache a NEMWEB archive ZIP ─────────────────────

"""
    _get_archive(table_name::String, year::Int, month::Int) -> String

Download and cache a NEMWEB data archive ZIP file. Returns path to the ZIP file.

# Arguments
- `table_name::String`: Name of the NEMWEB table
- `year::Int`: Year to download
- `month::Int`: Month to download

# Returns
- `String`: Path to the downloaded ZIP file (caller is responsible for deletion)
"""
function _get_archive(table_name::String, year::Int, month::Int)::String
    tmp_zip = tempname(_local_tmp_dir()) * ".zip"

    url = replace(
        NEMWEB_URL,
        "{year}" => year,
        "{month:02d}" => lpad(month, 2, '0'),
        "{table}" => table_name
    )
    url_alt = replace(
        NEMWEB_URL_ALT,
        "{year}" => year,
        "{month:02d}" => lpad(month, 2, '0'),
        "{table}" => table_name
    )

    # Only a 404 (MissingDataError) justifies trying the other naming pattern - AEMO uses
    # PUBLIC_DVD for some months and PUBLIC_ARCHIVE#...#FILE01# for others. A
    # TransientDownloadError propagates immediately instead: when NEMWEB is rate-limiting
    # us, retrying a second URL only adds load, and the retry/backoff already happened
    # inside _download_and_cache.
    try
        @info "Downloading from primary URL" url
        _download_and_cache(url, tmp_zip)
    catch e
        e isa MissingDataError || rethrow()
        try
            @info "Downloading from alternative URL" url_alt
            _download_and_cache(url_alt, tmp_zip)
        catch e2
            e2 isa MissingDataError || rethrow()
            throw(
                MissingDataError(
                    "Requested data for table: $table_name, year: $year, month: $month\n" *
                        "returned HTTP 404 under both known URL patterns, so AEMO does not publish it.\n" *
                        "Check http://nemweb.com.au/#mms-data-model to confirm availability."
                )
            )
        end
    end

    return tmp_zip   # return the zip path, not an extracted CSV
end

"Maximum attempts per URL before giving up with a [`TransientDownloadError`](@ref)."
const _DOWNLOAD_MAX_ATTEMPTS = 5
"Base seconds for the exponential backoff between download attempts."
const _DOWNLOAD_BASE_DELAY_S = 2.0

"""
    _is_transient_status(status::Integer) -> Bool

Whether an HTTP status means "ask again later" rather than "this does not exist".

`403` is in the list because that is how NEMWEB rate-limits: a burst of requests (easily
produced by bulk-populating a wide date range, or by two populate runs at once) gets 403 on
URLs that resolve perfectly a minute later. Treating it as absence is what silently puts
holes in a cache.
"""
_is_transient_status(status::Integer) =
    status in (403, 408, 425, 429, 500, 502, 503, 504)

"""
    _download_and_cache(url::String, cache_path::String)

Download `url` to `cache_path`, retrying transient failures with exponential backoff.

Throws [`MissingDataError`](@ref) on a 404 (and any other non-transient non-200), or
[`TransientDownloadError`](@ref) if a transient failure - see [`_is_transient_status`](@ref)
\\- persists across [`_DOWNLOAD_MAX_ATTEMPTS`](@ref) attempts. The distinction is the whole
point: callers skip the former and must not skip the latter.
"""
function _download_and_cache(url::String, cache_path::String)
    last_reason = "unknown"
    for attempt in 1:_DOWNLOAD_MAX_ATTEMPTS
        transient = false
        response = nothing
        try
            # status_exception=false so a non-2xx comes back as a response to classify
            # rather than an exception; retry=false so backoff stays in one place here.
            response = HTTP.get(url; status_exception = false, retry = false)
        catch e
            # Connection-level failure (DNS, reset, timeout) - no status to classify, and
            # transient by nature.
            (e isa HTTP.Exceptions.HTTPError || e isa Base.IOError) || rethrow()
            transient = true
            last_reason = sprint(showerror, e)
        end

        if !isnothing(response)
            if response.status == 200
                mkpath(dirname(cache_path))
                return write(cache_path, response.body)
            elseif _is_transient_status(response.status)
                transient = true
                last_reason = "HTTP $(response.status)"
            else
                throw(MissingDataError("HTTP $(response.status): Unable to download from $url"))
            end
        end

        if transient && attempt < _DOWNLOAD_MAX_ATTEMPTS
            delay = _DOWNLOAD_BASE_DELAY_S * 2.0^(attempt - 1)
            @warn "Transient download failure; retrying" url reason = last_reason attempt delay_s = delay
            sleep(delay)
        end
    end
    return throw(
        TransientDownloadError(
            "$last_reason after $_DOWNLOAD_MAX_ATTEMPTS attempts: $url\n" *
                "NEMWEB is likely rate-limiting. This is NOT a missing month - re-run to gap-fill."
        )
    )
end

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
        zip_path = _get_archive(source.table_name, year, month)
        d_only_path, available_cols = try
            _extract_d_lines(zip_path)
        finally
            # The zip is deleted as soon as the D-lines-only CSV has been
            # extracted from it.
            rm(zip_path; force = true)
        end

        try
            @info "Writing Hive-partitioned parquet" path = source.path
            conn = _new_duckdb_connection(get_filesystem(source))
            try
                _csv_to_parquet(
                    conn, d_only_path, available_cols, source.table_columns, source.path,
                    source.partitions, source.table_sort_by, year, month;
                    islocal = islocal(source),
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

# ── AEMDB-based lookup and populate — public API ─────────────────────────────

"""
    get_table(db::AEMDB, table_name::Symbol) -> DataSource

Build the `DataSource` for `table_name`, rooted at `db.config.hive_location`.
Available tables are listed in `_TABLE_SPECS` / `list_available_tables()`.
"""
function get_table(db::AEMDB, table_name::Symbol)::DataSource
    spec = get(_TABLE_SPECS_BY_NAME, table_name) do
        throw(ArgumentError("Table $table_name not found. Available: $(list_available_tables())"))
    end
    return DataSource(spec.name, spec.columns, db.config; table_sort_by = spec.sort_by)
end

"""
    list_available_tables() -> Vector{String}

List all NEMWEB tables known to `_TABLE_SPECS`.

# Examples
```julia
tables = list_available_tables()
println("Available tables: \$tables")
```
"""
list_available_tables()::Vector{String} = [spec.name for spec in _TABLE_SPECS]

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

function Base.show(io::IO, db::AEMDB)
    return print(io, "AEMDB(hive_location=\"$(db.config.hive_location)\", filesystem=\"$(get_filesystem(db.config))\")")
end

function Base.show(io::IO, ::MIME"text/plain", db::AEMDB)
    println(io, "AEMDB")
    println(io, "  hive_location: ", db.config.hive_location)
    println(io, "  filesystem: ", get_filesystem(db.config))
    println(io, "  tables:")

    rows = map(list_available_tables()) do name
        source = get_table(db, Symbol(name))
        range = cached_date_range(source)
        coverage = range === nothing ? "(not cached)" : "$(range[1]) … $(range[2])"
        (name, coverage)
    end

    name_width = maximum(length(r[1]) for r in rows)
    for (name, coverage) in rows
        println(io, "    ", rpad(name, name_width), "  ", coverage)
    end
    return
end
