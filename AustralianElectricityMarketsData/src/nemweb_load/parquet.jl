"""
    _local_tmp_dir() -> String

Shared scratch directory, under the system tempdir, for DuckDB's spill files
and the pipeline's own downloaded/extracted files.
"""
function _local_tmp_dir()
    dir = joinpath(tempdir(), "aem_nemweb")
    mkpath(dir)
    return dir
end

"""
    _new_duckdb_connection(filesystem::String = "file") -> DuckDB.DB

Open a DuckDB connection configured to spill to disk once memory use crosses
a conservative bound, rather than growing unbounded. Loads the `httpfs`
extension when `filesystem` is remote (`"s3"`/`"gs"`), so subsequent
`COPY`/`glob()` calls can reach it.
"""
function _new_duckdb_connection(filesystem::String = "file")
    conn = DuckDB.DB()
    if !islocal(filesystem)
        # Two separate calls, not one "INSTALL httpfs; LOAD httpfs;" string —
        # DuckDB.jl 1.5.2 raises "Cannot prepare multiple statements at once!"
        # on a semicolon-joined multi-statement string (confirmed directly).
        DuckDB.execute(conn, "INSTALL httpfs;")
        DuckDB.execute(conn, "LOAD httpfs;")
    end
    DBInterface.execute(conn, "SET memory_limit='4GB'")
    DBInterface.execute(conn, "SET temp_directory='$(_local_tmp_dir())'")
    return conn
end

# ── CSV → Parquet, entirely inside DuckDB ────────────────────────────────────
#
# NEMWEB CSVs mix three record types on one file, identified by the first
# field of each line:
#   C  comment/header/trailer record (variable width, often shorter than D)
#   I  names the real columns for the D records that follow
#   D  an actual data row
# Real columns always start at field 5, after a fixed 4-field prefix
# (record_type, namespace, report, version), e.g.:
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
    _extract_d_lines(zip_path::String) -> (String, Vector{String})

Stream the ZIP's first `.csv` entry, in one pass via `ZipArchives.jl`, writing
only the real "D" data-record lines to a new temp file and capturing the "I"
record's column names/order along the way. Returns `(d_only_path,
available_cols)`; caller deletes `d_only_path` when done.
"""
function _extract_d_lines(zip_path::String)::Tuple{String, Vector{String}}
    # Pre-filtering to D-only lines before DuckDB ever sees the file works
    # around a DuckDB read_csv behavior confirmed directly on a real
    # BIDPEROFFER_D file: feeding it the *raw* NEMWEB file — narrow C
    # header/trailer + I header rows mixed with wide D rows, absorbed via
    # null_padding/ignore_errors — produced one MORE row than the true D-row
    # count. Filtering in this single Julia pass over
    # the decompressed stream (rather than shelling out to `grep`, or writing
    # the full CSV to disk and filtering it in a second pass).
    reader = ZipReader(read(zip_path))
    entries = zip_names(reader)
    idx = findfirst(e -> endswith(lowercase(e), ".csv"), entries)
    isnothing(idx) && throw(MissingDataError("No CSV file found in $zip_path"))

    d_path = tempname(_local_tmp_dir()) * ".csv"
    available_cols = String[]
    io = zip_openentry(reader, entries[idx])
    open(d_path, "w") do out
        for line in eachline(io)
            if startswith(line, "D,")
                println(out, line)
            elseif isempty(available_cols) && startswith(line, "I,")
                # I: I, namespace, report, version, col1, col2, ...
                available_cols = String.(strip.(split(line, ",")[5:end]))
            end
        end
    end
    isempty(available_cols) && throw(MissingDataError("No I (header) record found in $zip_path"))
    return d_path, available_cols
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

`available_cols` is the file's real column names/order and must be supplied
explicitly, since `csv_path` may be a pre-filtered, D-lines-only file (see
`_extract_d_lines`) with no header row left to read it from.
"""
function _csv_to_parquet(
        conn, csv_path::String, available_cols::Vector{String}, table_columns::Vector{String}, path::String,
        partitions::Vector{String}, sort_by::Vector{String}, year::Int, month::Int;
        islocal::Bool = true,
    )
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

    cols_extra = setdiff(available_cols, table_columns)
    isempty(cols_extra) || @info "Columns in file not captured by table spec" cols_extra year month

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
