"""
    _query(db::AEMDB, sql::String, params = ())

Executes `sql` against `db`'s connection and materializes the result as a `DataFrame`.
`params` are bound as positional `?` placeholders when provided.
"""
_query(db::AEMDB, sql::String) = DataFrame(DuckDB.execute(db.db, sql))

_query(db::AEMDB, sql::String, params) = DataFrame(DuckDB.execute(db.db, sql, params))

# Only 0 (pricing run) and 1 (physical run, pricing run where the interval has none) are runs.
function _check_intervention(intervention::Integer)
    intervention in (0, 1) || throw(
        ArgumentError("intervention must be 0 (pricing run) or 1 (physical run), got $intervention"),
    )
    return
end


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
