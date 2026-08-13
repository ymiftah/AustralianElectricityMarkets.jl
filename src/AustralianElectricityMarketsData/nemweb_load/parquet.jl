"""
    _new_duckdb_connection(filesystem::String = "file") -> DuckDB.DB

Open a DuckDB connection configured to spill to a real (non-tmpfs) disk
directory once memory use crosses a conservative bound, rather than growing
unbounded. Loads the `httpfs` extension when `filesystem` is remote
(`"s3"`/`"gs"`), so subsequent `COPY`/`glob()` calls can reach it.
"""
function _new_duckdb_connection(filesystem::String = "file")
    # Without this, an unconfigured in-memory DuckDB.DB() has nowhere to spill
    # a large sort/aggregate to, and can be OOM-killed by the OS on wide,
    # multi-million-row tables (confirmed directly: a bare connection
    # processing BIDPEROFFER_D was killed at ~7.5GB resident).
    conn = DuckDB.DB()
    if !islocal(filesystem)
        # Two separate calls, not one "INSTALL httpfs; LOAD httpfs;" string —
        # DuckDB.jl 1.5.2 raises "Cannot prepare multiple statements at once!"
        # on a semicolon-joined multi-statement string (confirmed directly).
        DuckDB.execute(conn, "INSTALL httpfs;")
        DuckDB.execute(conn, "LOAD httpfs;")
    end
    spill_dir = expanduser("~/.cache/aem_duckdb_spill")
    mkpath(spill_dir)
    DBInterface.execute(conn, "SET memory_limit='2GB'")
    DBInterface.execute(conn, "SET temp_directory='$spill_dir'")
    return conn
end

"""
    _local_tmp_dir() -> String

A real-disk (non-tmpfs) scratch directory for extracted CSVs and line
batches.
"""
function _local_tmp_dir()
    # Julia's bare tempname() defaults to tempdir(), which on this system is
    # RAM-backed /tmp — using it here would silently defeat the whole point of
    # spilling the pipeline's intermediate files to disk instead of holding
    # them in memory (confirmed directly: /tmp ran out of space during this
    # same investigation).
    dir = expanduser("~/.cache/aem_nemweb_tmp")
    mkpath(dir)
    return dir
end

"""
    read_parquet_file(parquet_path::String) -> DataFrame

Read a parquet file using DuckDB.
"""
function read_parquet_file(parquet_path::String)::DataFrame
    conn = _new_duckdb_connection()
    try
        query = "SELECT * FROM read_parquet('$parquet_path', hive_partitioning=true)"
        return DBInterface.execute(conn, query) |> DataFrame
    catch e
        e isa DuckDB.QueryException || rethrow()
        @warn "Error reading parquet file: $parquet_path" exception = e
        return DataFrame()
    finally
        DBInterface.close!(conn)
    end
end

"""
    write_hive_parquet(df::DataFrame, path::String, partition_cols::Vector{String})

Write a DataFrame to a Hive-partitioned Parquet dataset using DuckDB.

Each unique combination of `partition_cols` values becomes a subdirectory
`col=value/` under `path`.

# Arguments
- `df::DataFrame`: Data to write
- `path::String`: Root output directory
- `partition_cols::Vector{String}`: Column names to partition by (e.g. `["archive_month"]`)

# Examples
```julia
write_hive_parquet(df, "/cache/DISPATCHPRICE", ["archive_month"])
```
"""
function write_hive_parquet(df::DataFrame, path::String, partition_cols::Vector{String})
    mkpath(path)
    conn = _new_duckdb_connection()
    try
        DuckDB.register_data_frame(conn, df, "temp_table")
        cols = join(partition_cols, ", ")
        return DBInterface.execute(conn, "COPY temp_table TO '$path' (FORMAT PARQUET, PARTITION_BY ($cols), OVERWRITE_OR_IGNORE TRUE)")
    finally
        DBInterface.close!(conn)
    end
end

# ── CSV → Parquet, entirely inside DuckDB ────────────────────────────────────
#
# NEMWEB CSVs mix three record types on one file, identified by the first
# field of each line:
#   C  comment/header/trailer record (variable width, often shorter than D)
#   I  names the real columns for the D records that follow
#   D  an actual data row
# Real columns always start at field 5, after a fixed 4-field prefix
# (record_type, namespace, report, version) — confirmed empirically against
# real files, e.g.:
#   I,DISPATCH,REGIONSUM,9,SETTLEMENTDATE,RUNNO,REGIONID,...
#   I,PARTICIPANT_REGISTRATION,STATION,1,STATIONID,STATIONNAME,...
# Rather than making DuckDB's CSV parser skip rows structurally (it has no
# concept of this convention), every line is read as plain VARCHAR and the
# record type is filtered with a plain SQL WHERE clause.

const _DUCKDB_TYPE_NAMES = Dict{DataType, String}(
    Float32 => "FLOAT", Float64 => "DOUBLE", Int8 => "TINYINT", Int32 => "INTEGER",
    Bool => "BOOLEAN", String => "VARCHAR", DateTime => "TIMESTAMP", Date => "DATE",
)
_duckdb_type(T::DataType) = get(_DUCKDB_TYPE_NAMES, T, "VARCHAR")

