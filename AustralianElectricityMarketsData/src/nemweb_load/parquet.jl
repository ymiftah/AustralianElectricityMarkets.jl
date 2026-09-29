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
    _month_filter_bounds(year::Int, month::Int) -> (String, String)

The NEMWEB-formatted (`"YYYY/MM/DD HH:MM:SS"`) lower (exclusive) and upper (inclusive)
bounds of one archive month, for lexicographic comparison against a raw CSV field. An
interval ending exactly on the lower bound belongs to the *previous* month.

# Returns
- `(String, String)`: `(lo, hi)`.
"""
function _month_filter_bounds(year::Int, month::Int)::Tuple{String, String}
    lo = "$year/$(lpad(month, 2, '0'))/01 00:00:00"
    next_year, next_month = month == 12 ? (year + 1, 1) : (year, month + 1)
    hi = "$next_year/$(lpad(next_month, 2, '0'))/01 00:00:00"
    return lo, hi
end

"""
    _write_d_lines(out::IO, zip_path::String;
                   month_filter_column=nothing, lo=nothing, hi=nothing) -> Vector{String}

Stream the ZIP's first `.csv` entry, in one pass via `ZipArchives.jl`, writing only the
real "D" data-record lines to `out` and capturing the "I" record's column names/order
along the way.

When `month_filter_column` is given, a "D" line is written only when that column's raw
field, quotes stripped, satisfies `lo < field <= hi`.

# Returns
- `Vector{String}`: the file's column names/order, from its "I" record.
"""
function _write_d_lines(
        out::IO, zip_path::String;
        month_filter_column::Union{Nothing, String} = nothing,
        lo::Union{Nothing, String} = nothing, hi::Union{Nothing, String} = nothing,
    )::Vector{String}
    # Pre-filtering to D-only lines before DuckDB ever sees the file works around a DuckDB
    # read_csv behavior confirmed directly on a real BIDPEROFFER_D file: feeding it the
    # *raw* NEMWEB file — narrow C header/trailer + I header rows mixed with wide D rows,
    # absorbed via null_padding/ignore_errors — produced one MORE row than the true D-row
    # count. Filtering happens in this single Julia pass over the decompressed stream
    # instead, rather than shelling out to `grep` or writing the full CSV to disk first.
    reader = ZipReader(read(zip_path))
    entries = zip_names(reader)
    idx = findfirst(e -> endswith(lowercase(e), ".csv"), entries)
    isnothing(idx) && throw(MissingDataError("No CSV file found in $zip_path"))

    available_cols = String[]
    filter_idx = nothing
    io = zip_openentry(reader, entries[idx])
    for line in eachline(io)
        if startswith(line, "D,")
            if !isnothing(filter_idx)
                field = strip(split(line, ",")[4 + filter_idx], '"')
                (lo < field <= hi) || continue
            end
            println(out, line)
        elseif isempty(available_cols) && startswith(line, "I,")
            # I: I, namespace, report, version, col1, col2, ...
            available_cols = String.(strip.(split(line, ",")[5:end]))
            if !isnothing(month_filter_column)
                filter_idx = findfirst(==(month_filter_column), available_cols)
            end
        end
    end
    isempty(available_cols) && throw(MissingDataError("No I (header) record found in $zip_path"))
    return available_cols
end

"""
    _extract_d_lines(zip_path::String;
                     month_filter_column=nothing, lo=nothing, hi=nothing) -> (String, Vector{String})

Write one ZIP's D-lines, via [`_write_d_lines`](@ref), to a new temp file. Returns
`(d_only_path, available_cols)`; caller deletes `d_only_path` when done.
"""
function _extract_d_lines(
        zip_path::String;
        month_filter_column::Union{Nothing, String} = nothing,
        lo::Union{Nothing, String} = nothing, hi::Union{Nothing, String} = nothing,
    )::Tuple{String, Vector{String}}
    d_path = tempname(_local_tmp_dir()) * ".csv"
    available_cols = String[]
    try
        open(d_path, "w") do out
            available_cols = _write_d_lines(out, zip_path; month_filter_column, lo, hi)
        end
    catch
        rm(d_path; force = true)
        rethrow()
    end
    return d_path, available_cols
end

"""
    _extract_d_lines(zip_paths::Vector{String};
                     month_filter_column=nothing, lo=nothing, hi=nothing) -> (String, Vector{String})

