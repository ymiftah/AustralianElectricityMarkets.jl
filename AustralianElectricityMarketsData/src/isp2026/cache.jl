# ── ISP cache database ───────────────────────────────────────────────────────

const _ISP_CACHE_LAYOUT = 2
const _ISP_RESERVED_SCHEMAS = ("cache_meta", "traces", "main", "information_schema", "pg_catalog")
const _ISP_STALE_BUILD_SECONDS = 3600

"""
    isp_cache(config::HiveConfiguration; read_only = true) -> AEMDB

Open the ISP cache database, which [`build_isp_cache`](@ref) creates.

# Arguments
- `config`: cache configuration.
- `read_only`: open without write access; true by default, since only
  [`populate_isp`](@ref) writes the database.

# Returns
- `AEMDB` wrapping the open database.
"""
function isp_cache(config::HiveConfiguration; read_only::Bool = true)::AEMDB
    path = isp_cache_path(config)
    isfile(path) || throw(
        ArgumentError("ISP cache not found at $path; run populate_isp first.")
    )
    db = DuckDB.DB(path; readonly = read_only)
    return AEMDB(; db, config)
end

"""
    populate_isp(config::HiveConfiguration, source_dir::AbstractString;
        release = ISP_RELEASE_2026, force_new = false, download! = _download_isp_archive) -> String

Obtain the release archives from `source_dir`, extract every archive and build the ISP cache
database from the extracted model and trace files.

# Arguments
- `config`: cache configuration; the cache must be on the local filesystem.
- `source_dir`: directory holding, or receiving, the release archives.
- `release`: release record, [`ISP_RELEASE_2026`](@ref) by default.
- `force_new`: rebuild even when the database already exists.
- `download!`: function used to fetch a missing archive.

# Returns
- `String` path of the built database.
"""
function populate_isp(
        config::HiveConfiguration,
        source_dir::AbstractString;
        release::ISPRelease = ISP_RELEASE_2026,
        force_new::Bool = false,
        download! = _download_isp_archive,
    )::String
    target = isp_cache_path(config)
    isfile(target) && !force_new && return _checked_isp_cache(target)
    archives = acquire_isp_archives(config, source_dir; release, download!)
    dir = mktempdir(dirname(target); prefix = "isp-model-")
    try
        for (kind, archive) in sort!(collect(archives))
            _extract_zip(archive, joinpath(dir, string(kind)))
        end
        return build_isp_cache(config, dir; force_new)
    finally
        rm(dir; recursive = true, force = true)
    end
end

"""
    _extract_zip(zip_path::AbstractString, dir::AbstractString)

Extract every file of `zip_path` under `dir`, keeping the archive's relative paths.

# Arguments
- `zip_path`: path to the ZIP archive.
- `dir`: directory to extract into.

# Returns
- `String` the extraction directory.
"""
function _extract_zip(zip_path::AbstractString, dir::AbstractString)
    reader = ZipReader(read(zip_path))
    for name in zip_names(reader)
        endswith(name, "/") && continue
        path = _isp_archive_entry_path(dir, name)
        mkpath(dirname(path))
        open(path, "w") do io
            write(io, read(zip_openentry(reader, name)))
        end
    end
    return dir
end

"""
    _isp_archive_entry_path(dir::AbstractString, name::AbstractString) -> String

Absolute path of one archive entry, rejecting any entry that would land outside `dir`.

# Arguments
- `dir`: extraction directory.
- `name`: entry name as stored in the archive.

# Returns
- `String` path under `dir`.
"""
function _isp_archive_entry_path(dir::AbstractString, name::AbstractString)::String
    root = normpath(dir)
    path = normpath(joinpath(root, name))
    (path == root || startswith(path, joinpath(root, ""))) || throw(
        ArgumentError("archive entry $(repr(name)) escapes the extraction directory")
    )
    return path
end

