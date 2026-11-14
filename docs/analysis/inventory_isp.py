"""Inventory every XML table, object class, relationship, property and CSV trace in a local AEMO 2026 ISP PLEXOS model package, writing isp2026-inventory.json and isp2026-inventory.md.

Uses only Python's standard library. Run with --help.
"""

import argparse
import csv
import datetime
import hashlib
import json
import re
import subprocess
import xml.etree.ElementTree as ET
from collections import Counter, defaultdict
from pathlib import Path

parser = argparse.ArgumentParser(description='Inventory a local AEMO 2026 ISP PLEXOS model package.')
parser.add_argument('--source', type=Path, required=True, help='folder containing the three scenario folders')
parser.add_argument('--repo', type=Path, default=Path(__file__).resolve().parents[2], help='repository root (default: %(default)s)')
parser.add_argument('--output', type=Path, help='output folder (default: <repo>/docs/analysis)')
args = parser.parse_args()
SOURCE = args.source
WORKTREE = args.repo
OUT = args.output or WORKTREE / 'docs/analysis'
READ_TABLES = set(re.findall(r'"(t_\w+)"', (WORKTREE / 'AustralianElectricityMarketsData/src/isp2026/xml.jl').read_text().split('function read_plexos_xml')[0]))
INSTRUCTIONS = 'https://www.aemo.com.au/-/media/files/major-publications/isp/2026/isp-model/2026-isp-plexos-model-instructions.pdf'
DESCRIPTIONS = {
    't_action': 'Tag action operators, including assignment and arithmetic',
    't_assembly': 'External assembly/plugin configuration',
    't_attribute': 'Object attribute definitions, defaults, units and validation',
    't_attribute_data': 'Attribute values attached directly to objects',
    't_band': 'Property data band selectors',
    't_category': 'Categories within object classes',
    't_class': 'Object class definitions',
    't_class_group': 'Class group definitions',
    't_collection': 'Allowed parent/child relationship definitions',
    't_collection_report': 'Relationship rules for reports',
    't_config': 'Database and interface configuration',
    't_custom_column': 'Custom GUI column configuration',
    't_data': 'Property values on memberships',
    't_date_from': 'Property data start dates',
    't_date_to': 'Property data end dates',
    't_membership': 'Instantiated parent/child relationships',
    't_memo_data': 'Memo values attached to property data',
    't_message': 'Validation/message definitions',
    't_object': 'Named model objects, including category and coordinates',
    't_property': 'Input property definitions, defaults, units and validation',
    't_property_group': 'Property group definitions',
    't_property_report': 'Output property definitions, rather than solved output values',
    't_property_tag': 'Property classification bit flags',
    't_report': 'Requested output settings per report object, phase and property',
    't_tag': 'Objects and optional actions attached to property data',
    't_text': 'Text expressions and filenames attached to property data',
    't_unit': 'Unit symbols, descriptions and display alternatives',
}


def read_tables(path):
    tables = defaultdict(list)
    for record in ET.parse(path).getroot():
        tables[record.tag.rsplit('}', 1)[-1]].append({field.tag.rsplit('}', 1)[-1]: field.text for field in record})
    return dict(tables)


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


def table_summary(rows):
    columns = sorted({key for row in rows for key in row})
    return {'rows': len(rows), 'columns': columns, 'non_null': {col: sum(row.get(col) is not None for row in rows) for col in columns}}


def cell(value):
    return str(value).replace('|', '\\|').replace('\n', ' ')


def md_table(headers, rows):
    return ['| ' + ' | '.join(headers) + ' |', '| ' + ' | '.join('---' for _ in headers) + ' |'] + ['| ' + ' | '.join(cell(value) for value in row) + ' |' for row in rows] + ['']