Stream every ZIP part's D-lines, via [`_write_d_lines`](@ref), straight into one combined
temp file, in part order — no intermediate per-part file. Returns `(d_only_path,
available_cols)`, taking `available_cols` from the first part; caller deletes
`d_only_path` when done.
"""
function _extract_d_lines(
        zip_paths::Vector{String};
        month_filter_column::Union{Nothing, String} = nothing,
        lo::Union{Nothing, String} = nothing, hi::Union{Nothing, String} = nothing,
    )::Tuple{String, Vector{String}}
    combined_path = tempname(_local_tmp_dir()) * ".csv"
    available_cols = String[]
    try
        open(combined_path, "w") do out
            for zip_path in zip_paths
                part_cols = _write_d_lines(out, zip_path; month_filter_column, lo, hi)
                isempty(available_cols) && (available_cols = part_cols)
            end
        end
    catch
        rm(combined_path; force = true)
        rethrow()
    end
    return combined_path, available_cols
end

_datetime_parse_expr(col::String) = "try_strptime(\"$col\", '%Y/%m/%d %H:%M:%S')"
_cast_expr(col::String) = _cast_expr(col, get(COLUMN_TYPES, col, String))
_cast_expr(col::String, ::Type{DateTime}) = "$(_datetime_parse_expr(col)) AS \"$col\""
_cast_expr(col::String, ::Type{Date}) = "CAST($(_datetime_parse_expr(col)) AS DATE) AS \"$col\""
_cast_expr(col::String, ::Type{String}) = "\"$col\" AS \"$col\""
_cast_expr(col::String, T::DataType) = "TRY_CAST(\"$col\" AS $(_duckdb_type(T))) AS \"$col\""

"""
    _csv_to_parquet(conn, csv_path, available_cols, table_columns, path, partitions, sort_by, year, month;
                    islocal=true, month_filter_column=nothing)

Read `csv_path` entirely inside DuckDB, in one query — every line as VARCHAR,
filtered to real "D" records, cast to `COLUMN_TYPES`, missing columns filled
as typed NULL, tagged with `archive_month` — and COPY straight to
Hive-partitioned parquet.

`available_cols` is the file's real column names/order and must be supplied
explicitly, since `csv_path` may be a pre-filtered, D-lines-only file (see
`_extract_d_lines`) with no header row left to read it from.

When `month_filter_column` is given, rows are kept only when that column's parsed
datetime falls in `(first of month, first of next month]` — the MMSDM convention that a
datetime column holds the interval **end**, so the boundary instant belongs to the
earlier month — and, if `sort_by` gives a non-empty key, rows are deduplicated on it.
"""
function _csv_to_parquet(
        conn, csv_path::String, available_cols::Vector{String}, table_columns::Vector{String}, path::String,
        partitions::Vector{String}, sort_by::Vector{String}, year::Int, month::Int;
        islocal::Bool = true, month_filter_column::Union{Nothing, String} = nothing,
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
    next_archive_month = archive_month + Month(1)
    sort_cols = intersect(vcat(partitions, sort_by), table_columns)
    order_by = isempty(sort_cols) ? "" : "ORDER BY " * join(("\"$c\"" for c in sort_cols), ", ")
    partition_by = join(partitions, ", ")

    month_where = ""
    if !isnothing(month_filter_column) && month_filter_column in cols_present
        parsed = _datetime_parse_expr(month_filter_column)
        month_where = "AND $parsed > TIMESTAMP '$archive_month' AND $parsed <= TIMESTAMP '$next_archive_month'"
    end

    distinct_on = (!isnothing(month_filter_column) && !isempty(sort_cols)) ?
        "DISTINCT ON ($(join(("\"$c\"" for c in sort_cols), ", "))) " : ""

    islocal && mkpath(path)
    sql = """
        COPY (
            SELECT $distinct_on$select_list, DATE '$archive_month' AS $ARCHIVE_MONTH_PARTITION
            FROM read_csv('$csv_path', header=false, names=$names_sql, all_varchar=true,
                           delim=',', quote='"', escape='"', strict_mode=false,
                           null_padding=true, ignore_errors=true)
            WHERE _record_type = 'D' $month_where
            $order_by
        ) TO '$path' (FORMAT PARQUET, PARTITION_BY ($partition_by), OVERWRITE_OR_IGNORE TRUE)
    """
    return DBInterface.execute(conn, sql)
end