"""
    build_isp_cache(config::HiveConfiguration, source_root::AbstractString;
        force_new = false) -> String

Build the ISP cache database from a directory holding the extracted release archives.

Each scenario is a folder holding one PLEXOS XML export. It becomes a schema named after that
folder, with the leading year-and-`ISP` prefix removed and the rest snake-cased. Trace CSV
files found anywhere under `source_root` are loaded into `traces` tables keyed by SHA-256, and
each scenario gains a `trace_bindings` view, even when no CSV is present.
The database is written beside the target and renamed over it only after every table's record
count and column set are confirmed, so a failed build leaves the previous database in place.

# Arguments
- `config`: cache configuration.
- `source_root`: directory holding the extracted archives.
- `force_new`: rebuild even when the database already exists.

# Returns
- `String` path of the built database.
"""
function build_isp_cache(
        config::HiveConfiguration,
        source_root::AbstractString,
        ;
        force_new::Bool = false,
    )::String
    target = isp_cache_path(config)
    mkpath(dirname(target))
    _remove_stale_isp_builds(target)
    isfile(target) && !force_new && return _checked_isp_cache(target)
    isdir(source_root) ||
        throw(ArgumentError("source directory not found at $(source_root)"))

    building = target * ".building-" * string(time_ns())
    try
        _write_isp_cache(building, source_root)
        # rename(2) replaces the target in one step; mv may unlink it first.
        Base.Filesystem.rename(building, target)
    catch
        _remove_quietly(building)
        rethrow()
    end
    return target
end

"""
    _checked_isp_cache(target::AbstractString) -> String

Return `target` after confirming it is a database of the current layout.

# Arguments
- `target`: path of an existing database.

# Returns
- `String` the same path.
"""
function _checked_isp_cache(target::AbstractString)::String
    db = nothing
    try
        db = DuckDB.DB(target; readonly = true)
        layout = DataFrame(DuckDB.execute(db, "SELECT layout_version FROM cache_meta.cache"))
        nrow(layout) == 1 || throw(
            ArgumentError(
                "ISP cache at $(target) has $(nrow(layout)) layout rows; rebuild with force_new = true"
            ),
        )
        only(layout.layout_version) == _ISP_CACHE_LAYOUT || throw(
            ArgumentError(
                "ISP cache at $(target) has layout $(only(layout.layout_version)); rebuild with force_new = true"
            ),
        )
    catch e
        e isa InterruptException && rethrow()
        e isa ArgumentError && rethrow()
        throw(
            ArgumentError(
                "ISP cache at $(target) is not a readable build_isp_cache database; rebuild with force_new = true"
            ),
        )
    finally
        db === nothing || DBInterface.close!(db)
    end
    return target
end

"""
    _remove_stale_isp_builds(target::AbstractString)

Delete build leftovers and leaked extraction directories older than an hour, so a concurrent
build in progress is never removed.

# Arguments
- `target`: path of the cache database.

# Returns
- `nothing`.
"""
function _remove_stale_isp_builds(target::AbstractString)
    dir = dirname(target)
    isdir(dir) || return nothing
    prefixes = (basename(target) * ".building-", "isp-model-")
    for name in readdir(dir)
        any(startswith(name, prefix) for prefix in prefixes) || continue
        path = joinpath(dir, name)
        ispath(path) || continue
        time() - mtime(path) < _ISP_STALE_BUILD_SECONDS && continue
        _remove_quietly(path)
    end
    return nothing
end

"""
    _remove_quietly(path::AbstractString)

Remove a file or directory, ignoring failures.

# Arguments
- `path`: path to remove.

# Returns
- `nothing`.
"""
function _remove_quietly(path::AbstractString)
    try
        rm(path; force = true, recursive = true)
    catch
        # Leftovers from an earlier crash must not block a new build.
    end
    return nothing
end

