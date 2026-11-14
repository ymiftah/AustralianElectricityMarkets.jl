"""
    write_isp_source_fixture(path::AbstractString)::String

Write a small ISP cache database at `path` with the `step_change` and `slower_growth` scenarios, a `traces` schema and a `cache_meta` schema.

Any file already at `path` is replaced. The fixture encodes the cases the source layer has to preserve: two scenarios reusing the same object ids, two properties named `Max Capacity` in different collections with different defaults, an object in two memberships of one collection, a data row with no value, two dated records of one object and property whose validity periods overlap, a row in band 2, a tag to a Variable, a tag to a Data File and the indirect Variable to Profile to Data File chain.

# Arguments

- `path::AbstractString`: location of the database to create.

# Returns

- `String`: the path written.

# Example

```julia
write_isp_source_fixture(joinpath(mktempdir(), "isp.duckdb"))
```
"""
function write_isp_source_fixture(path::AbstractString)::String
    isfile(path) && rm(path)
    db = DuckDB.DB(path)
    try
        _create_scenario_tables!(db, "step_change")
        for sql in _STEP_CHANGE_INSERTS
            DuckDB.execute(db, sql)
        end
        _create_scenario_tables!(db, "slower_growth")
        for sql in _SLOWER_GROWTH_INSERTS
            DuckDB.execute(db, sql)
        end
        for sql in (
                "CREATE SCHEMA traces",
                "CREATE TABLE traces.f_fixture (Year VARCHAR, Month VARCHAR, Day VARCHAR, \"01\" VARCHAR)",
                "INSERT INTO traces.f_fixture VALUES ('2026', '7', '1', '1.5'), ('2026', '7', '2', '2.5')",
                "CREATE SCHEMA cache_meta",
                """CREATE TABLE cache_meta.trace_references (scenario VARCHAR, data_file_object_id VARCHAR,
                data_file_object_name VARCHAR, filename_data_id VARCHAR, relative_path VARCHAR,
                table_schema VARCHAR, table_name VARCHAR, source_sha256 VARCHAR, source_path VARCHAR)""",
                """INSERT INTO cache_meta.trace_references VALUES
                ('step_change', '6', 'FILE_A', '6', 'Traces/solar/FIXTURE.csv', 'traces', 'f_fixture',
                 'abc123', '/tmp/FIXTURE.csv')""",
                """CREATE TABLE cache_meta.trace_files (scenario VARCHAR, family VARCHAR, filename VARCHAR,
                source_path VARCHAR, source_sha256 VARCHAR, source_bytes BIGINT, table_schema VARCHAR,
                table_name VARCHAR, row_count BIGINT, column_count BIGINT, columns_json VARCHAR)""",
                """INSERT INTO cache_meta.trace_files VALUES
                ('step_change', 'solar', 'FIXTURE.csv', '/tmp/FIXTURE.csv', 'abc123', 64, 'traces',
                 'f_fixture', 2, 4, '["Year","Month","Day","01"]')""",
            )
            DuckDB.execute(db, sql)
        end
    finally
        DuckDB.DBInterface.close!(db)
    end
    return String(path)
end

"""
    _create_scenario_tables!(db, schema::AbstractString)::Nothing

Create the scenario schema and its `t_*` tables in `db`.

# Arguments

- `db`: open writable DuckDB connection.
- `schema::AbstractString`: scenario schema name.

# Returns

- `nothing`.
"""
function _create_scenario_tables!(db, schema::AbstractString)::Nothing
    statements = (
        "CREATE SCHEMA $schema",
        "CREATE TABLE $schema.t_class (class_id VARCHAR, name VARCHAR)",
        "CREATE TABLE $schema.t_object (object_id VARCHAR, class_id VARCHAR, name VARCHAR, category_id VARCHAR)",
        "CREATE TABLE $schema.t_category (category_id VARCHAR, name VARCHAR)",
        "CREATE TABLE $schema.t_collection (collection_id VARCHAR, name VARCHAR, parent_class_id VARCHAR, child_class_id VARCHAR)",
        "CREATE TABLE $schema.t_property (property_id VARCHAR, name VARCHAR, collection_id VARCHAR, default_value VARCHAR, is_multi_band VARCHAR, max_band_id VARCHAR)",
        "CREATE TABLE $schema.t_membership (membership_id VARCHAR, parent_object_id VARCHAR, collection_id VARCHAR, child_object_id VARCHAR, child_class_id VARCHAR)",
        "CREATE TABLE $schema.t_data (data_id VARCHAR, membership_id VARCHAR, property_id VARCHAR, value VARCHAR)",
        "CREATE TABLE $schema.t_date_from (data_id VARCHAR, date VARCHAR)",
        "CREATE TABLE $schema.t_date_to (data_id VARCHAR, date VARCHAR)",
        "CREATE TABLE $schema.t_band (data_id VARCHAR, band_id VARCHAR)",
        "CREATE TABLE $schema.t_tag (data_id VARCHAR, object_id VARCHAR, action_id VARCHAR)",
        "CREATE TABLE $schema.t_text (data_id VARCHAR, class_id VARCHAR, value VARCHAR)",
    )
    for sql in statements
        DuckDB.execute(db, sql)
    end
    return nothing
end

