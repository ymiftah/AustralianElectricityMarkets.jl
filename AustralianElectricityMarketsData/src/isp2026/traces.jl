# ── ISP trace CSV files ──────────────────────────────────────────────────────

const ISP_TRACE_FAMILIES = (
    "demand", "dnsp", "gas", "hydro", "load_subtractor", "rooftop pv", "solar",
    "timeslice", "wind",
)

const _ISP_TRACE_NULL_SENTINEL = "__ISP_CACHE_RESERVED_NULL__"

const _ISP_TRACE_REFERENCE_COLUMNS = (
    "t_text" => ("class_id", "data_id", "value"),
    "t_class" => ("class_id", "name"),
    "t_data" => ("data_id", "property_id", "membership_id"),
    "t_property" => ("property_id", "name"),
    "t_membership" => ("membership_id", "child_object_id"),
    "t_object" => ("object_id", "name"),
)

const _ISP_TRACE_BINDING_COLUMNS = (
    "t_data" => ("data_id", "membership_id", "property_id"),
    "t_membership" => ("membership_id", "parent_object_id", "child_object_id"),
    "t_property" => ("property_id", "name"),
    "t_tag" => ("data_id", "object_id", "action_id"),
)

"""
    _isp_csv_files(root::AbstractString) -> Vector{String}

Every CSV file under `root`, sorted by path.

# Arguments
- `root`: directory to search.

# Returns
- `Vector{String}` of CSV file paths.
"""
function _isp_csv_files(root::AbstractString)::Vector{String}
    files = String[]
    for (dir, _, names) in walkdir(root)
        for name in names
            endswith(name, ".csv") && push!(files, joinpath(dir, name))
        end
    end
    return sort!(files)
end

"""
    _isp_trace_family(path::AbstractString, root::AbstractString) -> String

The first component of `path` relative to `root` that names a trace family, lowercased. An
`ArgumentError` naming `path` is thrown when no component names a family.

# Arguments
- `path`: CSV file path.
- `root`: directory the trace tree is scanned from.

# Returns
- `String` the family name.
"""
function _isp_trace_family(path::AbstractString, root::AbstractString)::String
    for part in split(relpath(path, root), r"[\\/]")
        family = lowercase(part)
        family in ISP_TRACE_FAMILIES && return family
    end
    throw(
        ArgumentError(
            "unrecognised trace family in $(path); expected one of $(join(ISP_TRACE_FAMILIES, ", "))"
        )
    )
end

"""
    _isp_trace_scenario(path, scenarios) -> Union{Missing, String}

The scenario whose XML export sits in a directory containing `path`, or `missing`.

# Arguments
- `path`: CSV file path.
- `scenarios`: scenario schema to XML path pairs, as [`_isp_scenarios`](@ref) returns.

# Returns
- `Union{Missing, String}` the scenario schema name, or `missing` for a shared file.
"""
function _isp_trace_scenario(path::AbstractString, scenarios)::Union{Missing, String}
    for (scenario, xml_path) in scenarios
        _isp_path_within(path, dirname(xml_path)) && return String(scenario)
    end
    return missing
end

"""
    _isp_path_within(path::AbstractString, dir::AbstractString) -> Bool

Whether `path` is `dir` itself or sits under it.

# Arguments
- `path`: candidate path.
- `dir`: directory path.

# Returns
- `Bool` true when `path` is inside `dir`.
"""
function _isp_path_within(path::AbstractString, dir::AbstractString)::Bool
    candidate = normpath(abspath(path))
    root = normpath(abspath(dir))
    return candidate == root || startswith(candidate, joinpath(root, ""))
end

"""
    _isp_sql_string(value::AbstractString) -> String

A single-quoted SQL string literal with embedded quotes doubled.

# Arguments
- `value`: the string to quote.

# Returns
- `String` the SQL literal.
"""
function _isp_sql_string(value::AbstractString)::String
    return "'" * replace(value, "'" => "''") * "'"
end