"""
    _extract_csv_entry(zip_path::String) -> String

Stream the ZIP's first `.csv` entry to a temp file on disk via `ZipArchives.jl`
and return the temp path. Caller deletes it when done.
"""
function _extract_csv_entry(zip_path::String)::String
    reader = ZipReader(read(zip_path))
    entries = zip_names(reader)
    idx = findfirst(e -> endswith(lowercase(e), ".csv"), entries)
    isnothing(idx) && throw(MissingDataError("No CSV file found in $zip_path"))

    tmp_csv = tempname(_local_tmp_dir()) * ".csv"
    open(tmp_csv, "w") do out
        io = zip_openentry(reader, entries[idx])
        buf = Vector{UInt8}(undef, 1 << 20)  # 1 MB, reused across reads
        while !eof(io)
            n = readbytes!(io, buf, length(buf))
            n == 0 && break
            write(out, view(buf, 1:n))
        end
    end
    return tmp_csv
end

"""
    _filter_d_lines(csv_path::String) -> String

Copy only the real "D" data-record lines of `csv_path` to a new temp file via
the system `grep` and return its path. Caller deletes it when done.
"""
function _filter_d_lines(csv_path::String)::String
    # This exists to work around a DuckDB read_csv behavior confirmed
    # directly on a real BIDPEROFFER_D file: feeding it the *raw* NEMWEB file
    # — narrow C header/trailer + I header rows mixed with wide D rows,
    # absorbed via null_padding/ignore_errors — produced one MORE row than
    # the true D-row count. Reproducible regardless of threads, so not a
    # parallel chunk-boundary race — something in DuckDB's dialect/schema
    # sniffing trips on the mixed row widths. Pre-filtering with grep
    # (measured at a few seconds even on a multi-GB file) sidesteps the
    # issue rather than trying to root-cause DuckDB's sniffer further.
    d_path = tempname(_local_tmp_dir()) * ".csv"
    open(d_path, "w") do out
        run(pipeline(`grep '^D,' $csv_path`, stdout = out))
    end
    return d_path
end

"""
    _peek_header_columns(csv_path::String) -> Vector{String}

Read just the NEMWEB "I" record (line 2) to learn this file's real column
names and order. The only part of the file read in Julia rather than DuckDB.
"""
function _peek_header_columns(csv_path::String)::Vector{String}
    return open(csv_path) do io
        readline(io)                        # C record
        fields = split(readline(io), ",")   # I: I, namespace, report, version, col1, col2, ...
        String.(strip.(fields[5:end]))
    end
end

_cast_expr(col::String) = _cast_expr(col, get(COLUMN_TYPES, col, String))
_cast_expr(col::String, ::Type{DateTime}) = "try_strptime(\"$col\", '%Y/%m/%d %H:%M:%S') AS \"$col\""
_cast_expr(col::String, ::Type{Date}) = "CAST(try_strptime(\"$col\", '%Y/%m/%d %H:%M:%S') AS DATE) AS \"$col\""
_cast_expr(col::String, ::Type{String}) = "\"$col\" AS \"$col\""
_cast_expr(col::String, T::DataType) = "TRY_CAST(\"$col\" AS $(_duckdb_type(T))) AS \"$col\""

"""
    _csv_to_parquet(conn, csv_path, available_cols, table_columns, path, partitions, sort_by, year, month)

Read `csv_path` entirely inside DuckDB, in one query — every line as VARCHAR,
filtered to real "D" records, cast to `COLUMN_TYPES`, missing columns filled
as typed NULL, tagged with `archive_month` — and COPY straight to
Hive-partitioned parquet.

`available_cols` is the file's real column names/order (see
`_peek_header_columns`) and must be supplied explicitly, since `csv_path` may
be a pre-filtered, D-lines-only file (see `_filter_d_lines`) with no header
row left to read it from.
"""
function _csv_to_parquet(
        conn, csv_path::String, available_cols::Vector{String}, table_columns::Vector{String}, path::String,
        partitions::Vector{String}, sort_by::Vector{String}, year::Int, month::Int;
        islocal::Bool = true,
    )
    # No Julia-side DataFrame is ever constructed, and DuckDB's own
    # out-of-core read_csv (bounded via `_new_duckdb_connection`'s
    # memory_limit/temp_directory) handles arbitrarily large files directly;
    # there is no Julia-side batching layer to size a call around.
    raw_names = vcat(["_record_type", "_namespace", "_report", "_version"], available_cols)
    names_sql = "[" * join(("'$n'" for n in raw_names), ", ") * "]"

    cols_present = intersect(table_columns, available_cols)
    cols_missing = setdiff(table_columns, available_cols)
    select_list = join(
        vcat(
            [_cast_expr(c) for c in cols_present],
            ["CAST(NULL AS $(_duckdb_type(get(COLUMN_TYPES, c, String)))) AS \"$c\"" for c in cols_missing],
        ),
        ", ",
    )
    isempty(cols_missing) || @info "Columns not found in file" cols_missing year month

    archive_month = Date(year, month, 1)
    sort_cols = intersect(vcat(partitions, sort_by), table_columns)
    order_by = isempty(sort_cols) ? "" : "ORDER BY " * join(("\"$c\"" for c in sort_cols), ", ")
    partition_by = join(partitions, ", ")

    islocal && mkpath(path)
    sql = """
        COPY (
            SELECT $select_list, DATE '$archive_month' AS $ARCHIVE_MONTH_PARTITION
            FROM read_csv('$csv_path', header=false, names=$names_sql, all_varchar=true,
                           delim=',', quote='"', escape='"', strict_mode=false,
                           null_padding=true, ignore_errors=true)
            WHERE _record_type = 'D'
            $order_by
        ) TO '$path' (FORMAT PARQUET, PARTITION_BY ($partition_by), OVERWRITE_OR_IGNORE TRUE)
    """
    return DBInterface.execute(conn, sql)
end
