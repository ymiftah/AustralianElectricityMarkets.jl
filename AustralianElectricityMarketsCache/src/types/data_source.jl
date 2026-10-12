"""
    DataSource

Immutable description of one NEMWEB MMS table, cached as Hive-partitioned
parquet under `config.hive_location`. Construction is pure — it does not
touch the filesystem; `_add_data` creates `path` lazily on first write.

The filesystem (`"file"`, `"s3"`, `"gs"`) is not stored separately — it's
recovered from `path`'s scheme via `get_filesystem(::String)`, since `path`
already encodes it (`s3://...`, `gs://...`, or a bare local path).

# Fields
- `table_name::String`: Name of the table
- `table_columns::Vector{String}`: Columns to include
- `table_sort_by::Vector{String}`: Columns to sort by within each output file (row-group locality; not an enforced uniqueness constraint)
- `partitions::Vector{String}`: Partition columns
- `path::String`: Path to parquet dataset (local path, or `scheme://...` URI for remote)
- `month_filter_column::Union{Nothing, String}`: Column scoping rows to their archive month, or `nothing`
"""
struct DataSource
    table_name::String
    table_columns::Vector{String}
    table_sort_by::Vector{String}
    partitions::Vector{String}
    path::String
    month_filter_column::Union{Nothing, String}
end


get_filesystem(source::DataSource) = get_filesystem(source.path)

islocal(source::DataSource) = islocal(get_filesystem(source))


"""
    DataSource(table_name, table_columns, config=HiveConfiguration();
               table_sort_by=String[], add_partitions=String[], month_filter_column=nothing)

Create a new `DataSource` for a NEMWEB table, rooted at `config.hive_location`.
Works for both local and remote (`s3`/`gs`) `config.filesystem` — path
construction is delegated to `_parse_hive_root`.
"""
function DataSource(
        table_name::String,
        table_columns::Vector{String},
        config::HiveConfiguration = HiveConfiguration();
        table_sort_by::Vector{String} = String[],
        add_partitions::Vector{String} = String[],
        month_filter_column::Union{Nothing, String} = nothing,
    )
    return DataSource(
        table_name,
        table_columns,
        table_sort_by,
        vcat(add_partitions, ARCHIVE_MONTH_PARTITION),
        joinpath(_parse_hive_root(config), table_name),
        month_filter_column,
    )
end