"""
    _write_isp_cache(path::AbstractString, source_root::AbstractString)

Write the whole database at `path` and validate it.

# Arguments
- `path`: file to create.
- `source_root`: directory holding the extracted archives.

# Returns
- `nothing`.
"""
function _write_isp_cache(path::AbstractString, source_root::AbstractString)
    db = DuckDB.DB(path)
    try
        conn = DuckDB.connect(db)
        try
            DuckDB.execute(conn, "SET external_threads = 1")
            DuckDB.execute(conn, "SET threads = 2")
            DuckDB.execute(conn, "SET memory_limit = '2GB'")
            DuckDB.execute(conn, "CREATE SCHEMA cache_meta")
            DuckDB.execute(
                conn,
                """
                CREATE TABLE cache_meta.cache (
                    layout_version BIGINT, built_at TIMESTAMP, model_dir VARCHAR
                )
                """,
            )
            DuckDB.execute(
                conn,
                "INSERT INTO cache_meta.cache VALUES (?, now(), ?)",
                [_ISP_CACHE_LAYOUT, source_root],
            )
            DuckDB.execute(
                conn,
                """
                CREATE TABLE cache_meta.xml_tables (
                    scenario VARCHAR, table_name VARCHAR, row_count BIGINT,
                    column_count BIGINT, columns_json VARCHAR, source_path VARCHAR,
                    xml_sha256 VARCHAR
                )
                """,
            )
            DuckDB.execute(
                conn,
                """
                CREATE TABLE cache_meta.row_count_checks (
                    table_schema VARCHAR, table_name VARCHAR,
                    actual_count BIGINT, expected_count BIGINT
                )
                """,
            )
            model_root = isdir(joinpath(source_root, "model")) ?
                joinpath(source_root, "model") : source_root
            scenarios = _isp_scenarios(model_root)
            for (scenario, xml_path) in scenarios
                _write_isp_scenario!(conn, source_root, scenario, xml_path)
            end
            _write_isp_traces!(conn, source_root, scenarios)
        finally
            DuckDB.disconnect(conn)
        end
    finally
        DBInterface.close!(db)
    end
    return nothing
end

"""
    _isp_scenarios(source_root::AbstractString) -> Vector{Pair{String, String}}

Map each scenario schema name to its XML export.

# Arguments
- `source_root`: directory holding the extracted archives.

# Returns
- `Vector{Pair{String, String}}` of schema name to XML path, sorted by schema name.
"""
function _isp_scenarios(source_root::AbstractString)::Vector{Pair{String, String}}
    root_dir = normpath(source_root)
    found = Dict{String, String}()
    for (root, _, files) in walkdir(source_root)
        for file in files
            endswith(lowercase(file), ".xml") || continue
            path = joinpath(root, file)
            normpath(root) == root_dir && throw(
                ArgumentError(
                    "scenario XML $(path) sits directly in $(source_root); expected one folder per scenario"
                ),
            )
            scenario = _isp_scenario_name(basename(root))
            if haskey(found, scenario)
                throw(
                    ArgumentError(
                        "two scenario XMLs map to schema $(scenario): " *
                            "$(found[scenario]) and $path"
                    )
                )
            end
            found[scenario] = path
        end
    end
    isempty(found) &&
        throw(ArgumentError("no scenario XML found under $(source_root)"))
    return sort!(collect(found))
end

"""
    _isp_scenario_name(folder::AbstractString) -> String

Derive the scenario schema name from its folder, e.g. `"2026 ISP Step Change"` gives
`"step_change"`.

# Arguments
- `folder`: scenario folder name.

# Returns
- `String` the validated schema name.
"""
function _isp_scenario_name(folder::AbstractString)::String
    name = replace(folder, r"^\d{4}\s+ISP\s+" => "")
    schema = strip(replace(lowercase(name), r"[^a-z0-9]+" => "_"), '_')
    isempty(schema) &&
        throw(ArgumentError("cannot derive a scenario name from $(repr(folder))"))
    schema in _ISP_RESERVED_SCHEMAS && throw(
        ArgumentError(
            "scenario folder $(repr(folder)) maps to the reserved schema $(schema)"
        ),
    )
    return isp_scenario_schema(Symbol(schema))
end