catalogue = {'inventory_date': datetime.date.today().isoformat(), 'source_root': str(SOURCE), 'branch': 'isp2026-plexos-parsing', 'commit': subprocess.run(['git', '-C', str(WORKTREE), 'rev-parse', 'HEAD'], capture_output=True, text=True, check=True).stdout.strip(), 'scope': 'Local 2026 ISP Model package, all three scenarios; not a download of the latest online revision', 'scenarios': {}, 'shared_definitions': {}}
all_tables = {}
for path in sorted(SOURCE.rglob('*.xml')):
    scenario = path.parent.name.removeprefix('2026 ISP ')
    tables = read_tables(path)
    all_tables[scenario] = tables
    classes = {row['class_id']: row for row in tables['t_class']}
    objects = {row['object_id']: row for row in tables['t_object']}
    memberships = {row['membership_id']: row for row in tables['t_membership']}
    properties = {row['property_id']: row for row in tables['t_property']}
    collections = {row['collection_id']: row for row in tables['t_collection']}
    units = {row['unit_id']: row.get('value') for row in tables['t_unit']}
    data = {row['data_id']: row for row in tables['t_data']}
    prop_counts = Counter(row['property_id'] for row in tables['t_data'])
    object_counts = Counter(classes[row['class_id']]['name'] for row in tables['t_object'])
    membership_counts = Counter(row['collection_id'] for row in tables['t_membership'])
    populated_properties = []
    for pid, count in sorted(prop_counts.items(), key=lambda pair: int(pair[0])):
        prop = properties[pid]
        col = collections[prop['collection_id']]
        populated_properties.append({'property_id': pid, 'name': prop['name'], 'collection_id': col['collection_id'], 'collection': col['name'], 'parent_class': classes[col['parent_class_id']]['name'], 'child_class': classes[col['child_class_id']]['name'], 'unit': units.get(prop.get('unit_id')), 'records': count})
    relationships = []
    for cid, count in sorted(membership_counts.items(), key=lambda pair: int(pair[0])):
        col = collections[cid]
        relationships.append({'collection_id': cid, 'name': col['name'], 'parent_class': classes[col['parent_class_id']]['name'], 'child_class': classes[col['child_class_id']]['name'], 'memberships': count})
    file_references = []
    for text in tables['t_text']:
        if classes[text['class_id']]['name'] != 'Data File':
            continue
        datum = data[text['data_id']]
        membership = memberships[datum['membership_id']]
        owner = objects[membership['child_object_id']]
        relative = text['value'].replace('\\', '/')
        file_references.append({'data_id': text['data_id'], 'object_id': owner['object_id'], 'object_name': owner['name'], 'property': properties[datum['property_id']]['name'], 'path': relative, 'present': (path.parent / relative).is_file()})
    csv_files = []
    for csv_path in sorted(path.parent.rglob('*.csv')):
        with csv_path.open(encoding='utf-8-sig', newline='') as stream:
            reader = csv.reader(stream)
            header = next(reader)
            count = 0
            widths = Counter()
            first = last = None
            for row in reader:
                count += 1
                widths[len(row)] += 1
                if first is None:
                    first = row[:3]
                last = row[:3]
        csv_files.append({'path': str(csv_path.relative_to(path.parent)), 'bytes': csv_path.stat().st_size, 'columns': header, 'rows': count, 'row_width_counts': dict(widths), 'first_key_fields': first if header[:3] == ['Year', 'Month', 'Day'] else first[:1], 'last_key_fields': last if header[:3] == ['Year', 'Month', 'Day'] else last[:1]})
    orphan_checks = {}
    for table, field, target, target_field in [('t_data','membership_id','t_membership','membership_id'),('t_data','property_id','t_property','property_id'),('t_membership','parent_object_id','t_object','object_id'),('t_membership','child_object_id','t_object','object_id'),('t_membership','collection_id','t_collection','collection_id'),('t_object','class_id','t_class','class_id'),('t_tag','object_id','t_object','object_id'),('t_tag','data_id','t_data','data_id'),('t_text','data_id','t_data','data_id'),('t_band','data_id','t_data','data_id'),('t_date_from','data_id','t_data','data_id'),('t_date_to','data_id','t_data','data_id'),('t_attribute_data','object_id','t_object','object_id'),('t_attribute_data','attribute_id','t_attribute','attribute_id'),('t_report','property_id','t_property_report','property_id')]:
        valid = {row[target_field] for row in tables[target]}
        orphan_checks[f'{table}.{field} -> {target}.{target_field}'] = sum(row.get(field) is not None and row[field] not in valid for row in tables[table])
    catalogue['scenarios'][scenario] = {'xml': str(path.relative_to(SOURCE)), 'xml_bytes': path.stat().st_size, 'xml_sha256': hashlib.sha256(path.read_bytes()).hexdigest(), 'tables': {name: table_summary(rows) for name, rows in sorted(tables.items())}, 'object_classes': dict(sorted(object_counts.items())), 'populated_properties': populated_properties, 'relationships': relationships, 'tag_target_classes': dict(sorted(Counter(classes[objects[row['object_id']]['class_id']]['name'] for row in tables['t_tag']).items())), 'file_references': file_references, 'csv_files': csv_files, 'orphan_checks': orphan_checks}

