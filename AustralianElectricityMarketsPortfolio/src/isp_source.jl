"""
    ISPSourceTag

A PLEXOS tag attached to a data row, naming the object the row is tagged to.

# Fields

- `object_id::String`: PLEXOS object id of the tagged object.
- `object_name::String`: name of the tagged object.
- `class_name::String`: class of the tagged object, for example `"Timeslice"`, `"Data File"` or `"Variable"`.
- `action_id::Union{String,Missing}`: stored action id, missing when the tag has none.
"""
struct ISPSourceTag
    object_id::String
    object_name::String
    class_name::String
    action_id::Union{String, Missing}
end

"""
    ISPSourceRecord

One PLEXOS data row with its membership, class, collection, property, date, band and tag scoping.

# Fields

- `scenario::Symbol`: ISP scenario the row belongs to.
- `data_id::String`: PLEXOS data id.
- `membership_id::String`: membership the row is attached to.
- `collection_id::String`: collection of that membership.
- `collection_name::String`: name of that collection.
- `class_id::String`: class of the child object.
- `class_name::String`: name of the child object's class.
- `object_id::String`: child object id.
- `object_name::String`: child object name.
- `category::String`: category of the child object, `"-"` when it has none.
- `property_id::String`: property id.
- `property_name::String`: property name.
- `value::Union{Float64,Missing}`: the stored value cast to `Float64`, missing when not numeric or absent.
- `raw_value::Union{String,Missing}`: the stored value as text.
- `text_value::Union{String,Missing}`: the text attached to the same data row.
- `date_from::Union{DateTime,Missing}`: start of the validity period.
- `date_to::Union{DateTime,Missing}`: end of the validity period.
- `band::Int`: band of the row, `1` when the row has no band entry.
- `tags::Vector{ISPSourceTag}`: tags attached to the row, empty when there are none.
"""
struct ISPSourceRecord
    scenario::Symbol
    data_id::String
    membership_id::String
    collection_id::String
    collection_name::String
    class_id::String
    class_name::String
    object_id::String
    object_name::String
    category::String
    property_id::String
    property_name::String
    value::Union{Float64, Missing}
    raw_value::Union{String, Missing}
    text_value::Union{String, Missing}
    date_from::Union{DateTime, Missing}
    date_to::Union{DateTime, Missing}
    band::Int
    tags::Vector{ISPSourceTag}
end

"""
    ISPTimeSlice

A PLEXOS timeslice object and the stored values of its `Include` property.

# Fields

- `object_id::String`: PLEXOS object id of the timeslice.
- `name::String`: name of the timeslice.
- `is_active::Bool`: true when any `Include` value is `"-1"`.
- `include_values::Vector{String}`: stored `Include` values, missing values omitted.
- `include_texts::Vector{String}`: stored `Include` text expressions, missing texts omitted.
"""
struct ISPTimeSlice
    object_id::String
    name::String
    is_active::Bool
    include_values::Vector{String}
    include_texts::Vector{String}
end

"""
    ISPTraceHandle

A reference to one trace table in the cache's `traces` schema, loaded on demand by [`read_isp_trace`](@ref).

# Fields

- `scenario::Symbol`: ISP scenario that references the trace.
- `data_file_object_id::String`: PLEXOS object id of the Data File.
- `data_file_object_name::String`: name of the Data File.
- `relative_path::String`: path of the CSV relative to the ISP archive.
- `table_schema::String`: schema holding the trace table.
- `table_name::String`: name of the trace table.
- `source_sha256::String`: SHA-256 of the source CSV.
- `source_path::String`: path of the source CSV when the cache was built.
"""
struct ISPTraceHandle
    scenario::Symbol
    data_file_object_id::String
    data_file_object_name::String
    relative_path::String
    table_schema::String
    table_name::String
    source_sha256::String
    source_path::String
end