"""
    _isp_csv_summary(path::AbstractString) -> Tuple{Vector{String}, Int}

Read a CSV file's header fields and count its data records, rejecting any record whose field
count differs from the header and any field equal to the reserved NULL sentinel.

# Arguments
- `path`: CSV file path.

# Returns
- `Tuple{Vector{String}, Int}` of header field names and data record count.
"""
function _isp_csv_summary(path::AbstractString)
    records = _isp_csv_records(read(path))
    isempty(records) && throw(ArgumentError("CSV file $(path) is empty"))
    header = _isp_csv_fields(_isp_strip_bom(records[1]))
    for (index, record) in enumerate(@view records[2:end])
        fields = isempty(record) ? String[] : _isp_csv_fields(record)
        length(fields) == length(header) || throw(
            ArgumentError(
                "CSV width mismatch on row $(index) of $(path): expected $(length(header)) fields, found $(length(fields))"
            ),
        )
        any(==(_ISP_TRACE_NULL_SENTINEL), fields) && throw(
            ArgumentError(
                "$(path) contains the reserved NULL sentinel $(_ISP_TRACE_NULL_SENTINEL) on row $(index)"
            ),
        )
    end
    return header, length(records) - 1
end

"""
    _isp_strip_bom(line::AbstractString) -> String

Remove a leading UTF-8 byte-order mark from `line`.

# Arguments
- `line`: the record text.

# Returns
- `String` the record without a byte-order mark.
"""
function _isp_strip_bom(line::AbstractString)::String
    return startswith(line, Char(0xfeff)) ? chop(line; head = 1, tail = 0) : line
end

"""
    _isp_csv_records(data::Vector{UInt8}) -> Vector{String}

Split a CSV file's bytes into record texts, ignoring newlines inside quoted fields and
dropping the carriage return of a CRLF ending.

# Arguments
- `data`: the file's bytes.

# Returns
- `Vector{String}` of record texts, header first.
"""
function _isp_csv_records(data::Vector{UInt8})::Vector{String}
    records = String[]
    start = 1
    in_quotes = false
    for (index, byte) in enumerate(data)
        if byte == UInt8('"')
            in_quotes = !in_quotes
        elseif byte == UInt8('\n') && !in_quotes
            stop = index - 1
            stop >= start && data[stop] == UInt8('\r') && (stop -= 1)
            push!(records, stop >= start ? String(data[start:stop]) : "")
            start = index + 1
        end
    end
    if start <= length(data)
        stop = length(data)
        data[stop] == UInt8('\r') && (stop -= 1)
        stop >= start && push!(records, String(data[start:stop]))
    end
    return records
end

"""
    _isp_csv_fields(line::AbstractString) -> Vector{String}

Split one CSV record into its fields, honouring quoted fields and doubled quotes.

# Arguments
- `line`: the record text.

# Returns
- `Vector{String}` of field values.
"""
function _isp_csv_fields(line::AbstractString)::Vector{String}
    fields = String[]
    field = IOBuffer()
    in_quotes = false
    i = firstindex(line)
    while i <= lastindex(line)
        c = line[i]
        if in_quotes
            if c == '"'
                next = nextind(line, i)
                if next <= lastindex(line) && line[next] == '"'
                    write(field, '"')
                    i = next
                else
                    in_quotes = false
                end
            else
                write(field, c)
            end
        elseif c == '"'
            in_quotes = true
        elseif c == ','
            push!(fields, String(take!(field)))
        else
            write(field, c)
        end
        i = nextind(line, i)
    end
    push!(fields, String(take!(field)))
    return fields
end

"""
    _isp_scan_trace_files(root, scenarios) -> Vector{Dict{String, Any}}

Scan every CSV file under `root`, recording its family, scenario, hash and shape.

# Arguments
- `root`: directory holding the extracted archives.
- `scenarios`: scenario schema to XML path pairs.

# Returns
- `Vector{Dict{String, Any}}` of one record per CSV file, sorted by path.
"""
function _isp_scan_trace_files(root::AbstractString, scenarios)::Vector{Dict{String, Any}}
    files = Dict{String, Any}[]
    for path in _isp_csv_files(root)
        family = _isp_trace_family(path, root)
        header, count = _isp_csv_summary(path)
        length(unique(lowercase.(header))) == length(header) || throw(
            ArgumentError(
                "duplicate CSV column name in $(path): $(join(header, ", "))"
            ),
        )
        digest = _isp_sha256(path)
        push!(
            files,
            Dict{String, Any}(
                "scenario" => _isp_trace_scenario(path, scenarios),
                "family" => family,
                "filename" => basename(path),
                "source_path" => relpath(path, root),
                "source_sha256" => digest,
                "source_bytes" => filesize(path),
                "row_count" => count,
                "column_count" => length(header),
                "columns" => header,
                "columns_json" => _isp_columns_json(header),
                "lookup_key" => lowercase(family * "/" * basename(path)),
                "table_name" => "f_" * digest,
            ),
        )
    end
    return files
