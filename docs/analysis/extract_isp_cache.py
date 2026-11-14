"""Extract a downloaded ISP package into a validated, standalone DuckDB cache.

Uses Python's standard library and the DuckDB CLI already supplied by DuckDB_jll.
Run with --help. The source directory must contain raw/ and downloads.json.
"""

import argparse
import csv
import hashlib
import json
import re
import subprocess
import xml.etree.ElementTree as ET
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path


def literal(value):
    return "'" + str(value).replace("'", "''") + "'"


def identifier(value):
    return '"' + str(value).replace('"', '""') + '"'


def sha256(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def read_xml(path):
    root = ET.parse(path).getroot()
    if root.tag.rsplit('}', 1)[-1] != 'MasterDataSet':
        raise ValueError(f'Not a PLEXOS MasterDataSet: {path}')
    tables = defaultdict(list)
    for record in root:
        table = record.tag.rsplit('}', 1)[-1]
        if not table.startswith('t_'):
            raise ValueError(f'Unrecognised root record {table} in {path}')
        tables[table].append({field.tag.rsplit('}', 1)[-1]: field.text for field in record})
    return dict(tables)


def json_table(statements, staging, schema, table, rows, strings=False):
    if not rows:
        raise ValueError(f'Cannot infer an empty table: {schema}.{table}')
    path = staging / f'{schema}__{table}.jsonl'
    with path.open('w') as stream:
        for row in rows:
            stream.write(json.dumps(row, ensure_ascii=False) + '\n')
    columns = sorted({key for row in rows for key in row})
    options = ", format='newline_delimited', sample_size=-1"
    if strings:
        options += ', columns={' + ', '.join(literal(col) + ": 'VARCHAR'" for col in columns) + '}'
    statements.append(f'CREATE TABLE {identifier(schema)}.{identifier(table)} AS SELECT * FROM read_json({literal(path)}{options});')
    return columns


def query(binary, database, sql):
    result = subprocess.run([str(binary), '-no-init', '-readonly', '-json', '-batch', '-bail', str(database)], input=sql, text=True, capture_output=True, check=True)
    return json.loads(result.stdout or '[]')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--duckdb', type=Path, required=True)
    args = parser.parse_args()
    source = args.source.resolve()
    output = args.output.resolve()
    if output.exists():
        raise FileExistsError(f'Refusing to overwrite an existing cache: {output}')
    timestamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    staging = source / f'import_{timestamp}'
    staging.mkdir()
    output.parent.mkdir(parents=True, exist_ok=True)
    building = output.with_name(f'isp-building-{timestamp}.duckdb')
    provenance = json.loads((source / 'downloads.json').read_text())
    for archive in provenance['archives']:
        archive.pop('final_url', None)
        archive.pop('http_headers', None)
        if sha256(Path(archive['archive_path'])) != archive['sha256']:
            raise ValueError('Archive hash mismatch: ' + archive['archive_path'])
    statements = ["SET threads=2;", "SET memory_limit='768MB';", f'SET temp_directory={literal(staging / "spill")};', 'CREATE SCHEMA cache_meta;', 'CREATE SCHEMA traces;']
    xml_inventory = []
    scenarios = {}
    for path in sorted((source / 'raw/model').rglob('*.xml')):
        name = path.parent.name.removeprefix('2026 ISP ')
        schema = re.sub(r'[^a-z0-9]+', '_', name.lower()).strip('_')
        if schema in scenarios:
            raise ValueError(f'Duplicate scenario schema {schema}')
        tables = read_xml(path)
        xml_digest = sha256(path)
        scenarios[schema] = (path, tables)
        statements.append(f'CREATE SCHEMA {identifier(schema)};')
        for table, rows in sorted(tables.items()):
            columns = json_table(statements, staging, schema, table, rows, strings=True)
            xml_inventory.append({'scenario': schema, 'table_name': table, 'row_count': len(rows), 'column_count': len(columns), 'columns_json': json.dumps(columns), 'source_path': str(path), 'xml_sha256': xml_digest})
        print(f'Prepared XML: {schema}, {len(tables)} tables', flush=True)
    if not scenarios:
        raise ValueError('No scenario XMLs found')
    families = {'demand', 'dnsp', 'gas', 'hydro', 'load_subtractor', 'rooftop pv', 'solar', 'timeslice', 'wind'}
    csv_inventory = []
    file_lookup = defaultdict(list)
    physical = {}
    for path in sorted((source / 'raw').rglob('*.csv')):
        scenario = next((schema for schema, (xml, _) in scenarios.items() if path.is_relative_to(xml.parent)), None)
        family = next((part.lower() for part in path.parts if part.lower() in families), None)
        if family is None:
            raise ValueError(f'Unrecognised trace family: {path}')
        key = (scenario, family + '/' + path.name.lower())
        digest = sha256(path)
        with path.open(encoding='utf-8-sig', newline='') as stream:
            reader = csv.reader(stream)
            columns = next(reader)
            if len({column.lower() for column in columns}) != len(columns):
                raise ValueError(f'Duplicate CSV column name: {path}')
            count = 0
            for row in reader:
                if len(row) != len(columns):
                    raise ValueError(f'CSV width mismatch on row {count + 2}: {path}')
                if '__ISP_CACHE_RESERVED_NULL__' in row:
                    raise ValueError(f'Reserved NULL sentinel occurs in {path}')
                count += 1
        table = 'f_' + digest
        if digest not in physical:
            statements.append(f"CREATE TABLE traces.{identifier(table)} AS SELECT * FROM read_csv({literal(path)}, header=true, all_varchar=true, sample_size=-1, strict_mode=true, nullstr='__ISP_CACHE_RESERVED_NULL__');")
            physical[digest] = {'table_schema': 'traces', 'table_name': table, 'row_count': count, 'column_count': len(columns), 'columns_json': json.dumps(columns)}
        entry = {'scenario': scenario, 'family': family, 'filename': path.name, 'source_path': str(path), 'source_sha256': digest, 'source_bytes': path.stat().st_size, **physical[digest]}
        csv_inventory.append(entry)
        file_lookup[key].append(entry)
        if len(csv_inventory) % 100 == 0:
            print(f'Inspected {len(csv_inventory)} CSV files', flush=True)
    references = []
    for schema, (_, tables) in scenarios.items():
        classes = {row['class_id']: row['name'] for row in tables['t_class']}
        objects = {row['object_id']: row for row in tables['t_object']}
        data = {row['data_id']: row for row in tables['t_data']}
        memberships = {row['membership_id']: row for row in tables['t_membership']}
        properties = {row['property_id']: row for row in tables['t_property']}
        for text in tables['t_text']:
            if classes[text['class_id']] != 'Data File':
                continue
            datum = data[text['data_id']]
            if properties[datum['property_id']]['name'] != 'Filename':
                raise ValueError('Unexpected Data File text property')
            owner = objects[memberships[datum['membership_id']]['child_object_id']]
            relative = text['value'].replace('\\', '/').removeprefix('./')
            parts = relative.split('/')
            if parts[0].lower() != 'traces' or len(parts) != 3:
                raise ValueError(f'Unexpected trace path {relative}')
            key = '/'.join(parts[1:]).lower()
            candidates = file_lookup.get((schema, key)) or file_lookup.get((None, key))
            if not candidates:
                raise FileNotFoundError(f'{schema}: {relative}')
            if len({candidate['source_sha256'] for candidate in candidates}) != 1:
                raise ValueError(f'Ambiguous trace reference {schema}: {relative}')
            found = candidates[0]
            references.append({'scenario': schema, 'data_file_object_id': owner['object_id'], 'data_file_object_name': owner['name'], 'filename_data_id': datum['data_id'], 'relative_path': relative, 'table_schema': found['table_schema'], 'table_name': found['table_name'], 'source_sha256': found['source_sha256'], 'source_path': found['source_path']})
    provenance['cache_created_utc'] = datetime.now(timezone.utc).isoformat()
    provenance['duckdb_cli_version'] = subprocess.check_output([str(args.duckdb), '-version'], text=True).strip()
    provenance['value_storage'] = 'XML fields and original CSV columns are VARCHAR; absent XML fields are SQL NULL; trace layouts and source values are retained without calendar or unit transformations.'
    json_table(statements, staging, 'cache_meta', 'xml_tables', xml_inventory)
    json_table(statements, staging, 'cache_meta', 'trace_files', csv_inventory)
    json_table(statements, staging, 'cache_meta', 'trace_references', references)
    json_table(statements, staging, 'cache_meta', 'provenance', [{'key': key, 'value': json.dumps(value)} for key, value in provenance.items()])
    count_queries = []
    for entry in xml_inventory:
        count_queries.append(f"SELECT {literal(entry['scenario'])} AS table_schema, {literal(entry['table_name'])} AS table_name, count(*) AS actual_count, {entry['row_count']}::BIGINT AS expected_count FROM {identifier(entry['scenario'])}.{identifier(entry['table_name'])}")
    for entry in physical.values():
        count_queries.append(f"SELECT 'traces' AS table_schema, {literal(entry['table_name'])} AS table_name, count(*) AS actual_count, {entry['row_count']}::BIGINT AS expected_count FROM traces.{identifier(entry['table_name'])}")
    statements.append('CREATE TABLE cache_meta.row_count_checks AS ' + ' UNION ALL '.join(count_queries) + ';')
    for schema in scenarios:
        statements.append(f"CREATE VIEW {identifier(schema)}.trace_bindings AS SELECT d.data_id, d.membership_id, d.property_id, p.name AS property_name, m.parent_object_id, m.child_object_id, tag.object_id AS data_file_object_id, tag.action_id, ref.relative_path, ref.table_schema, ref.table_name FROM {identifier(schema)}.t_data d JOIN {identifier(schema)}.t_membership m USING (membership_id) JOIN {identifier(schema)}.t_property p USING (property_id) JOIN {identifier(schema)}.t_tag tag USING (data_id) JOIN cache_meta.trace_references ref ON ref.scenario={literal(schema)} AND ref.data_file_object_id=tag.object_id;")
    statements.append('CHECKPOINT;')
    sql_path = staging / 'import.sql'
    sql_path.write_text('\n'.join(statements) + '\n')
    print(f'Importing {len(xml_inventory)} XML tables and {len(physical)} unique CSV tables; {len(references)} references resolved', flush=True)
    log_path = staging / 'duckdb.log'
    with sql_path.open() as commands, log_path.open('w') as log:
        result = subprocess.run([str(args.duckdb), '-no-init', '-batch', '-bail', str(building)], stdin=commands, stdout=log, stderr=subprocess.STDOUT)
    if result.returncode:
        raise RuntimeError(f'DuckDB import failed; see {log_path}')
    failures = query(args.duckdb, building, 'SELECT * FROM cache_meta.row_count_checks WHERE actual_count <> expected_count;')
    if failures:
        raise ValueError(f'Imported row counts disagree with source: {failures}')
    stored_columns = query(args.duckdb, building, "SELECT table_schema, table_name, column_name, data_type FROM information_schema.columns WHERE table_schema <> 'cache_meta' ORDER BY table_schema, table_name, ordinal_position;")
    actual_columns = defaultdict(list)
    for column in stored_columns:
        if column['table_name'] == 'trace_bindings':
            continue
        if column['data_type'] != 'VARCHAR':
            raise ValueError(f'Unexpected source-value cast: {column}')
        actual_columns[(column['table_schema'], column['table_name'])].append(column['column_name'])
    for entry in xml_inventory:
        if actual_columns[(entry['scenario'], entry['table_name'])] != json.loads(entry['columns_json']):
            raise ValueError(f'XML column mismatch: {entry}')
    for entry in physical.values():
        if actual_columns[('traces', entry['table_name'])] != json.loads(entry['columns_json']):
            raise ValueError(f'CSV column mismatch: {entry}')
    summary = {'database': str(output), 'source_manifest': str(source / 'downloads.json'), 'release_page_date': provenance['page_date'], 'scenarios': {schema: {'xml_tables': len(tables), 'xml_records': sum(len(rows) for rows in tables.values()), 'file_references': sum(row['scenario'] == schema for row in references)} for schema, (_, tables) in scenarios.items()}, 'xml_tables': len(xml_inventory), 'csv_source_files': len(csv_inventory), 'unique_csv_tables': len(physical), 'trace_references': len(references), 'missing_trace_references': 0, 'physical_csv_rows': sum(row['row_count'] for row in physical.values()), 'validated_table_counts': len(xml_inventory) + len(physical), 'validation': 'Source row counts, original column names, VARCHAR storage and every filename reference verified', 'staging_path': str(staging)}
    building.rename(output)
    summary['database_bytes'] = output.stat().st_size
    output.with_suffix('.manifest.json').write_text(json.dumps(summary, indent=2, sort_keys=True) + '\n')
    output.with_suffix('.sources.json').write_text(json.dumps(provenance, indent=2, sort_keys=True) + '\n')
    print(json.dumps(summary, indent=2), flush=True)
    return


if __name__ == '__main__':
    main()