"""
    ISPSourceData

The PLEXOS master data and data rows of one ISP scenario, read from the cache without loading any trace arrays.

# Fields

- `scenario::Symbol`: ISP scenario.
- `path::String`: path of the cache database.
- `objects::DataFrame`: `object_id`, `name`, `class_name`, `category`.
- `collections::DataFrame`: `collection_id`, `name`, `parent_class_name`, `child_class_name`.
- `properties::DataFrame`: `property_id`, `name`, `collection_id`, `default_value`, `is_multi_band`, `max_band_id`.
- `memberships::DataFrame`: `membership_id`, `parent_object_id`, `collection_id`, `child_object_id`, `class_name`.
- `records::Vector{ISPSourceRecord}`: one entry per PLEXOS data row.
- `timeslices::Vector{ISPTimeSlice}`: one entry per object of class `Timeslice`.
- `trace_handles::Vector{ISPTraceHandle}`: one handle per Data File reference of the scenario.
- `trace_by_data_id::Dict{String,ISPTraceHandle}`: trace handle of each data id that resolves to a trace.
"""
struct ISPSourceData
    scenario::Symbol
    path::String
    objects::DataFrame
    collections::DataFrame
    properties::DataFrame
    memberships::DataFrame
    records::Vector{ISPSourceRecord}
    timeslices::Vector{ISPTimeSlice}
    trace_handles::Vector{ISPTraceHandle}
    trace_by_data_id::Dict{String, ISPTraceHandle}
end

const _ISP_RESERVED_SCHEMAS = ("main", "information_schema", "pg_catalog", "cache_meta", "traces")
const _ISP_SQL_IDENTIFIER = r"^[A-Za-z_][A-Za-z0-9_]*$"

"""
    _with_readonly(f, path::AbstractString)

Call `f(db)` on a read-only DuckDB connection to `path` and close the connection afterwards.

# Arguments

- `f`: function taking the open `DuckDB.DB`.
- `path::AbstractString`: database file, which must exist.

# Returns

- The value returned by `f`.
"""
function _with_readonly(f, path::AbstractString)
    db = DuckDB.DB(path; readonly = true)
    try
        return f(db)
    finally
        DuckDB.DBInterface.close!(db)
    end
end

"""
    _require_file(path::AbstractString)

Throw an `ArgumentError` when no file exists at `path`.

# Arguments

- `path::AbstractString`: path that must be a file.

# Returns

- `nothing`.
"""
function _require_file(path::AbstractString)
    isfile(path) || throw(ArgumentError("ISP cache database not found at $(path)"))
    return nothing
end

"""
    _scenario_schemas(db)::Vector{String}

List the scenario schemas of an open ISP cache, sorted, leaving out the reserved schemas.

# Arguments

- `db`: open DuckDB connection.

# Returns

- `Vector{String}`: sorted scenario schema names.
"""
function _scenario_schemas(db)::Vector{String}
    names = DataFrame(DuckDB.execute(db, "SELECT schema_name FROM information_schema.schemata")).schema_name
    scenarios = String[String(n) for n in names if !(n in _ISP_RESERVED_SCHEMAS)]
    return sort!(scenarios)
end

"""
    _tags_by_data_id(df::DataFrame)::Dict{String,Vector{ISPSourceTag}}

Group the rows of the tag query by data id.

# Arguments

- `df::DataFrame`: result of the tag query.

# Returns

- `Dict{String,Vector{ISPSourceTag}}`: tags of each data id that has one.
"""
function _tags_by_data_id(df::DataFrame)::Dict{String, Vector{ISPSourceTag}}
    tags = Dict{String, Vector{ISPSourceTag}}()
    for row in eachrow(df)
        tag = ISPSourceTag(String(row.object_id), String(row.object_name), String(row.class_name), row.action_id)
        push!(get!(() -> ISPSourceTag[], tags, String(row.data_id)), tag)
    end
    return tags
end

"""
    _records(df::DataFrame, scenario::Symbol, tags::Dict)::Vector{ISPSourceRecord}

Build one record per row of the record query, attaching the tags of each data id.

# Arguments

- `df::DataFrame`: result of the record query.
- `scenario::Symbol`: scenario stored on each record.
- `tags::Dict`: tags from [`_tags_by_data_id`](@ref).

# Returns

- `Vector{ISPSourceRecord}`: one record per data row, in query order.
"""
function _records(df::DataFrame, scenario::Symbol, tags::Dict)::Vector{ISPSourceRecord}
    records = ISPSourceRecord[]
    for row in eachrow(df)
        data_id = String(row.data_id)
        push!(
            records,
            ISPSourceRecord(
                scenario,
                data_id,
                String(row.membership_id),
                String(row.collection_id),
                String(row.collection_name),
                String(row.class_id),
                String(row.class_name),
                String(row.object_id),
                String(row.object_name),
                String(row.category),
                String(row.property_id),
                String(row.property_name),
                row.value,
                row.raw_value,
                row.text_value,
                row.date_from,
                row.date_to,
                Int(row.band),
                get(tags, data_id, ISPSourceTag[]),
            ),
        )
    end
    return records