end

"""
    _isp_trace_lookup(files) -> Tuple{Dict, Dict}

Index scanned trace files by scenario and family-relative filename, and by SHA-256.

# Arguments
- `files`: scanned file records, each a `Dict` of its metadata.

# Returns
- `Tuple{Dict, Dict}`: the first maps `(scenario, lowercase(family/filename))` to the
  SHA-256 digests seen, the second maps each digest to its physical table record.
"""
function _isp_trace_lookup(files)
    lookup = Dict{Tuple{Union{Missing, String}, String}, Vector{String}}()
    physical = Dict{String, Dict{String, Any}}()
    for file in files
        key = (file["scenario"], file["lookup_key"])
        push!(get!(lookup, key, String[]), file["source_sha256"])
        get!(physical, file["source_sha256"]) do
            Dict{String, Any}(
                "table_schema" => "traces",
                "table_name" => file["table_name"],
                "source_path" => file["source_path"],
                "row_count" => file["row_count"],
                "column_count" => file["column_count"],
                "columns" => file["columns"],
                "columns_json" => file["columns_json"],
            )
        end
    end
    return lookup, physical
end

"""
    _isp_create_trace_meta_tables!(conn)

Create the empty `cache_meta.trace_files` and `cache_meta.trace_references` tables.

# Arguments
- `conn`: open DuckDB connection.

# Returns
- `nothing`.
"""
function _isp_create_trace_meta_tables!(conn)
    DuckDB.execute(
        conn,
        """
        CREATE TABLE cache_meta.trace_files (
            scenario VARCHAR, family VARCHAR, filename VARCHAR, source_path VARCHAR,
            source_sha256 VARCHAR, source_bytes BIGINT, table_schema VARCHAR,
            table_name VARCHAR, row_count BIGINT, column_count BIGINT,
            columns_json VARCHAR
        )
        """,
    )
    DuckDB.execute(
        conn,
        """
        CREATE TABLE cache_meta.trace_references (
            scenario VARCHAR, data_file_object_id VARCHAR, data_file_object_name VARCHAR,
            filename_data_id VARCHAR, relative_path VARCHAR, table_schema VARCHAR,
            table_name VARCHAR, source_sha256 VARCHAR, source_path VARCHAR
        )
        """,
    )
    return nothing
end

"""
    _isp_normalise_trace_path(value::AbstractString) -> String

Normalise a Data File filename: backslashes become slashes and one leading `./` is removed.

# Arguments
- `value`: the filename as stored in the XML.

# Returns
- `String` the normalised relative path.
"""
function _isp_normalise_trace_path(value::AbstractString)::String
    relative = replace(value, '\\' => '/')
    startswith(relative, "./") && (relative = relative[3:end])
    return relative
end

"""
    _assert_isp_trace_columns(conn, schema::AbstractString, required)

Fail when a scenario schema lacks a column the trace queries need.

# Arguments
- `conn`: open DuckDB connection.
- `schema`: scenario schema name.
- `required`: table name to required column names.

# Returns
- `nothing`.
"""
function _assert_isp_trace_columns(conn, schema::AbstractString, required)
    for (table, columns) in required
        stored = Set(_isp_table_columns(conn, schema, table))
        absent = [column for column in columns if !(column in stored)]
        isempty(absent) || throw(
            ArgumentError(
                "$(schema).$(table) lacks $(join(absent, ", ")); the scenario XML cannot resolve trace references"
            ),
        )
    end
    return nothing
end