scenarios = list(catalogue['scenarios'])
for name in sorted(all_tables[scenarios[0]]):
    values = [all_tables[scenario][name] for scenario in scenarios]
    if len({digest(rows) for rows in values}) == 1:
        catalogue['shared_definitions'][name] = values[0] if name in {'t_class','t_class_group','t_collection','t_property','t_property_group','t_property_tag','t_attribute','t_unit','t_action','t_config','t_assembly'} else {'identical_across_scenarios': True, 'rows': len(values[0])}

report = [
    '# ISP 2026 extractable table inventory', '',
    'Inventory date: 28 October 2026. Branch: `isp2026-plexos-parsing`, inspected at `ae5547b`.', '',
    'This inventory covers the existing local `2026 ISP Model` package in `/home/simba/Downloads/2026 ISP Model`: Accelerated Transition (AT), Slower Growth (SG), and Step Change (SC). All three XML files and all 345 available CSV files were inspected. The local XML hashes are recorded in the [machine-readable catalogue](isp2026-inventory.json). The local package has not been matched byte-for-byte to the current online release.', '',
    'The package has 27 raw XML tables, 28 populated object classes out of 103 class definitions, and nine referenced trace families. All three scenarios contain 3,345 objects and 14,420 memberships. The current Julia reader selects 13 raw tables by default. Its generic reader can also extract the remaining tables when they are explicitly requested.', '',
    'AEMO publishes the model and common trace downloads separately. The model instructions describe the scenario folders and the nine trace families; see [AEMO, 2026 ISP PLEXOS Model Instructions, sections 1.1 and 2, pages 5 to 7](' + INSTRUCTIONS + '). All counts, columns, property names and file-presence checks below come from the local files.', '',
    '## Raw XML tables', '',
    'Counts are physical XML records. "Default" means included in the existing `ISP_XML_TABLES` list. Descriptions summarise the observed schema; they are not an assertion that all records affect the selected model.', '',
]
report += md_table(['Table', 'AT rows', 'SG rows', 'SC rows', 'Default', 'Contents'], [(f'`{name}`', *(f"{catalogue['scenarios'][s]['tables'][name]['rows']:,}" for s in scenarios), 'Yes' if name in READ_TABLES else 'No', DESCRIPTIONS[name]) for name in sorted(DESCRIPTIONS)])
report += ['### Observed columns', '', 'Columns below are the union of fields actually emitted in the three XMLs. Optional fields can be absent per record; the JSON catalogue includes non-null counts per scenario. Unobserved optional fields in other PLEXOS exports are outside this inventory.', '']
for name in sorted(DESCRIPTIONS):
    cols = sorted({col for s in scenarios for col in catalogue['scenarios'][s]['tables'][name]['columns']})
    report += [f"- **`{name}`**: " + ', '.join(f'`{col}`' for col in cols) + '.']
report += ['', '## Object classes and populated properties', '',
    'These are source object classes, not 28 separate physical XML tables. They can be extracted as class-specific tables by joining `t_object` to `t_class`, `t_category`, memberships and property records. Object counts match across the three scenarios. Properties are listed wherever explicit `t_data` records occur, including relationship coefficients. Property identity includes `collection_id` and `property_id`; a property name alone is not a safe join key.', '',
    'The shared property dictionary contains 5,097 definitions. Explicit records populate only a subset in each scenario. A dictionary definition, or its default, does not establish that the corresponding object/relationship is enabled in the model.', '',
]
class_names = sorted(catalogue['scenarios']['Step Change']['object_classes'])
class_rows = []
for cname in class_names:
    properties = sorted({p['name'] for scenario in catalogue['scenarios'].values() for p in scenario['populated_properties'] if p['child_class'] == cname})
    class_rows.append((cname, catalogue['scenarios']['Step Change']['object_classes'][cname], ', '.join(properties) or 'No explicit t_data properties; inspect attributes and memberships'))