end

"""
    _timeslices(objects::DataFrame, records::Vector{ISPSourceRecord})::Vector{ISPTimeSlice}

Build one timeslice per object of class `Timeslice` from the `Include` records of that object.

# Arguments

- `objects::DataFrame`: objects of the scenario.
- `records::Vector{ISPSourceRecord}`: all records of the scenario.

# Returns

- `Vector{ISPTimeSlice}`: timeslices in object order.
"""
function _timeslices(objects::DataFrame, records::Vector{ISPSourceRecord})::Vector{ISPTimeSlice}
    includes = Dict{String, Vector{ISPSourceRecord}}()
    for record in records
        record.property_name == "Include" || continue
        push!(get!(() -> ISPSourceRecord[], includes, record.object_id), record)
    end
    slices = ISPTimeSlice[]
    for row in eachrow(objects)
        row.class_name == "Timeslice" || continue
        object_id = String(row.object_id)
        include_records = get(includes, object_id, ISPSourceRecord[])
        is_active = any(r -> !ismissing(r.raw_value) && r.raw_value == "-1", include_records)
        values = String[r.raw_value for r in include_records if !ismissing(r.raw_value)]
        texts = String[r.text_value for r in include_records if !ismissing(r.text_value)]
        push!(slices, ISPTimeSlice(object_id, String(row.name), is_active, values, texts))
    end
    return slices
end

"""
    _trace_handles(db, scenario::Symbol)::Tuple{Vector{ISPTraceHandle},Dict{String,ISPTraceHandle}}

Read the Data File trace references of a scenario, returning the handles and the handle of each `Filename` data id.

# Arguments

- `db`: open DuckDB connection.
- `scenario::Symbol`: ISP scenario.

# Returns

- `Vector{ISPTraceHandle}`: one handle per reference.
- `Dict{String,ISPTraceHandle}`: handle of each `filename_data_id`.
"""
function _trace_handles(db, scenario::Symbol)::Tuple{Vector{ISPTraceHandle}, Dict{String, ISPTraceHandle}}
    df = DataFrame(
        DuckDB.execute(
            db,
            """
            SELECT scenario, data_file_object_id, data_file_object_name, filename_data_id, relative_path,
                   table_schema, table_name, source_sha256, source_path
            FROM cache_meta.trace_references WHERE scenario = ?
            """,
            (String(scenario),),
        ),
    )
    handles = ISPTraceHandle[]
    by_filename = Dict{String, ISPTraceHandle}()
    for row in eachrow(df)
        handle = ISPTraceHandle(
            scenario,
            String(row.data_file_object_id),
            String(row.data_file_object_name),
            String(row.relative_path),
            String(row.table_schema),
            String(row.table_name),
            String(row.source_sha256),
            String(row.source_path),
        )
        push!(handles, handle)
        by_filename[String(row.filename_data_id)] = handle
    end
    return handles, by_filename
end

"""
    _trace_by_data_id(records, handles_by_filename, handles_by_object)::Dict{String,ISPTraceHandle}

Map each data id that refers to a trace to its handle.

A `Filename` row maps through the cache's filename reference. A record tagged to a Data File maps to that Data File. A record tagged to a Variable maps to the Data File of the Variable's `Profile` record.

# Arguments

- `records::Vector{ISPSourceRecord}`: all records of the scenario.
- `handles_by_filename::Dict{String,ISPTraceHandle}`: handle of each `Filename` data id.
- `handles_by_object::Dict{String,ISPTraceHandle}`: handle of each Data File object id.

# Returns

- `Dict{String,ISPTraceHandle}`: handle of each resolvable data id.
"""
function _trace_by_data_id(
        records::Vector{ISPSourceRecord},
        handles_by_filename::Dict{String, ISPTraceHandle},
        handles_by_object::Dict{String, ISPTraceHandle},
    )::Dict{String, ISPTraceHandle}
    mapping = copy(handles_by_filename)
    profile_handles = Dict{String, Set{ISPTraceHandle}}()
    for record in records
        for tag in record.tags
            tag.class_name == "Data File" && haskey(handles_by_object, tag.object_id) || continue
            mapping[record.data_id] = handles_by_object[tag.object_id]
            if record.property_name == "Profile"
                push!(get!(() -> Set{ISPTraceHandle}(), profile_handles, record.object_id), handles_by_object[tag.object_id])
            end
        end
    end
    for record in records
        for tag in record.tags
            tag.class_name == "Variable" || continue
            handles = get(profile_handles, tag.object_id, Set{ISPTraceHandle}())
            isempty(handles) && continue
            length(handles) == 1 || throw(
                ArgumentError(
                    "Variable $(tag.object_name) has Profile records tagged to $(length(handles)) Data Files; expected one",
                ),
            )
            mapping[record.data_id] = only(handles)
        end
    end
    return mapping
