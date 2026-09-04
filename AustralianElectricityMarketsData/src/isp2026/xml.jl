export read_plexos_xml, ISP_XML_TABLES

"""
The `t_*` tables read from a PLEXOS `MasterDataSet` export. The full file has 27; these are
the ones needed to resolve objects, memberships, properties and their scoping.
"""
const ISP_XML_TABLES = (
    "t_object", "t_class", "t_collection", "t_membership", "t_property",
    "t_data", "t_band", "t_date_from", "t_date_to", "t_tag", "t_text",
    "t_category", "t_unit",
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
    isfile(path) || throw(ArgumentError("PLEXOS XML not found at $(path)"))
    doc = XML.read(path, XML.Node)
    root = only(filter(c -> XML.nodetype(c) == XML.Element, XML.children(doc)))
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

export load_isp_xml!, isp_scenario_schema

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

"""
    load_isp_xml!(db::AEMDB, path::AbstractString, scenario::Symbol; tables = ISP_XML_TABLES)

Load a PLEXOS XML export into `db` under a schema named for `scenario`.

Each scenario gets its own DuckDB schema because PLEXOS `object_id`s are per-file: the same
integer means different objects in different scenarios. Isolating them by schema means the
resolution queries can be written once against unqualified table names and simply executed
with the schema selected, with no `scenario` predicate that a later join could forget.

Reloading a scenario replaces its tables.

# Arguments
- `db`: an open [`AEMDB`](@ref).
- `path`: path to the scenario's XML file.
- `scenario`: schema name, e.g. `:step_change`.
- `tables`: table names to load.

# Returns
- `Vector{String}` of loaded table names, sorted.
"""
function load_isp_xml!(db::AEMDB, path::AbstractString, scenario::Symbol; tables = ISP_XML_TABLES)
    schema = isp_scenario_schema(scenario)
    frames = read_plexos_xml(path; tables)
    conn = DuckDB.connect(db.db)
    try
        DuckDB.execute(conn, "CREATE SCHEMA IF NOT EXISTS $(schema)")
        for (table, frame) in frames
            DuckDB.register_data_frame(conn, frame, "_isp_stage")
            DuckDB.execute(conn, "CREATE OR REPLACE TABLE $(schema).$(table) AS SELECT * FROM _isp_stage")
            DuckDB.unregister_table(conn, "_isp_stage")
        end
    finally
        DuckDB.disconnect(conn)
    end
    return sort!(collect(keys(frames)))
end
