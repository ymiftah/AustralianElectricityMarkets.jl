# ISP 2026 extractable table inventory

This is the inventory of the older local source copy. The [extracted cache report](isp2026-cache.md) records the fresh AEMO downloads and current cache contents.

Inventory date: 28 October 2026. Branch: `isp2026-plexos-parsing`, inspected at `ae5547b`.

This inventory covers the existing local `2026 ISP Model` package in `/home/simba/Downloads/2026 ISP Model`: Accelerated Transition (AT), Slower Growth (SG), and Step Change (SC). All three XML files and all 345 available CSV files were inspected. The local XML hashes are recorded in the [machine-readable catalogue](isp2026-inventory.json). The local package has not been matched byte-for-byte to the current online release.

The package has 27 raw XML tables, 28 populated object classes out of 103 class definitions, and nine referenced trace families. All three scenarios contain 3,345 objects and 14,420 memberships. The current Julia reader selects 13 raw tables by default. Its generic reader can also extract the remaining tables when they are explicitly requested.

AEMO publishes the model and common trace downloads separately. The model instructions describe the scenario folders and the nine trace families; see [AEMO, 2026 ISP PLEXOS Model Instructions, sections 1.1 and 2, pages 5 to 7](https://www.aemo.com.au/-/media/files/major-publications/isp/2026/isp-model/2026-isp-plexos-model-instructions.pdf). All counts, columns, property names and file-presence checks below come from the local files.

## Raw XML tables

Counts are physical XML records. "Default" means included in the existing `ISP_XML_TABLES` list. Descriptions summarise the observed schema; they are not an assertion that all records affect the selected model.

| Table | AT rows | SG rows | SC rows | Default | Contents |
| --- | --- | --- | --- | --- | --- |
| `t_action` | 7 | 7 | 7 | No | Tag action operators, including assignment and arithmetic |
| `t_assembly` | 1 | 1 | 1 | No | External assembly/plugin configuration |
| `t_attribute` | 569 | 569 | 569 | No | Object attribute definitions, defaults, units and validation |
| `t_attribute_data` | 58 | 58 | 58 | No | Attribute values attached directly to objects |
| `t_band` | 13,367 | 13,367 | 13,367 | Yes | Property data band selectors |
| `t_category` | 393 | 393 | 400 | Yes | Categories within object classes |
| `t_class` | 103 | 103 | 103 | Yes | Object class definitions |
| `t_class_group` | 15 | 15 | 15 | No | Class group definitions |
| `t_collection` | 865 | 865 | 865 | Yes | Allowed parent/child relationship definitions |
| `t_collection_report` | 112 | 112 | 112 | No | Relationship rules for reports |
| `t_config` | 18 | 18 | 18 | No | Database and interface configuration |
| `t_custom_column` | 50 | 50 | 50 | No | Custom GUI column configuration |
| `t_data` | 98,283 | 99,085 | 99,549 | Yes | Property values on memberships |
| `t_date_from` | 71,674 | 71,836 | 72,290 | Yes | Property data start dates |
| `t_date_to` | 6,792 | 6,227 | 6,648 | Yes | Property data end dates |
| `t_membership` | 14,420 | 14,420 | 14,420 | Yes | Instantiated parent/child relationships |
| `t_memo_data` | 331 | 333 | 333 | No | Memo values attached to property data |
| `t_message` | 458 | 458 | 458 | No | Validation/message definitions |
| `t_object` | 3,345 | 3,345 | 3,345 | Yes | Named model objects, including category and coordinates |
| `t_property` | 5,097 | 5,097 | 5,097 | Yes | Input property definitions, defaults, units and validation |
| `t_property_group` | 12 | 12 | 12 | No | Property group definitions |
| `t_property_report` | 3,325 | 3,325 | 3,325 | No | Output property definitions, rather than solved output values |
| `t_property_tag` | 40 | 40 | 40 | No | Property classification bit flags |
| `t_report` | 166 | 166 | 166 | No | Requested output settings per report object, phase and property |
| `t_tag` | 15,912 | 17,202 | 17,226 | Yes | Objects and optional actions attached to property data |
| `t_text` | 575 | 575 | 575 | Yes | Text expressions and filenames attached to property data |
| `t_unit` | 139 | 139 | 139 | Yes | Unit symbols, descriptions and display alternatives |

### Observed columns

Columns below are the union of fields actually emitted in the three XMLs. Optional fields can be absent per record; the JSON catalogue includes non-null counts per scenario. Unobserved optional fields in other PLEXOS exports are outside this inventory.

- **`t_action`**: `action_id`, `action_symbol`.
- **`t_assembly`**: `assembly_id`, `filename`, `is_enabled`, `namespace`.
- **`t_attribute`**: `attribute_id`, `class_id`, `default_value`, `description`, `enum_id`, `input_mask`, `is_enabled`, `is_integer`, `is_visible`, `lang_id`, `name`, `tag`, `unit_id`, `validation_rule`.
- **`t_attribute_data`**: `attribute_id`, `object_id`, `value`.
- **`t_band`**: `band_id`, `data_id`.
- **`t_category`**: `category_id`, `class_id`, `name`, `rank`.
- **`t_class`**: `class_group_id`, `class_id`, `description`, `is_enabled`, `lang_id`, `name`.
- **`t_class_group`**: `class_group_id`, `lang_id`, `name`.
- **`t_collection`**: `child_class_id`, `collection_id`, `complement_description`, `complement_max_count`, `complement_min_count`, `complement_name`, `description`, `is_enabled`, `is_one_to_many`, `lang_id`, `max_count`, `min_count`, `name`, `parent_class_id`.
- **`t_collection_report`**: `collection_id`, `left_collection_id`, `right_collection_id`, `rule_id`, `rule_left_collection_id`, `rule_right_collection_id`.
- **`t_config`**: `element`, `value`.
- **`t_custom_column`**: `GUID`, `class_id`, `column_id`, `name`, `position`.
- **`t_data`**: `data_id`, `membership_id`, `property_id`, `uid`, `value`.
- **`t_date_from`**: `data_id`, `date`.
- **`t_date_to`**: `data_id`, `date`.
- **`t_membership`**: `child_class_id`, `child_object_id`, `collection_id`, `membership_id`, `parent_class_id`, `parent_object_id`.
- **`t_memo_data`**: `data_id`, `value`.
- **`t_message`**: `action`, `default_action`, `description`, `number`, `severity`.
- **`t_object`**: `GUID`, `X`, `Y`, `Z`, `category_id`, `class_id`, `description`, `name`, `object_id`.
- **`t_property`**: `collection_id`, `default_value`, `description`, `downscaling_method`, `enum_id`, `input_mask`, `is_dynamic`, `is_enabled`, `is_key`, `is_multi_band`, `is_visible`, `lang_id`, `max_band_id`, `name`, `period_type_id`, `property_group_id`, `property_id`, `property_type`, `tag`, `unit_id`, `upscaling_method`, `validation_rule`.
- **`t_property_group`**: `lang_id`, `name`, `property_group_id`.
- **`t_property_report`**: `collection_id`, `description`, `enum_id`, `is_LT`, `is_MT`, `is_PA`, `is_ST`, `is_multi_band`, `is_period`, `is_quantity`, `is_summary`, `is_visible`, `lang_id`, `name`, `property_group_id`, `property_id`, `summary_lang_id`, `summary_name`, `summary_unit_id`, `unit_id`.
- **`t_property_tag`**: `name`, `tag_id`.
- **`t_report`**: `object_id`, `phase_id`, `property_id`, `report_period`, `report_samples`, `report_statistics`, `report_summary`, `write_flat_files`.
- **`t_tag`**: `action_id`, `data_id`, `object_id`.
- **`t_text`**: `class_id`, `data_id`, `value`.
- **`t_unit`**: `default`, `description`, `imperial_energy`, `imperial_level`, `imperial_volume`, `lang_id`, `metric_level`, `metric_volume`, `unit_id`, `value`.

## Object classes and populated properties

These are source object classes, not 28 separate physical XML tables. They can be extracted as class-specific tables by joining `t_object` to `t_class`, `t_category`, memberships and property records. Object counts match across the three scenarios. Properties are listed wherever explicit `t_data` records occur, including relationship coefficients. Property identity includes `collection_id` and `property_id`; a property name alone is not a safe join key.

The shared property dictionary contains 5,097 definitions. Explicit records populate only a subset in each scenario. A dictionary definition, or its default, does not establish that the corresponding object/relationship is enabled in the model.

| Class | Objects per scenario | Explicit property names, union of scenarios |
| --- | --- | --- |
| Battery | 432 | Build Cost, Capacity, Charge Efficiency, Discharge Efficiency, Economic Life, End Effects Method, FO&M Charge, Firm Capacity, Forced Outage Rate, Initial SoC, Maintenance Rate, Marginal Loss Factor, Max Cycles Day, Max Power, Max SoC, Max Units Built, Mean Time to Repair, Min SoC, Min Units Built, Technical Life, Units, VO&M Charge, WACC |
| Company | 12 | Share |
| Competition | 1 | No explicit t_data properties; inspect attributes and memberships |
| Constraint | 590 | Capacity Built Coefficient, Flow Back Coefficient, Flow Coefficient, Flow Forward Coefficient, Generation Capacity Coefficient, Generation Coefficient, Generation Sent Out Coefficient, Include in LT Plan, Installed Capacity Coefficient, Load Coefficient, Offtake Coefficient, Penalty Price, Production Coefficient, Pump Load Coefficient, RHS, RHS Custom, RHS Day, RHS Month, RHS Year, Release Coefficient, Scalar, Sense, Units Built in Year Coefficient |
| Data File | 570 | Filename |
| Diagnostic | 1 | No explicit t_data properties; inspect attributes and memberships |
| Emission | 5 | Price, Shadow Price |
| Fuel | 125 | Price, Production Rate, Units |
| Generator | 1194 | Aux Incr, Build Cost, Economic Life, Efficiency Incr, FO&M Charge, Firm Capacity, Forced Outage Rate, Heat Rate, Load Subtracter, Maintenance Rate, Marginal Loss Factor, Mark-up, Max Capacity, Max Energy Day, Max Energy Year, Max Units Built, Mean Time to Repair, Min Capacity Factor, Min Capacity Factor Year, Min Load, Min Units Built, Outage Factor, Production Rate, Pump Efficiency, Pump Load, Pump Units, Rating, Rating Factor, Technical Life, Units, VO&M Charge, WACC |
| Horizon | 1 | No explicit t_data properties; inspect attributes and memberships |
| LT Plan | 1 | No explicit t_data properties; inspect attributes and memberships |
| Line | 18 | Loss Allocation, Loss Base, Loss Base Back, Loss Incr, Loss Incr Back, Loss Incr2, Loss Incr2 Back, Marginal Loss Factor, Marginal Loss Factor Back, Max Capacity Reserves, Max Flow, Min Capacity Reserves, Min Flow, Units |
| MLF | 14 | Flow Coefficient, Intercept |
| Model | 1 | No explicit t_data properties; inspect attributes and memberships |
| Node | 15 | Load, Units |
| Performance | 1 | No explicit t_data properties; inspect attributes and memberships |
| Power Station | 116 | Is Enabled |
| Production | 1 | No explicit t_data properties; inspect attributes and memberships |
| Purchaser | 83 | Bid Price, Bid Quantity, Fixed Load, Load Obligation, Max Load, Units |
| Region | 5 | DSP Bid Price, DSP Bid Quantity, Generator Settlement Model, Load Includes Losses, Load Metering Point, Load Settlement Model, VoLL |
| Report | 1 | No explicit t_data properties; inspect attributes and memberships |
| Storage | 31 | Balance Period, End Effects Method, Initial Volume, Internal Volume Scalar, Max Spill, Max Volume, Min Volume, Natural Inflow, Target Week |
| System | 1 | No explicit t_data properties; inspect attributes and memberships |
| Timeslice | 30 | Include |
| Transmission | 1 | No explicit t_data properties; inspect attributes and memberships |
| Variable | 38 | Profile |
| Waterway | 38 | Max Flow |
| Zone | 19 | Min Capacity Reserves, Units |

### Object attributes

There are 569 attribute definitions and 58 explicit `t_attribute_data` values per scenario. These are a separate channel from `t_data`. They hold horizon and simulation configuration, so reading scalar properties alone does not capture the model configuration.

| Class | Explicit values per scenario | Attribute names |
| --- | --- | --- |
| Competition | 1 | Epsilon |
| Diagnostic | 10 | Data File Read, Database Load, Feasibility Repair Weight, IIS, LP Progress, Licensing, Sample Summary, Solver Summary, Step Summary, Task Size |
| Horizon | 9 | Chrono Date From, Chrono Period From, Chrono Period To, Chrono Step Count, Date From, Periods per Day, Step Count, Step Type, Week Beginning |
| LT Plan | 12 | Allow Capacity Sharing, Always Annualize Build Cost, At a Time, Block Count, Chronology, Discount Rate, End Effects Method, LDC Slicing Method, LDC Type, Optimality, Stochastic Method, Transmission Detail |
| Model | 2 | Enabled, Make Unique Name |
| Performance | 7 | Cold Start Optimizer 1, Crossover, Feasibility Tolerance, Hot Start Optimizer 1, MIP Relative Gap, Objective Tolerance, Small LP Optimizer |
| Production | 6 | Formulate Ramp Upfront, Formulate Upfront, Fuel Use Function Precision, Heat Rate Detail, Max Heat Rate Tranches, Rounding Up Threshold |
| Report | 1 | Datetime Convention |
| Transmission | 10 | Allow Dump Energy, Bound Node Phase Angles, Flow PTDF Threshold, Formulate Upfront, Loss Function Precision, Loss Tolerance, Losses Enabled, Max Absolute Phase Angle, Max Loss Tranches, Report All Interzonal Flows |

## Relationship tables

The XML defines 865 collection types. Each scenario instantiates 64 collection types in `t_membership`. The following is the union of instantiated types; the JSON catalogue also contains every collection definition and the populated property catalogue with units and counts.

| Collection ID | Parent class | Collection | Child class | AT | SG | SC |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | System | Generators | Generator | 1194 | 1194 | 1194 |
| 4 | Generator | Heat Input | Generator | 2 | 2 | 2 |
| 6 | Generator | Power Station | Power Station | 340 | 340 | 340 |
| 7 | Generator | Fuels | Fuel | 397 | 397 | 397 |
| 10 | Generator | Head Storage | Storage | 100 | 100 | 100 |
| 11 | Generator | Tail Storage | Storage | 57 | 57 | 57 |
| 12 | Generator | Nodes | Node | 1194 | 1194 | 1194 |
| 24 | Generator | Companies | Company | 1755 | 1755 | 1755 |
| 32 | Generator | Constraints | Constraint | 3729 | 3729 | 3729 |
| 36 | System | Power Stations | Power Station | 116 | 116 | 116 |
| 40 | System | Fuels | Fuel | 125 | 125 | 125 |
| 54 | Fuel | Constraints | Constraint | 136 | 136 | 136 |
| 81 | System | Batteries | Battery | 432 | 432 | 432 |
| 85 | Battery | Nodes | Node | 432 | 432 | 432 |
| 92 | Battery | Constraints | Constraint | 2011 | 2011 | 2011 |
| 99 | System | Storages | Storage | 31 | 31 | 31 |
| 103 | Storage | Constraints | Constraint | 2 | 2 | 2 |
| 107 | System | Waterways | Waterway | 38 | 38 | 38 |
| 110 | Waterway | Storage From | Storage | 38 | 38 | 38 |
| 111 | Waterway | Storage To | Storage | 10 | 10 | 10 |
| 114 | System | Emissions | Emission | 5 | 5 | 5 |
| 117 | Emission | Generators | Generator | 266 | 266 | 266 |
| 118 | Emission | Fuels | Fuel | 34 | 34 | 34 |
| 131 | Emission | Constraints | Constraint | 46 | 46 | 46 |
| 155 | System | Purchasers | Purchaser | 83 | 83 | 83 |
| 158 | Purchaser | Nodes | Node | 83 | 83 | 83 |
| 161 | Purchaser | Constraints | Constraint | 249 | 249 | 249 |
| 214 | System | Regions | Region | 5 | 5 | 5 |
| 226 | Region | Reference Node | Node | 5 | 5 | 5 |
| 252 | System | Zones | Zone | 19 | 19 | 19 |
| 297 | System | Nodes | Node | 15 | 15 | 15 |
| 301 | Node | Region | Region | 15 | 15 | 15 |
| 303 | Node | Capacity Zones | Zone | 29 | 29 | 29 |
| 311 | Node | Constraints | Constraint | 10 | 10 | 10 |
| 321 | System | Lines | Line | 18 | 18 | 18 |
| 325 | Line | Node From | Node | 18 | 18 | 18 |
| 326 | Line | Node To | Node | 18 | 18 | 18 |
| 329 | Line | Constraints | Constraint | 58 | 58 | 58 |
| 332 | System | MLFs | MLF | 14 | 14 | 14 |
| 336 | MLF | Node | Node | 14 | 14 | 14 |
| 337 | MLF | Line | Line | 14 | 14 | 14 |
| 642 | System | Companies | Company | 12 | 12 | 12 |
| 654 | Company | Constraints | Constraint | 6 | 6 | 6 |
| 759 | System | Constraints | Constraint | 590 | 590 | 590 |
| 777 | System | Data Files | Data File | 570 | 570 | 570 |
| 779 | System | Variables | Variable | 38 | 38 | 38 |
| 785 | System | Timeslices | Timeslice | 30 | 30 | 30 |
| 796 | System | Models | Model | 1 | 1 | 1 |
| 799 | Model | Horizon | Horizon | 1 | 1 | 1 |
| 800 | Model | Report | Report | 1 | 1 | 1 |
| 802 | Model | LT Plan | LT Plan | 1 | 1 | 1 |
| 807 | Model | Transmission | Transmission | 1 | 1 | 1 |
| 808 | Model | Production | Production | 1 | 1 | 1 |
| 809 | Model | Competition | Competition | 1 | 1 | 1 |
| 810 | Model | Performance | Performance | 1 | 1 | 1 |
| 811 | Model | Diagnostic | Diagnostic | 1 | 1 | 1 |
| 817 | System | Horizons | Horizon | 1 | 1 | 1 |
| 818 | System | Reports | Report | 1 | 1 | 1 |
| 824 | System | LT Plan | LT Plan | 1 | 1 | 1 |
| 850 | System | Transmission | Transmission | 1 | 1 | 1 |
| 851 | System | Production | Production | 1 | 1 | 1 |
| 852 | System | Competition | Competition | 1 | 1 | 1 |
| 853 | System | Performance | Performance | 1 | 1 | 1 |
| 854 | System | Diagnostics | Diagnostic | 1 | 1 | 1 |

### Join map

```text
t_class.class_id <- t_object.class_id
t_category.category_id <- t_object.category_id
t_object.object_id <- t_membership.parent_object_id / child_object_id
t_collection.collection_id <- t_membership.collection_id
t_membership.membership_id <- t_data.membership_id
t_property.property_id <- t_data.property_id
t_data.data_id <- t_band / t_date_from / t_date_to / t_tag / t_text / t_memo_data
t_object.object_id <- t_tag.object_id
t_action.action_id <- t_tag.action_id (optional)
t_object.object_id <- t_attribute_data.object_id
t_attribute.attribute_id <- t_attribute_data.attribute_id
t_unit.unit_id <- t_property.unit_id / t_attribute.unit_id
t_property_report.property_id <- t_report.property_id
```

Input and output property IDs belong to different dictionaries: `t_report.property_id` refers to `t_property_report`, while `t_data.property_id` refers to `t_property`. Report metadata describes requested outputs, not solved dispatch, prices or expansion results.

The file namespace is essential for every ID-based join. Matching integer IDs across scenario XMLs does not prove the objects or data records are the same.

## External trace tables

Every scenario contains 570 Data File objects and 570 filename references. Of these, 115 referenced CSV files are present locally and 455 are missing. Counts below are per scenario and are identical across scenarios. The three missing families are distributed separately by AEMO; they must be checked before claiming complete trace coverage.

| Family | References | Present | Missing | Observed CSV layout | Contents |
| --- | --- | --- | --- | --- | --- |
| demand | 15 | 15 | 0 | Year, Month, Day + 48 period columns | Sub-regional demand |
| dnsp | 38 | 38 | 0 | Year, Month, Day + 48 period columns | Distribution-level CER limits and coefficient profiles |
| gas | 11 | 11 | 0 | Year, Month, Day + Value | Gas availability limits |
| hydro | 23 | 23 | 0 | Year + 49 generator columns; Year, Month, Day + 1; Year, Month, Day + 48 period columns; Year, Month, Day + Inflows | Hydro inflows and annual generation limits |
| load_subtractor | 9 | 9 | 0 | Year, Month, Day + 48 period columns | Load/VRE approximation adjustments |
| rooftop PV | 19 | 19 | 0 | Year, Month, Day + 48 period columns | Embedded PV profiles |
| solar | 248 | 0 | 248 | Not inspected: files absent | Large-scale solar profiles |
| timeslice | 1 | 0 | 1 | Not inspected: files absent | Seasonal timeslice profiles |
| wind | 206 | 0 | 206 | Not inspected: files absent | Wind profiles |

The JSON catalogue records each filename, its Data File object, property/data IDs, local presence, column names, data-row count, row widths and first/last key fields. Filenames are not sufficient to determine units: follow the tagged property and `t_unit`. The hydro family also contains `MaxEnergyYear_RefYear5000_Flat.csv`, with a `Year` key and 49 generator columns. Other files have date keys and a single column named `1`; a filename beginning `MonthlyNaturalInflow` does not by itself establish the physical row frequency.

A trace reference joins from a consuming property record through `t_tag` to a Data File object, then through that object's `Filename` property and `t_text` to the CSV path. Preserve this link rather than joining files to generators by similar names.

## Coverage of the existing implementation

- `read_plexos_xml` can extract any explicitly named flat XML table. Its default selects 13 of the observed 27 tables and retains values as strings.
- `load_isp_xml!` creates regular DuckDB tables in a scenario schema. It does not write Hive-partitioned Parquet.
- `resolve_properties` resolves numeric scalar properties by class, date, band and supported month-timeslice tags. It excludes records tagged to Data File or Variable objects, so it cannot substitute for trace extraction or expression evaluation.
- The default excludes attributes and attribute values, tag action definitions, memos, simulation/report metadata and several schema dictionaries. All are extractable from the same local XML.
- Inventory counts include disabled and unselected source objects/relationships. Active model selection, attribute/default interpretation, variables, tag actions, reference-year mapping and time-series semantics require additional readers.

## Verification and boundaries

The inventory parsed all three complete XML exports, compared shared dictionary contents across scenarios, checked 15 explicit foreign-key paths and inspected all 345 CSV files. No optimisation or dispatch simulation was run. The JSON includes every foreign-key check result, including any dangling references.

The shared dictionaries (`t_class`, `t_collection`, `t_property`, `t_attribute` and `t_unit`) are identical in the local scenarios. Property records, dates and tags vary by scenario and remain scenario-specific in the catalogue.

This maps extractable content in the local PLEXOS package. It does not enumerate workbook-only sheets, GIS features, other ISP releases, separate public demand-trace archives, or missing external trace files. AEMO's [2026 ISP download page](https://www.aemo.com.au/energy-systems/major-publications/integrated-system-plan-isp/2026-integrated-system-plan-isp) lists those additional products.