end

"""
    read_isp_source(path::AbstractString; scenario::Symbol)::ISPSourceData

Read the PLEXOS master data and data rows of one ISP scenario from the cache at `path`.

The database is opened read-only and no trace table is queried. Throws an `ArgumentError` when the file does not exist or the scenario is not in the cache.

# Arguments

- `path::AbstractString`: path of the ISP cache database.

# Keywords

- `scenario::Symbol`: ISP scenario, for example `:step_change`.

# Returns

- `ISPSourceData`: the scenario's objects, collections, properties, memberships, records, timeslices and trace handles.

# Example

```julia
source = read_isp_source(path; scenario = :step_change)
```
"""
function read_isp_source(path::AbstractString; scenario::Symbol)::ISPSourceData
    _require_file(path)
    schema = isp_scenario_schema(scenario)
    return _with_readonly(path) do db
        available = _scenario_schemas(db)
        schema in available || throw(
            ArgumentError(
                "scenario $(scenario) is not in $(path); available scenarios: $(join(available, ", "))",
            ),
        )
        objects = DataFrame(
            DuckDB.execute(
                db,
                """
                SELECT o.object_id, o.name, cl.name AS class_name, COALESCE(cat.name, '-') AS category
                FROM $schema.t_object o
                JOIN $schema.t_class cl ON cl.class_id = o.class_id
                LEFT JOIN $schema.t_category cat ON cat.category_id = o.category_id
                """,
            ),
        )
        collections = DataFrame(
            DuckDB.execute(
                db,
                """
                SELECT col.collection_id, col.name AS collection_name,
                       COALESCE(pc.name, '-') AS parent_class_name, COALESCE(cc.name, '-') AS child_class_name
                FROM $schema.t_collection col
                LEFT JOIN $schema.t_class pc ON pc.class_id = col.parent_class_id
                LEFT JOIN $schema.t_class cc ON cc.class_id = col.child_class_id
                """,
            ),
        )
        properties = DataFrame(
            DuckDB.execute(
                db,
                """
                SELECT p.property_id, p.name, p.collection_id, p.default_value, p.is_multi_band, p.max_band_id
                FROM $schema.t_property p
                """,
            ),
        )
        memberships = DataFrame(
            DuckDB.execute(
                db,
                """
                SELECT m.membership_id, m.parent_object_id, m.collection_id, m.child_object_id,
                       COALESCE(cc.name, '-') AS class_name
                FROM $schema.t_membership m
                LEFT JOIN $schema.t_class cc ON cc.class_id = m.child_class_id
                """,
            ),
        )
        tags = _tags_by_data_id(
            DataFrame(
                DuckDB.execute(
                    db,
                    """
                    SELECT tg.data_id, o.object_id, o.name AS object_name, cl.name AS class_name, tg.action_id
                    FROM $schema.t_tag tg
                    JOIN $schema.t_object o ON o.object_id = tg.object_id
                    JOIN $schema.t_class cl ON cl.class_id = o.class_id
                    """,
                ),
            ),
        )
        records = _records(
            DataFrame(
                DuckDB.execute(
                    db,
                    """
                    SELECT d.data_id, d.membership_id, m.collection_id, col.name AS collection_name,
                           m.child_class_id AS class_id, cl.name AS class_name, m.child_object_id AS object_id,
                           o.name AS object_name, COALESCE(cat.name, '-') AS category,
                           p.property_id, p.name AS property_name,
                           TRY_CAST(d.value AS DOUBLE) AS value, d.value AS raw_value, tx.value AS text_value,
                           CAST(df.date AS TIMESTAMP) AS date_from, CAST(dt.date AS TIMESTAMP) AS date_to,
                           COALESCE(TRY_CAST(b.band_id AS INTEGER), 1) AS band
                    FROM $schema.t_data d
                    JOIN $schema.t_membership m ON m.membership_id = d.membership_id
                    JOIN $schema.t_collection col ON col.collection_id = m.collection_id
                    JOIN $schema.t_property p ON p.property_id = d.property_id
                    JOIN $schema.t_object o ON o.object_id = m.child_object_id
                    JOIN $schema.t_class cl ON cl.class_id = m.child_class_id
                    LEFT JOIN $schema.t_category cat ON cat.category_id = o.category_id
                    LEFT JOIN $schema.t_date_from df ON df.data_id = d.data_id
                    LEFT JOIN $schema.t_date_to dt ON dt.data_id = d.data_id
                    LEFT JOIN $schema.t_band b ON b.data_id = d.data_id
                    LEFT JOIN $schema.t_text tx ON tx.data_id = d.data_id
                    """,
                ),
            ),
            scenario,
            tags,
        )
        handles, handles_by_filename = _trace_handles(db, scenario)
        handles_by_object = Dict{String, ISPTraceHandle}(h.data_file_object_id => h for h in handles)
        return ISPSourceData(
            scenario,
            String(path),
            objects,
            collections,
            properties,
            memberships,
            records,
            _timeslices(objects, records),
            handles,
            _trace_by_data_id(records, handles_by_filename, handles_by_object),
        )
    end