"""
    _write_isp_scenario!(conn, source_root, scenario, xml_path)

Load one scenario's tables and record their provenance and row counts.

# Arguments
- `conn`: open DuckDB connection.
- `source_root`: directory holding the extracted archives.
- `scenario`: schema name.
- `xml_path`: the scenario's XML export.

# Returns
- `nothing`.
"""
function _write_isp_scenario!(
        conn,
        source_root::AbstractString,
        scenario::AbstractString,
        xml_path::AbstractString,
    )
    schema = isp_scenario_schema(Symbol(scenario))
    frames = read_plexos_xml(xml_path)
    counts = isp_record_counts(xml_path)
    absent = setdiff(collect(ISP_XML_TABLES), collect(keys(frames)))
    isempty(absent) || throw(
        ArgumentError(
            "$(xml_path) has no records in $(join(absent, ", ")); every table must be present"
        ),
    )
    digest = _isp_sha256(xml_path)
    source = relpath(xml_path, source_root)
    DuckDB.execute(conn, "CREATE SCHEMA $(schema)")

    inventory = DataFrame(
        scenario = String[], table_name = String[], row_count = Int[],
        column_count = Int[], columns_json = String[], source_path = String[],
        xml_sha256 = String[],
    )
    checks = DataFrame(
        table_schema = String[], table_name = String[],
        actual_count = Int[], expected_count = Int[],
    )
    for (table, frame) in sort!(collect(frames); by = first)
        table in ISP_XML_TABLES ||
            throw(ArgumentError("unexpected table $(table) in $(xml_path)"))
        expected = counts[table]
        nrow(frame) == expected || throw(
            ArgumentError(
                "$(schema).$(table): parsed $(nrow(frame)) records, the XML holds $(expected)"
            ),
        )
        DuckDB.register_data_frame(conn, frame, "_isp_stage")
        DuckDB.execute(
            conn, "CREATE TABLE $(schema).$(table) AS SELECT * FROM _isp_stage"
        )
        DuckDB.unregister_table(conn, "_isp_stage")
        stored = _isp_table_count(conn, schema, table)
        stored == expected || throw(
            ArgumentError(
                "$(schema).$(table): stored $(stored) records, the XML holds $(expected)"
            ),
        )
        columns = _isp_table_columns(conn, schema, table)
        sort(columns) == sort(String.(names(frame))) || throw(
            ArgumentError(
                "$(schema).$(table): stored columns $(columns) differ from parsed $(names(frame))"
            ),
        )
        push!(
            inventory,
            (
                scenario, table, stored, ncol(frame), _isp_columns_json(names(frame)),
                source, digest,
            ),
        )
        push!(checks, (schema, table, stored, expected))
    end
    _insert_frame(conn, inventory, "cache_meta", "xml_tables")
    _insert_frame(conn, checks, "cache_meta", "row_count_checks")
    return nothing
end

"""
    _isp_table_count(conn, schema::AbstractString, table::AbstractString) -> Int

Number of records actually stored in one scenario table.

# Arguments
- `conn`: open DuckDB connection.
- `schema`: scenario schema name.
- `table`: table name.

# Returns
- `Int` the stored record count.
"""
function _isp_table_count(conn, schema::AbstractString, table::AbstractString)::Int
    counted = DataFrame(DuckDB.execute(conn, "SELECT count(*) AS n FROM $(schema).$(table)"))
    return Int(counted.n[1])
end

"""
    _isp_table_columns(conn, schema::AbstractString, table::AbstractString) -> Vector{String}

Column names stored in one scenario table, in ordinal order.

# Arguments
- `conn`: open DuckDB connection.
- `schema`: scenario schema name.
- `table`: table name.

# Returns
- `Vector{String}` of column names.
"""
function _isp_table_columns(conn, schema::AbstractString, table::AbstractString)::Vector{String}
    columns = DataFrame(
        DuckDB.execute(
            conn,
            """
            SELECT column_name FROM information_schema.columns
            WHERE table_schema = '$(schema)' AND table_name = '$(table)'
            ORDER BY ordinal_position
            """,
        ),
    )
    return String.(columns.column_name)
end

"""
    _isp_columns_json(columns) -> String

JSON array of a table's column names.

# Arguments
- `columns`: column names.

# Returns
- `String` the JSON array.
"""
function _isp_columns_json(columns)::String
    return "[" * join([_isp_json_string(c) for c in columns], ",") * "]"
end

"""
    _isp_json_string(value::AbstractString) -> String

JSON string literal for `value`.

# Arguments
- `value`: the string to encode.

# Returns
- `String` the quoted and escaped JSON literal.
"""
function _isp_json_string(value::AbstractString)::String
    escaped = replace(value, "\\" => "\\\\", "\"" => "\\\"")
    return "\"" * escaped * "\""
end

"""
    _insert_frame(conn, frame::DataFrame, schema::AbstractString, table::AbstractString)

Append `frame`'s rows to an existing table.

# Arguments
- `conn`: open DuckDB connection.
- `frame`: rows to append.
- `schema`: destination schema.
- `table`: destination table.

# Returns
- `nothing`.
"""
function _insert_frame(conn, frame::DataFrame, schema::AbstractString, table::AbstractString)
    DuckDB.register_data_frame(conn, frame, "_isp_meta_stage")
    DuckDB.execute(conn, "INSERT INTO $(schema).$(table) SELECT * FROM _isp_meta_stage")
    DuckDB.unregister_table(conn, "_isp_meta_stage")
    return nothing
end
