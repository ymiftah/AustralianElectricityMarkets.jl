export read_plexos_xml, isp_record_counts, ISP_XML_TABLES

"""
The 27 `t_*` tables a PLEXOS `MasterDataSet` export carries, and the full set stored in the
ISP cache database.
"""
const ISP_XML_TABLES = (
    "t_action", "t_assembly", "t_attribute", "t_attribute_data", "t_band", "t_category",
    "t_class", "t_class_group", "t_collection", "t_collection_report", "t_config",
    "t_custom_column", "t_data", "t_date_from", "t_date_to", "t_membership",
    "t_memo_data", "t_message", "t_object", "t_property", "t_property_group",
    "t_property_report", "t_property_tag", "t_report", "t_tag", "t_text", "t_unit",
)

"""
    read_plexos_xml(path::AbstractString; tables = ISP_XML_TABLES)

Read a PLEXOS `MasterDataSet` XML export into one `DataFrame` per `t_*` table.

The export is a flat relational dump: the root element's children are the records, and each
record's children are its scalar fields. Records of the same table may carry different field
sets (an absent optional field is simply not emitted), so each frame's columns are the union
over its records, with `missing` where a field was absent. Every value stays a `String` —
numeric and timestamp casting happens in SQL where the precedence rules live.

The whole 42 MB ISP file parses eagerly in ~1.7 s / ~441 MiB, so no streaming is used.

# Arguments
- `path`: path to the XML file.
- `tables`: table names to keep; others are skipped.

# Returns
- `Dict{String, DataFrame}` keyed by table name. Tables absent from the file are absent here.
"""
function read_plexos_xml(path::AbstractString; tables = ISP_XML_TABLES)
    root = _master_dataset_root(path)
    wanted = Set(tables)
    rows = Dict{String, Vector{Dict{String, Union{String, Missing}}}}()
    for record in XML.children(root)
        XML.nodetype(record) == XML.Element || continue
        table = XML.tag(record)
        table in wanted || continue
        push!(get!(rows, table, Dict{String, Union{String, Missing}}[]), _record_fields(record))
    end
    isempty(rows) && throw(
        ArgumentError("no $(join(tables, ", ")) records found in $(path); is this a PLEXOS MasterDataSet export?"),
    )
    return Dict(table => _rows_to_dataframe(rs) for (table, rs) in rows)
end

"""
    _master_dataset_root(path::AbstractString)

Read `path` and return its `MasterDataSet` root element, rejecting any other root.

# Arguments
- `path`: path to the XML file.

# Returns
- the `MasterDataSet` root XML node.
"""
function _master_dataset_root(path::AbstractString)
    isfile(path) || throw(ArgumentError("PLEXOS XML not found at $(path)"))
    doc = XML.read(path, XML.Node)
    root = only(filter(c -> XML.nodetype(c) == XML.Element, XML.children(doc)))
    tag = _local_xml_tag(XML.tag(root))
    tag == "MasterDataSet" || throw(
        ArgumentError(
            "$(path) is not a PLEXOS MasterDataSet export: root element is $(tag)"
        ),
    )
    return root
end

function _local_xml_tag(tag::AbstractString)::String
    return last(split(tag, '}'))
end

"""
    isp_record_counts(path::AbstractString; tables = ISP_XML_TABLES) -> Dict{String, Int}

Count each table's records in the XML document, independently of
[`read_plexos_xml`](@ref).

# Arguments
- `path`: path to the XML file.
- `tables`: table names to count; others are skipped.

# Returns
- `Dict{String, Int}` keyed by table name. Tables absent from the file are absent here.
"""
function isp_record_counts(path::AbstractString; tables = ISP_XML_TABLES)::Dict{String, Int}
    root = _master_dataset_root(path)
    wanted = Set(tables)
    counts = Dict{String, Int}()
    for record in XML.children(root)
        XML.nodetype(record) == XML.Element || continue
        tag = XML.tag(record)
        tag in wanted && (counts[tag] = get(counts, tag, 0) + 1)
    end
    return counts
end

function _record_fields(record)
    fields = Dict{String, Union{String, Missing}}()
    for field in XML.children(record)
        XML.nodetype(field) == XML.Element || continue
        children = XML.children(field)
        fields[XML.tag(field)] = isempty(children) ? missing : XML.value(children[1])
    end
    return fields
end

function _rows_to_dataframe(rows::Vector{Dict{String, Union{String, Missing}}})
    columns = String[]
    seen = Set{String}()
    for row in rows, key in keys(row)
        if !(key in seen)
            push!(seen, key)
            push!(columns, key)
        end
    end
    sort!(columns)
    return DataFrame([col => [get(row, col, missing) for row in rows] for col in columns])
end

export isp_scenario_schema

"""
    isp_scenario_schema(scenario::Symbol)

Validate `scenario` as a DuckDB schema identifier and return it as a `String`.

Scenario names are interpolated into DDL, so they are restricted to a leading letter followed
by letters, digits and underscores. Anything else throws.
"""
function isp_scenario_schema(scenario::Symbol)
    name = String(scenario)
    occursin(r"^[A-Za-z][A-Za-z0-9_]*$", name) ||
        throw(ArgumentError("invalid scenario name $(repr(name)): expected a leading letter then letters, digits or underscores"))
    return name
end

function _isp_query(db::AEMDB, sql::String, params = ())
    return DataFrame(DuckDB.execute(db.db, sql, params))
end