end

"""
    read_isp_source(config::HiveConfiguration; scenario::Symbol)::ISPSourceData

Read one ISP scenario from the cache database at the location given by `config`.

# Arguments

- `config::HiveConfiguration`: cache configuration, see [`isp_cache_path`](@ref).

# Keywords

- `scenario::Symbol`: ISP scenario, for example `:step_change`.

# Returns

- `ISPSourceData`: the scenario's source data, as in the path method.
"""
function read_isp_source(config::HiveConfiguration; scenario::Symbol)::ISPSourceData
    return read_isp_source(isp_cache_path(config); scenario = scenario)
end

"""
    isp_scenarios(path::AbstractString)::Vector{String}

List the scenario schemas of the cache at `path`, opened read-only.

# Arguments

- `path::AbstractString`: path of the ISP cache database.

# Returns

- `Vector{String}`: sorted scenario names, excluding `main`, `information_schema`, `pg_catalog`, `cache_meta` and `traces`.

# Example

```julia
isp_scenarios(path)  # ["slower_growth", "step_change"]
```
"""
function isp_scenarios(path::AbstractString)::Vector{String}
    _require_file(path)
    return _with_readonly(_scenario_schemas, path)
end

"""
    read_isp_trace(path::AbstractString, handle::ISPTraceHandle)::DataFrame

Read every row of the trace table that `handle` points at, opening the cache read-only.

# Arguments

- `path::AbstractString`: path of the ISP cache database.
- `handle::ISPTraceHandle`: trace handle from [`isp_trace_handle`](@ref) or `ISPSourceData.trace_handles`.

# Returns

- `DataFrame`: the trace table, with the columns `Year`, `Month`, `Day` and one column per interval.
"""
function read_isp_trace(path::AbstractString, handle::ISPTraceHandle)::DataFrame
    for (what, name) in (("schema", handle.table_schema), ("table", handle.table_name))
        occursin(_ISP_SQL_IDENTIFIER, name) || throw(
            ArgumentError("invalid trace $what name $(repr(name)): expected a letter or underscore then letters, digits or underscores"),
        )
    end
    _require_file(path)
    sql = "SELECT * FROM \"$(handle.table_schema)\".\"$(handle.table_name)\""
    return _with_readonly(db -> DataFrame(DuckDB.execute(db, sql)), path)
end

"""
    isp_trace_handle(source::ISPSourceData, data_id::AbstractString)::Union{ISPTraceHandle,Nothing}

Return the trace handle of a data row, or `nothing` when the row points at no trace.

# Arguments

- `source::ISPSourceData`: source data read by [`read_isp_source`](@ref).
- `data_id::AbstractString`: PLEXOS data id.

# Returns

- `Union{ISPTraceHandle,Nothing}`: the handle, or `nothing`.
"""
function isp_trace_handle(source::ISPSourceData, data_id::AbstractString)::Union{ISPTraceHandle, Nothing}
    return get(source.trace_by_data_id, String(data_id), nothing)
end