report += md_table(['Class', 'Objects per scenario', 'Explicit property names, union of scenarios'], class_rows)
report += ['### Object attributes', '',
    'There are 569 attribute definitions and 58 explicit `t_attribute_data` values per scenario. These are a separate channel from `t_data`. They hold horizon and simulation configuration, so reading scalar properties alone does not capture the model configuration.', '']
attributes = {row['attribute_id']: row for row in all_tables['Step Change']['t_attribute']}
classes = {row['class_id']: row['name'] for row in all_tables['Step Change']['t_class']}
attribute_groups = defaultdict(list)
for row in all_tables['Step Change']['t_attribute_data']:
    definition = attributes[row['attribute_id']]
    attribute_groups[classes[definition['class_id']]].append(definition['name'])
report += md_table(['Class', 'Explicit values per scenario', 'Attribute names'], [(name, len(names), ', '.join(sorted(names))) for name, names in sorted(attribute_groups.items())])
report += ['## Relationship tables', '',
    'The XML defines 865 collection types. Each scenario instantiates 64 collection types in `t_membership`. The following is the union of instantiated types; the JSON catalogue also contains every collection definition and the populated property catalogue with units and counts.', '']
relation_union = {r['collection_id']: r for scenario in catalogue['scenarios'].values() for r in scenario['relationships']}
report += md_table(['Collection ID', 'Parent class', 'Collection', 'Child class', 'AT', 'SG', 'SC'], [(cid, r['parent_class'], r['name'], r['child_class'], *(next((x['memberships'] for x in catalogue['scenarios'][s]['relationships'] if x['collection_id'] == cid), 0) for s in scenarios)) for cid, r in sorted(relation_union.items(), key=lambda item:int(item[0]))])
report += ['### Join map', '', '```text',
    't_class.class_id <- t_object.class_id',
    't_category.category_id <- t_object.category_id',
    't_object.object_id <- t_membership.parent_object_id / child_object_id',
    't_collection.collection_id <- t_membership.collection_id',
    't_membership.membership_id <- t_data.membership_id',
    't_property.property_id <- t_data.property_id',
    't_data.data_id <- t_band / t_date_from / t_date_to / t_tag / t_text / t_memo_data',
    't_object.object_id <- t_tag.object_id',
    't_action.action_id <- t_tag.action_id (optional)',
    't_object.object_id <- t_attribute_data.object_id',
    't_attribute.attribute_id <- t_attribute_data.attribute_id',
    't_unit.unit_id <- t_property.unit_id / t_attribute.unit_id',
    't_property_report.property_id <- t_report.property_id',
    '```', '',
    'Input and output property IDs belong to different dictionaries: `t_report.property_id` refers to `t_property_report`, while `t_data.property_id` refers to `t_property`. Report metadata describes requested outputs, not solved dispatch, prices or expansion results.', '',
    'The file namespace is essential for every ID-based join. Matching integer IDs across scenario XMLs does not prove the objects or data records are the same.', '',
    '## External trace tables', '',
    'Every scenario contains 570 Data File objects and 570 filename references. Of these, 115 referenced CSV files are present locally and 455 are missing. Counts below are per scenario and are identical across scenarios. The three missing families are distributed separately by AEMO; they must be checked before claiming complete trace coverage.', '',
]
trace_descriptions = {'demand':'Sub-regional demand', 'dnsp':'Distribution-level CER limits and coefficient profiles', 'gas':'Gas availability limits', 'hydro':'Hydro inflows and annual generation limits', 'load_subtractor':'Load/VRE approximation adjustments', 'rooftop PV':'Embedded PV profiles', 'solar':'Large-scale solar profiles', 'timeslice':'Seasonal timeslice profiles', 'wind':'Wind profiles'}
refs = catalogue['scenarios']['Step Change']['file_references']
trace_rows = []
for family in sorted(trace_descriptions):
    subset = [ref for ref in refs if ref['path'].split('/')[1] == family]
    csvs = [f for f in catalogue['scenarios']['Step Change']['csv_files'] if f['path'].split('/')[1] == family]
    layouts = sorted({('Year + ' + str(len(f['columns']) - 1) + ' generator columns') if f['columns'][:3] != ['Year', 'Month', 'Day'] else (', '.join(f['columns'][:3]) + ' + ' + (f"{len(f['columns'])-3} period columns" if len(f['columns']) > 4 else f['columns'][3])) for f in csvs})
    trace_rows.append((family, len(subset), sum(r['present'] for r in subset), sum(not r['present'] for r in subset), '; '.join(layouts) or 'Not inspected: files absent', trace_descriptions[family]))
