"""
    read_hive(db::AEMDB, table_name::Symbol)

Builds the SQL `read_parquet(...)` source fragment for a hive-partitioned parquet dataset, for use
as a `FROM` source in a larger query. Partitions written before a column was added read back
`NULL` for it.

# Arguments
- `db::AEMDB`: The database connection wrapper to use.
- `table_name::Symbol`: The name of the table to read.

# Returns
A `String` SQL fragment.
"""
function read_hive(
        db::AEMDB,
        table_name::Symbol,
    )
    hive_root = _parse_hive_root(db.config)
    return "read_parquet('$hive_root/$table_name/**/*.parquet', hive_partitioning=true, union_by_name=true)"
end


"""
    read_hive(db::AEMDB, table_name::Symbol, date_range)

Like `read_hive(db, table_name)`, restricted to the `archive_month` partitions from the month of
the day before `first(date_range)` to the month of the day after `last(date_range)`. Falls back
to every partition when none of those months is cached.

# Arguments
- `db::AEMDB`: The database connection wrapper to use.
- `table_name::Symbol`: The name of the table to read.
- `date_range`: The `Date` or `DateTime` values the query reads, ordered.

# Returns
A `String` SQL fragment.
"""
function read_hive(db::AEMDB, table_name::Symbol, date_range)
    hive_root = _parse_hive_root(db.config)
    months = Dates.firstdayofmonth(Date(first(date_range)) - Day(1)):Month(1):Dates.firstdayofmonth(Date(last(date_range)) + Day(1))
    wanted = Set("archive_month=$m" for m in months)
    files = String[
        f for f in DataFrame(DuckDB.execute(db.db, "SELECT file FROM glob('$hive_root/$table_name/**/*.parquet')")).file
            if basename(dirname(f)) in wanted
    ]
    isempty(files) && return read_hive(db, table_name)
    list = join(("'$f'" for f in sort!(files)), ", ")
    return "read_parquet([$list], hive_partitioning=true, union_by_name=true)"
end
