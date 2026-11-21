"""
    DataSource

Description of one NEMWEB MMS table cached as Hive-partitioned parquet under
`config.hive_location`. The filesystem is recovered from the scheme of `path`.

# Fields
- `table_name::String`: Name of the table
- `table_columns::Vector{String}`: Columns to include
- `table_sort_by::Vector{String}`: Columns to sort by within each output file (row-group locality; not an enforced uniqueness constraint)
- `partitions::Vector{String}`: Partition columns
- `path::String`: Path to parquet dataset (local path, or `scheme://...` URI for remote)
- `month_filter_column::Union{Nothing, String}`: Column scoping rows to their archive month, or `nothing`
- `row_filter::Union{Nothing, Pair{String, String}}`: `column => value` keeping only the rows whose raw
  `column` equals `value`, or `nothing` to keep every row
"""
struct DataSource
    table_name::String
    table_columns::Vector{String}
    table_sort_by::Vector{String}
    partitions::Vector{String}
    path::String
    month_filter_column::Union{Nothing, String}
    row_filter::Union{Nothing, Pair{String, String}}
end


get_filesystem(source::DataSource) = get_filesystem(source.path)

islocal(source::DataSource) = islocal(get_filesystem(source))


"""
    DataSource(table_name, table_columns, config=HiveConfiguration();
               table_sort_by=String[], month_filter_column=nothing, row_filter=nothing)

Create a new `DataSource` for a NEMWEB table, rooted at `config.hive_location` on a local
or remote (`s3`/`gs`) filesystem. Does not touch the filesystem.
"""
function DataSource(
        table_name::String,
        table_columns::Vector{String},
        config::HiveConfiguration = HiveConfiguration();
        table_sort_by::Vector{String} = String[],
        month_filter_column::Union{Nothing, String} = nothing,
        row_filter::Union{Nothing, Pair{String, String}} = nothing,
    )
    return DataSource(
        table_name,
        table_columns,
        table_sort_by,
        [ARCHIVE_MONTH_PARTITION],
        joinpath(_parse_hive_root(config), table_name),
        month_filter_column,
        row_filter,
    )
end
