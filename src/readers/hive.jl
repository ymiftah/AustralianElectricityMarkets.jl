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


# The cached parquet files of `table_name` whose `archive_month` is read by `read_hive(db, table_name, date_range)`,
# with the months and their `yyyy-mm` labels.
function _hive_range_files(db::AEMDB, table_name::Symbol, date_range)
    hive_root = _parse_hive_root(db.config)
    months = Dates.firstdayofmonth(Date(first(date_range)) - Day(1)):Month(1):Dates.firstdayofmonth(Date(last(date_range)) + Day(1))
    labels = [Dates.format(m, "yyyy-mm") for m in months]
    wanted = Set(labels)
    files = String[
        f for f in DataFrame(DuckDB.execute(db.db, "SELECT file FROM glob('$hive_root/$table_name/**/*.parquet')")).file
            if (m = match(r"^archive_month=(\d{4}-\d{2})", basename(dirname(f)))) !== nothing && m.captures[1] in wanted
    ]
    return files, months, labels
end


# Whether `read_hive(db, table_name, date_range)` has at least one cached partition to read.
_cached_in_range(db::AEMDB, table_name::Symbol, date_range) = !isempty(first(_hive_range_files(db, table_name, date_range)))


"""
    read_hive(db::AEMDB, table_name::Symbol, date_range)

Like `read_hive(db, table_name)`, restricted to the `archive_month` partitions from the month of
the day before `first(date_range)` to the month of the day after `last(date_range)`. Throws an
`ArgumentError` naming the uncached months and the `populate` call when none of them is cached.

# Arguments
- `db::AEMDB`: The database connection wrapper to use.
- `table_name::Symbol`: The name of the table to read.
- `date_range`: The `Date` or `DateTime` values the query reads, ordered.

# Returns
A `String` SQL fragment.
"""
function read_hive(db::AEMDB, table_name::Symbol, date_range)
    files, months, labels = _hive_range_files(db, table_name, date_range)
    if isempty(files)
        throw(
            ArgumentError(
                "$table_name has no cached partition for $(join(labels, ", ")): run " *
                    "`populate(db, :$table_name, $(first(months)), $(Dates.lastdayofmonth(last(months))))` first.",
            ),
        )
    end
    list = join(("'$f'" for f in sort!(files)), ", ")
    return "read_parquet([$list], hive_partitioning=true, union_by_name=true)"
end