const _STEP_CHANGE_INSERTS = (
    "INSERT INTO step_change.t_class VALUES ('1', 'Generator'), ('2', 'Timeslice'), ('3', 'System'), ('4', 'Constraint'), ('5', 'Variable'), ('6', 'Data File')",
    "INSERT INTO step_change.t_category VALUES ('1', '-'), ('2', 'Black Coal NSW')",
    """INSERT INTO step_change.t_object VALUES
    ('1', '3', 'NEM', '1'),
    ('2', '1', 'GEN_A', '2'),
    ('3', '1', 'GEN_B', '2'),
    ('4', '4', 'CON_A', '1'),
    ('5', '5', 'VAR_A', '1'),
    ('6', '6', 'FILE_A', '1'),
    ('7', '2', 'Summer', '1')""",
    """INSERT INTO step_change.t_collection VALUES
    ('1', 'Generators', '3', '1'),
    ('2', 'Timeslices', '3', '2'),
    ('3', 'Constraints', '3', '4'),
    ('4', 'Variables', '3', '5'),
    ('5', 'Data Files', '3', '6'),
    ('6', 'Generators Regional', '1', '1')""",
    """INSERT INTO step_change.t_property VALUES
    ('1', 'Max Capacity', '1', '100', 'false', '1'),
    ('2', 'Max Capacity', '6', '200', 'false', '1'),
    ('3', 'Generation Coefficient', '3', '0', 'false', '1'),
    ('4', 'Profile', '4', NULL, 'false', '1'),
    ('5', 'Include', '2', NULL, 'false', '1'),
    ('6', 'Filename', '5', NULL, 'false', '1')""",
    """INSERT INTO step_change.t_membership VALUES
    ('1', '1', '1', '2', '1'),
    ('2', '1', '1', '3', '1'),
    ('3', '1', '1', '3', '1'),
    ('4', '1', '3', '4', '4'),
    ('5', '1', '4', '5', '5'),
    ('6', '1', '5', '6', '6'),
    ('7', '1', '2', '7', '2')""",
    """INSERT INTO step_change.t_data VALUES
    ('1', '1', '1', '10'),
    ('2', '2', '1', '20'),
    ('3', '3', '2', '30'),
    ('4', '4', '3', '1'),
    ('5', '5', '4', NULL),
    ('6', '6', '6', NULL),
    ('7', '7', '5', '-1'),
    ('8', '2', '1', NULL),
    ('9', '1', '1', '15')""",
    """INSERT INTO step_change.t_date_from VALUES ('1', '2024-01-01T00:00:00'), ('2', '2026-01-01T00:00:00'),
    ('9', '2025-01-01T00:00:00')""",
    "INSERT INTO step_change.t_band VALUES ('3', '2')",
    "INSERT INTO step_change.t_tag VALUES ('4', '5', '1'), ('5', '6', NULL)",
    "INSERT INTO step_change.t_text VALUES ('7', '2', 'M1-3,11,12'), ('6', '1', 'Traces/solar/FIXTURE.csv')",
)

const _SLOWER_GROWTH_INSERTS = (
    "INSERT INTO slower_growth.t_class VALUES ('1', 'Generator'), ('2', 'Timeslice'), ('3', 'System'), ('4', 'Constraint'), ('5', 'Variable'), ('6', 'Data File')",
    "INSERT INTO slower_growth.t_category VALUES ('1', '-'), ('2', 'Black Coal QLD')",
    """INSERT INTO slower_growth.t_object VALUES
    ('1', '3', 'NEM', '1'),
    ('2', '1', 'GEN_A_OLD', '2'),
    ('3', '1', 'GEN_B_OLD', '2'),
    ('4', '4', 'CON_B', '1'),
    ('5', '5', 'VAR_B', '1'),
    ('6', '6', 'FILE_B', '1'),
    ('7', '2', 'Winter', '1')""",
    """INSERT INTO slower_growth.t_collection VALUES
    ('1', 'Generators', '3', '1'),
    ('2', 'Timeslices', '3', '2'),
    ('3', 'Constraints', '3', '4'),
    ('4', 'Variables', '3', '5'),
    ('5', 'Data Files', '3', '6'),
    ('6', 'Generators Regional', '1', '1')""",
    """INSERT INTO slower_growth.t_property VALUES
    ('1', 'Max Capacity', '1', '150', 'false', '1'),
    ('2', 'Max Capacity', '6', '250', 'false', '1'),
    ('3', 'Generation Coefficient', '3', '0', 'false', '1'),
    ('4', 'Profile', '4', NULL, 'false', '1'),
    ('5', 'Include', '2', NULL, 'false', '1'),
    ('6', 'Filename', '5', NULL, 'false', '1')""",
    """INSERT INTO slower_growth.t_membership VALUES
    ('1', '1', '1', '2', '1'),
    ('2', '1', '1', '3', '1'),
    ('3', '1', '1', '3', '1'),
    ('4', '1', '3', '4', '4'),
    ('5', '1', '4', '5', '5'),
    ('6', '1', '5', '6', '6'),
    ('7', '1', '2', '7', '2')""",
    """INSERT INTO slower_growth.t_data VALUES
    ('1', '1', '1', '99'),
    ('2', '2', '1', '21'),
    ('3', '3', '2', '31'),
    ('4', '4', '3', '2'),
    ('5', '5', '4', NULL),
    ('6', '6', '6', NULL),
    ('7', '7', '5', '-1'),
    ('8', '2', '1', NULL),
    ('9', '1', '1', '109')""",
    """INSERT INTO slower_growth.t_date_from VALUES ('1', '2025-01-01T00:00:00'), ('2', '2027-01-01T00:00:00'),
    ('9', '2026-01-01T00:00:00')""",
    "INSERT INTO slower_growth.t_band VALUES ('3', '2')",
    "INSERT INTO slower_growth.t_tag VALUES ('4', '5', '1'), ('5', '6', NULL)",
    "INSERT INTO slower_growth.t_text VALUES ('7', '2', 'M4-9'), ('6', '1', 'Traces/solar/OLD.csv')",
)