"""
    _isp_resolve_trace_references(conn, scenarios, lookup, physical) -> DataFrame

Resolve every Data File filename in each scenario to a physical trace table. An `ArgumentError`
lists every reference that did not resolve or resolved ambiguously, and every Data File text
whose class, data, property, membership or owner object is absent.

# Arguments
- `conn`: open DuckDB connection.
- `scenarios`: scenario schema to XML path pairs.
- `lookup`: file lookup returned by [`_isp_trace_lookup`](@ref).
- `physical`: physical table lookup returned by [`_isp_trace_lookup`](@ref).

# Returns
- `DataFrame` with one row per resolved reference, in `cache_meta.trace_references` order.
"""
function _isp_resolve_trace_references(conn, scenarios, lookup, physical)
    references = DataFrame(
        scenario = String[],
        data_file_object_id = String[],
        data_file_object_name = String[],
        filename_data_id = String[],
        relative_path = String[],
        table_schema = String[],
        table_name = String[],
        source_sha256 = String[],
        source_path = String[],
    )
    problems = String[]
    for (scenario, _) in scenarios
        schema = isp_scenario_schema(Symbol(scenario))
        _assert_isp_trace_columns(conn, schema, _ISP_TRACE_REFERENCE_COLUMNS)
        texts = DataFrame(
            DuckDB.execute(
                conn,
                """
                SELECT txt.data_id AS filename_data_id,
                       txt.class_id AS text_class_id,
                       cls."name" AS class_name,
                       dat.data_id AS data_id,
                       prop.property_id AS property_id,
                       prop."name" AS property_name,
                       mem.membership_id AS membership_id,
                       obj.object_id AS data_file_object_id,
                       obj."name" AS data_file_object_name,
                       txt."value" AS value
                FROM $(schema).t_text txt
                LEFT JOIN $(schema).t_class cls ON cls.class_id = txt.class_id
                LEFT JOIN $(schema).t_data dat ON dat.data_id = txt.data_id
                LEFT JOIN $(schema).t_property prop ON prop.property_id = dat.property_id
                LEFT JOIN $(schema).t_membership mem ON mem.membership_id = dat.membership_id
                LEFT JOIN $(schema).t_object obj ON obj.object_id = mem.child_object_id
                """,
            ),
        )
        for row in eachrow(texts)
            ismissing(row.text_class_id) && continue
            if ismissing(row.class_name)
                push!(
                    problems,
                    "$(scenario): Data File text $(row.filename_data_id) has no class",
                )
                continue
            end
            row.class_name == "Data File" || continue
            if ismissing(row.data_id)
                push!(
                    problems,
                    "$(scenario): Data File text $(row.filename_data_id) has no data",
                )
                continue
            end
            if ismissing(row.property_id)
                push!(
                    problems,
                    "$(scenario): Data File text $(row.filename_data_id) has no property",
                )
                continue
            end
            if ismissing(row.membership_id)
                push!(
                    problems,
                    "$(scenario): Data File text $(row.filename_data_id) has no membership",
                )
                continue
            end
            if ismissing(row.data_file_object_id)
                push!(
                    problems,
                    "$(scenario): Data File text $(row.filename_data_id) has no owner object",
                )
                continue
            end
            if row.property_name != "Filename"
                push!(
                    problems,
                    "$(scenario): Data File text $(row.filename_data_id) has property " *
                        "$(row.property_name), expected Filename",
                )
                continue
            end
            if ismissing(row.value)
                push!(
                    problems,
                    "$(scenario): Data File text $(row.filename_data_id) has no filename",
                )
                continue
            end
            relative = _isp_normalise_trace_path(row.value)
            parts = split(relative, '/')
            if length(parts) != 3 || lowercase(parts[1]) != "traces"
                push!(problems, "$(scenario): unexpected trace path $(relative)")
                continue
            end
            key = lowercase(parts[2] * "/" * parts[3])
            candidates = get(lookup, (scenario, key), nothing)
            isnothing(candidates) && (candidates = get(lookup, (missing, key), nothing))
            if isnothing(candidates)
                push!(problems, "$(scenario): unresolved trace reference $(relative)")
                continue
            end
            digests = unique(candidates)
            if length(digests) != 1
                push!(
                    problems,
                    "$(scenario): ambiguous trace reference $(relative) resolves to " *
                        "$(length(digests)) tables",
                )
                continue
            end
            digest = only(digests)
            found = physical[digest]
            push!(
                references,
                (
                    String(scenario), String(row.data_file_object_id),
                    String(row.data_file_object_name), String(row.filename_data_id),
                    relative, found["table_schema"], found["table_name"], digest,
                    found["source_path"],
                ),
            )
        end
    end
    isempty(problems) ||
        throw(ArgumentError("trace references did not resolve:\n" * join(problems, "\n")))
    return references
end