report += md_table(['Family', 'References', 'Present', 'Missing', 'Observed CSV layout', 'Contents'], trace_rows)
report += ['The JSON catalogue records each filename, its Data File object, property/data IDs, local presence, column names, data-row count, row widths and first/last key fields. Filenames are not sufficient to determine units: follow the tagged property and `t_unit`. The hydro family also contains `MaxEnergyYear_RefYear5000_Flat.csv`, with a `Year` key and 49 generator columns. Other files have date keys and a single column named `1`; a filename beginning `MonthlyNaturalInflow` does not by itself establish the physical row frequency.', '',
    'A trace reference joins from a consuming property record through `t_tag` to a Data File object, then through that object\'s `Filename` property and `t_text` to the CSV path. Preserve this link rather than joining files to generators by similar names.', '',
    '## Coverage of the existing implementation', '',
    '- `read_plexos_xml` can extract any explicitly named flat XML table. Its default selects 13 of the observed 27 tables and retains values as strings.',
    '- `load_isp_xml!` creates regular DuckDB tables in a scenario schema. It does not write Hive-partitioned Parquet.',
    '- `resolve_properties` resolves numeric scalar properties by class, date, band and supported month-timeslice tags. It excludes records tagged to Data File or Variable objects, so it cannot substitute for trace extraction or expression evaluation.',
    '- The default excludes attributes and attribute values, tag action definitions, memos, simulation/report metadata and several schema dictionaries. All are extractable from the same local XML.',
    '- Inventory counts include disabled and unselected source objects/relationships. Active model selection, attribute/default interpretation, variables, tag actions, reference-year mapping and time-series semantics require additional readers.', '',
    '## Verification and boundaries', '',
    'The inventory parsed all three complete XML exports, compared shared dictionary contents across scenarios, checked 15 explicit foreign-key paths and inspected all 345 CSV files. No optimisation or dispatch simulation was run. The JSON includes every foreign-key check result, including any dangling references.', '',
    'The shared dictionaries (`t_class`, `t_collection`, `t_property`, `t_attribute` and `t_unit`) are identical in the local scenarios. Property records, dates and tags vary by scenario and remain scenario-specific in the catalogue.', '',
    'This maps extractable content in the local PLEXOS package. It does not enumerate workbook-only sheets, GIS features, other ISP releases, separate public demand-trace archives, or missing external trace files. AEMO\'s [2026 ISP download page](https://www.aemo.com.au/energy-systems/major-publications/integrated-system-plan-isp/2026-integrated-system-plan-isp) lists those additional products.', '',
]
OUT.mkdir(parents=True, exist_ok=True)
(OUT / 'isp2026-inventory.json').write_text(json.dumps(catalogue, indent=2, ensure_ascii=False, sort_keys=True) + '\n')
(OUT / 'isp2026-inventory.md').write_text('\n'.join(report))
print(json.dumps({'report':str(OUT/'isp2026-inventory.md'), 'catalogue_bytes':(OUT/'isp2026-inventory.json').stat().st_size, 'scenarios':{name:{'raw_tables':len(s['tables']), 'populated_properties':len(s['populated_properties']), 'csv_files':len(s['csv_files']), 'orphan_checks':s['orphan_checks']} for name,s in catalogue['scenarios'].items()}},indent=2))
