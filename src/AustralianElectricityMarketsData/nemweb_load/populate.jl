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