"""
    _isp_create_trace_bindings_view!(conn, scenario::AbstractString)

Create a scenario's `trace_bindings` view, joining property records to their trace table.

# Arguments
- `conn`: open DuckDB connection.
- `scenario`: scenario schema name.

# Returns
- `nothing`.
"""
function _isp_create_trace_bindings_view!(conn, scenario::AbstractString)
    schema = isp_scenario_schema(Symbol(scenario))
    literal = _isp_sql_string(scenario)
    _assert_isp_trace_columns(conn, schema, _ISP_TRACE_BINDING_COLUMNS)
    DuckDB.execute(
        conn,
        """
        CREATE VIEW $(schema).trace_bindings AS
        SELECT d.data_id, d.membership_id, d.property_id, p."name" AS property_name,
               m.parent_object_id, m.child_object_id, tag.object_id AS data_file_object_id,
               tag.action_id, "ref".relative_path, "ref".table_schema, "ref".table_name
        FROM $(schema).t_data d
        JOIN $(schema).t_membership m USING (membership_id)
        JOIN $(schema).t_property p USING (property_id)
        JOIN $(schema).t_tag tag USING (data_id)
        JOIN cache_meta.trace_references "ref"
            ON "ref".scenario = $(literal) AND "ref".data_file_object_id = tag.object_id
        """,
    )
    return nothing
end

"""
    _write_isp_traces!(conn, root, scenarios)

Load every trace CSV under `root`, record its provenance, resolve each scenario's Data File
references and create the per-scenario `trace_bindings` views.

# Arguments
- `conn`: open DuckDB connection.
- `root`: directory holding the extracted archives.
- `scenarios`: scenario schema to XML path pairs.

# Returns
- `nothing`.
"""
function _write_isp_traces!(conn, root::AbstractString, scenarios)
    files = _isp_scan_trace_files(root, scenarios)
    _isp_create_trace_meta_tables!(conn)
    DuckDB.execute(conn, "CREATE SCHEMA traces")
    lookup, physical = _isp_trace_lookup(files)

    if !isempty(files)
        for digest in sort!(collect(keys(physical)))
            entry = physical[digest]
            path = joinpath(root, entry["source_path"])
            table = entry["table_name"]
            DuckDB.execute(
                conn,
                "CREATE TABLE traces.$(table) AS SELECT * FROM read_csv(" *
                    "$(_isp_sql_string(path)), header = true, all_varchar = true, " *
                    "sample_size = -1, strict_mode = true, " *
                    "nullstr = $(_isp_sql_string(_ISP_TRACE_NULL_SENTINEL)))",
            )
            stored = _isp_table_count(conn, "traces", table)
            stored == entry["row_count"] || throw(
                ArgumentError(
                    "traces.$(table): stored $(stored) records, the CSV holds $(entry["row_count"])"
                ),
            )
            columns = _isp_table_columns(conn, "traces", table)
            columns == entry["columns"] || throw(
                ArgumentError(
                    "traces.$(table): stored columns $(columns) differ from the CSV header " *
                        "$(entry["columns"])"
                ),
            )
        end

        trace_files = DataFrame(
            scenario = Union{Missing, String}[file["scenario"] for file in files],
            family = String[file["family"] for file in files],
            filename = String[file["filename"] for file in files],
            source_path = String[file["source_path"] for file in files],
            source_sha256 = String[file["source_sha256"] for file in files],
            source_bytes = Int64[file["source_bytes"] for file in files],
            table_schema = fill("traces", length(files)),
            table_name = String[file["table_name"] for file in files],
            row_count = Int64[file["row_count"] for file in files],
            column_count = Int64[file["column_count"] for file in files],
            columns_json = String[file["columns_json"] for file in files],
        )
        _insert_frame(conn, trace_files, "cache_meta", "trace_files")
    end

    references = _isp_resolve_trace_references(conn, scenarios, lookup, physical)
    isempty(references) ||
        _insert_frame(conn, references, "cache_meta", "trace_references")

    for (scenario, _) in scenarios
        _isp_create_trace_bindings_view!(conn, String(scenario))
    end

    checks = DataFrame(
        table_schema = String[],
        table_name = String[],
        actual_count = Int64[],
        expected_count = Int64[],
    )
    for digest in sort!(collect(keys(physical)))
        entry = physical[digest]
        actual = _isp_table_count(conn, "traces", entry["table_name"])
        push!(checks, ("traces", entry["table_name"], actual, entry["row_count"]))
    end
    isempty(checks) ||
        _insert_frame(conn, checks, "cache_meta", "row_count_checks")
    return nothing
end
