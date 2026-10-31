"""
    _query(db::AEMDB, sql::String, params = ())

Executes `sql` against `db`'s connection and materializes the result as a `DataFrame`.
`params` are bound as positional `?` placeholders when provided.
"""
_query(db::AEMDB, sql::String) = DataFrame(DuckDB.execute(db.db, sql))

_query(db::AEMDB, sql::String, params) = DataFrame(DuckDB.execute(db.db, sql, params))

# Partitions that predate the INTERVENTION column are the normal run, so the filter applies
# only when the column exists: naming a column absent from every file is a DuckDB Binder Error.
_intervention_where(schema) = "INTERVENTION" in schema ? "AND COALESCE(INTERVENTION, 0) = ?" : ""

_push_intervention!(params, schema, intervention) = "INTERVENTION" in schema ? push!(params, intervention) : params

# One partition storing a numeric column as VARCHAR widens it to VARCHAR across the whole glob.
_cast_double(col) = "TRY_CAST($col AS DOUBLE) AS $col"


"""
    _table_schema(db, table) -> Vector{String}

The column names of `table`, a `FROM` source such as the fragment [`read_hive`](@ref) returns.
"""
_table_schema(db, table::AbstractString) = names(_query(db, "SELECT * FROM $table LIMIT 0"))


"""
    _table_is_cached(db, table_name) -> Bool

Whether `table_name` has at least one parquet file in the cache. A glob matching no file is
`false`; a failure to check (credentials, network, corrupt parquet) raises DuckDB's exception.
"""
function _table_is_cached(db, table_name::Symbol)
    hive_root = _parse_hive_root(db.config)
    df = _query(db, "SELECT COUNT(*) AS n FROM glob('$hive_root/$table_name/**/*.parquet')")
    return df.n[1] > 0
end


"""
    _require_cached(db, table_name; context = "")

Throws an `ArgumentError` naming `table_name` and the `populate` call that fills it when the
table has no cached partition. `context` is appended to the message.
"""
function _require_cached(db, table_name::Symbol; context::AbstractString = "")
    _table_is_cached(db, table_name) && return
    suffix = isempty(context) ? "" : " " * context
    throw(
        ArgumentError(
            "$table_name is not cached: run `populate(db, :$table_name, <from>, <to>)` first.$suffix",
        ),
    )
    return
end


"""
    _require_columns(table_name, schema, columns)

Throws an `ArgumentError` when a name in `columns` is absent from `schema`, the columns of the
cached `table_name`.
"""
function _require_columns(table_name::Symbol, schema, columns)
    for col in columns
        col in schema || throw(
            ArgumentError(
                "$table_name's cached partitions have no $col column at all: they predate " *
                    "AEMO publishing it. Run `populate(db, :$table_name, <from>, <to>; force_new = true)` " *
                    "to re-download.",
            ),
        )
    end
    return
end


"""
    _read_dispatch_table(columns, db, table_name, key, date_range; intervention = 0, where = "", order = false)

Reads one row per `(SETTLEMENTDATE, key)` of the dispatch-run table `table_name` with
`first(date_range) <= SETTLEMENTDATE < last(date_range)`, keeping the latest archive month's
row and the `intervention` run.

# Arguments
- `columns`: the select expressions after `SETTLEMENTDATE` and `key`, or a function of the cached
  schema returning them.
- `db`: an `AEMDB` connection.
- `table_name`: the cached table, which must exist.
- `key`: the column identifying a row within an interval, e.g. `"DUID"`.
- `date_range`: the half-open interval range.
- `intervention`: `0` for the pricing run, `1` for the physical run.
- `where`: an extra SQL predicate starting with `AND`; the table is aliased `src`.
- `order`: sort the rows by `SETTLEMENTDATE` and `key`.

# Returns
A `DataFrame` with `SETTLEMENTDATE`, `key` and the selected columns.
"""
function _read_dispatch_table(
        columns, db, table_name::Symbol, key::AbstractString, date_range;
        intervention::Integer = 0, where::AbstractString = "", order::Bool = false,
    )
    _require_cached(db, table_name)
    table = read_hive(db, table_name)
    schema = _table_schema(db, table)
    select_cols = columns isa Function ? columns(schema) : columns
    params = Any[first(date_range), last(date_range)]
    _push_intervention!(params, schema, intervention)
    return _query(
        db,
        """
        SELECT $(join(["SETTLEMENTDATE", key, select_cols...], ", "))
        FROM $table AS src
        WHERE SETTLEMENTDATE >= ? AND SETTLEMENTDATE < ? $(_intervention_where(schema)) $where
        QUALIFY row_number() OVER (PARTITION BY SETTLEMENTDATE, $key ORDER BY archive_month DESC) = 1
        $(order ? "ORDER BY SETTLEMENTDATE, $key" : "")
        """,
        params,
    )
end


"""
    _with_registered(f, db, df, name)

Registers `df` as the DuckDB view `name`, calls `f()` and unregisters the view, also when `f`
throws.

# Returns
The result of `f()`.
"""
function _with_registered(f, db, df, name::AbstractString)
    DuckDB.register_data_frame(db.db, df, name)
    try
        return f()
    finally
        DuckDB.unregister_table(db.db, name)
    end
end


"""
    _ceil_timestamp_sql(column, resolution) -> String

A DuckDB timestamp expression rounding `column` up to a positive `Dates.Period`, with the
same epoch as `Dates.ceil` on `DateTime`.
"""
function _ceil_timestamp_sql(column::AbstractString, resolution::Dates.Period)
    if resolution isa Union{Month, Quarter, Year}
        width = Dates.value(Month(resolution))
        unit = "months"
    else
        width = Dates.value(Millisecond(resolution))
        unit = "milliseconds"
    end
    width > 0 || throw(ArgumentError("resolution must be positive, got $resolution"))
    origin = resolution isa Week ? "0000-01-03" : "0000-01-01"
    interval = "INTERVAL '$width $unit'"
    bucket = "time_bucket($interval, $column, TIMESTAMP '$origin')"
    return "CASE WHEN $column = $bucket THEN $column ELSE $bucket + $interval END"
end
