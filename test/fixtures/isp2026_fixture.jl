using AustralianElectricityMarketsData

"""
    write_isp_fixture(path::AbstractString; broken_timeslice::Bool = false)

Write a miniature PLEXOS `MasterDataSet` XML exercising every property-resolution rule.

Contents:
- `GEN_SUPERSEDE`: two open-ended `Max Capacity` records (2024 => 100, 2026 => 250).
  Correct resolution at a 2026-07-01 horizon is **250** (latest `date_from` wins).
- `GEN_EXPIRED`: a `Max Capacity` record that expired in 2025; falls back to the
  property default of 42.
- `GEN_BANDED`: a multi-band `Max Capacity` with bands 1 and 2 (10 and 20).
- `GEN_TAGGED`: a `Max Capacity` row tagged to the active `Summer` timeslice
  (`M1-3,11,12`), which does not contain July; excluded from a 2026-07-01 resolution, so
  it falls back to the default of 42.
- `GEN_PLAIN`: a single undated record of 77.
- `GEN_TIMESLICE_MATCH`: a `Max Capacity` row tagged to the active `Winter` timeslice
  (`M4-10`), which does contain July; resolves to its own value of 88 rather than the
  default.
- `GEN_SPECIFICITY`: an untagged `Max Capacity` record (500, dated 2026) and a
  `Winter`-tagged one (33, dated 2020); the timeslice-matched record wins despite its
  older `date_from`, proving specificity outranks recency.
- `GEN_ODD`: a `Max Capacity` row tagged to the active `Odd` timeslice, a non-month
  day/hour expression (`D1,H1; D15,H1`); never matches, never throws, falls back to the
  default of 42.
- `GEN_SELF_MONTH`: a `Max Capacity` row tagged to the active `M7` timeslice, which has
  no `Include` text expression at all and is matched purely by its own name; resolves to
  its own value of 66 for a July horizon.
- `GEN_INACTIVE_TAG`: a `Max Capacity` row tagged to `Retired`, an **inactive**
  (`Include = 0`) timeslice with neither a text expression nor a month-form name: the
  disabled flag must exclude it before any expression lookup is attempted, so this falls
  back to the default of 42 without throwing.

Five `Timeslice` objects carry a real `Include` expression via their own `Include`
property: `Summer` = `M1-3,11,12`, `Winter` = `M4-10`, `Odd` = `D1,H1; D15,H1` (all
active, `Include = -1`); `M7` is active with no expression, matched by name alone;
`Retired` is inactive (`Include = 0`) with no expression and a non-month name, matching
AEMO's real ISP model, which disables regional seasonal timeslices this way rather than
by omitting their `Include` records.

When `broken_timeslice = true`, an additional active (`Include = -1`) `Mystery`
timeslice is added with neither a text expression nor a month-form name, tagged to
`GEN_BROKEN_TAG`'s `Max Capacity` record: a genuine gap that must make
`resolve_properties` in `AustralianElectricityMarketsPortfolio` throw naming `Mystery`,
not silently return no match. This is opt-in because a genuinely unresolvable active
timeslice makes *every* `resolve_properties` call against the scenario throw, by design;
it must not be present in the default fixture used by the other tests.
"""
function write_isp_fixture(path::AbstractString; broken_timeslice::Bool = false)
    broken_objects = broken_timeslice ? """
          <t_object><object_id>17</object_id><class_id>2</class_id><name>Mystery</name><category_id>3</category_id></t_object>
          <t_object><object_id>18</object_id><class_id>1</class_id><name>GEN_BROKEN_TAG</name><category_id>2</category_id></t_object>
        """ : ""
    broken_memberships = broken_timeslice ? """
          <t_membership><membership_id>16</membership_id><parent_class_id>3</parent_class_id><parent_object_id>1</parent_object_id><collection_id>2</collection_id><child_class_id>2</child_class_id><child_object_id>17</child_object_id></t_membership>
          <t_membership><membership_id>17</membership_id><parent_class_id>3</parent_class_id><parent_object_id>1</parent_object_id><collection_id>1</collection_id><child_class_id>1</child_class_id><child_object_id>18</child_object_id></t_membership>
        """ : ""
    broken_data = broken_timeslice ? """
          <t_data><data_id>19</data_id><membership_id>16</membership_id><property_id>2</property_id><value>-1</value></t_data>
          <t_data><data_id>20</data_id><membership_id>17</membership_id><property_id>1</property_id><value>13</value></t_data>
        """ : ""
    broken_tag = broken_timeslice ? """
          <t_tag><data_id>20</data_id><object_id>17</object_id></t_tag>
        """ : ""
    exercised = (
        "t_class", "t_collection", "t_property", "t_object", "t_category",
        "t_membership", "t_data", "t_date_from", "t_date_to", "t_band",
        "t_tag", "t_text",
    )
    filler = join(
        [
            "<$(table)><id>1</id></$(table)>"
                for table in setdiff(ISP_XML_TABLES, exercised)
        ],
        "\n      ",
    )
    # The trace queries read t_tag.action_id, which the tagged records above omit.
    trace_filler = "<t_tag><action_id>1</action_id></t_tag>"
    xml = """<?xml version="1.0" standalone="yes"?>
    <MasterDataSet>
      <t_class><class_id>1</class_id><name>Generator</name></t_class>
      <t_class><class_id>2</class_id><name>Timeslice</name></t_class>
      <t_class><class_id>3</class_id><name>System</name></t_class>

      <t_collection><collection_id>1</collection_id><parent_class_id>3</parent_class_id><child_class_id>1</child_class_id><name>Generators</name></t_collection>
      <t_collection><collection_id>2</collection_id><parent_class_id>3</parent_class_id><child_class_id>2</child_class_id><name>Timeslices</name></t_collection>

      <t_property><property_id>1</property_id><collection_id>1</collection_id><name>Max Capacity</name><default_value>42</default_value><is_multi_band>false</is_multi_band><max_band_id>1</max_band_id></t_property>
      <t_property><property_id>2</property_id><collection_id>2</collection_id><name>Include</name></t_property>

      <t_object><object_id>1</object_id><class_id>3</class_id><name>NEM</name><category_id>1</category_id></t_object>
      <t_object><object_id>2</object_id><class_id>1</class_id><name>GEN_SUPERSEDE</name><category_id>2</category_id></t_object>
      <t_object><object_id>3</object_id><class_id>1</class_id><name>GEN_EXPIRED</name><category_id>2</category_id></t_object>
      <t_object><object_id>4</object_id><class_id>1</class_id><name>GEN_BANDED</name><category_id>2</category_id></t_object>
      <t_object><object_id>5</object_id><class_id>1</class_id><name>GEN_TAGGED</name><category_id>2</category_id></t_object>
      <t_object><object_id>6</object_id><class_id>1</class_id><name>GEN_PLAIN</name><category_id>2</category_id></t_object>
      <t_object><object_id>7</object_id><class_id>2</class_id><name>Summer</name><category_id>3</category_id></t_object>
      <t_object><object_id>8</object_id><class_id>2</class_id><name>Winter</name><category_id>3</category_id></t_object>
      <t_object><object_id>9</object_id><class_id>2</class_id><name>Odd</name><category_id>3</category_id></t_object>
      <t_object><object_id>10</object_id><class_id>1</class_id><name>GEN_TIMESLICE_MATCH</name><category_id>2</category_id></t_object>
      <t_object><object_id>11</object_id><class_id>1</class_id><name>GEN_SPECIFICITY</name><category_id>2</category_id></t_object>
      <t_object><object_id>12</object_id><class_id>1</class_id><name>GEN_ODD</name><category_id>2</category_id></t_object>
      <t_object><object_id>13</object_id><class_id>2</class_id><name>M7</name><category_id>3</category_id></t_object>
      <t_object><object_id>14</object_id><class_id>2</class_id><name>Retired</name><category_id>3</category_id></t_object>
      <t_object><object_id>15</object_id><class_id>1</class_id><name>GEN_SELF_MONTH</name><category_id>2</category_id></t_object>
      <t_object><object_id>16</object_id><class_id>1</class_id><name>GEN_INACTIVE_TAG</name><category_id>2</category_id></t_object>
      $(broken_objects)

      <t_category><category_id>1</category_id><name>-</name></t_category>
      <t_category><category_id>2</category_id><name>Black Coal NSW</name></t_category>
      <t_category><category_id>3</category_id><name>Seasons</name></t_category>

      <t_membership><membership_id>1</membership_id><parent_class_id>3</parent_class_id><parent_object_id>1</parent_object_id><collection_id>1</collection_id><child_class_id>1</child_class_id><child_object_id>2</child_object_id></t_membership>
      <t_membership><membership_id>2</membership_id><parent_class_id>3</parent_class_id><parent_object_id>1</parent_object_id><collection_id>1</collection_id><child_class_id>1</child_class_id><child_object_id>3</child_object_id></t_membership>
      <t_membership><membership_id>3</membership_id><parent_class_id>3</parent_class_id><parent_object_id>1</parent_object_id><collection_id>1</collection_id><child_class_id>1</child_class_id><child_object_id>4</child_object_id></t_membership>
      <t_membership><membership_id>4</membership_id><parent_class_id>3</parent_class_id><parent_object_id>1</parent_object_id><collection_id>1</collection_id><child_class_id>1</child_class_id><child_object_id>5</child_object_id></t_membership>
      <t_membership><membership_id>5</membership_id><parent_class_id>3</parent_class_id><parent_object_id>1</parent_object_id><collection_id>1</collection_id><child_class_id>1</child_class_id><child_object_id>6</child_object_id></t_membership>
      <t_membership><membership_id>6</membership_id><parent_class_id>3</parent_class_id><parent_object_id>1</parent_object_id><collection_id>2</collection_id><child_class_id>2</child_class_id><child_object_id>7</child_object_id></t_membership>
      <t_membership><membership_id>7</membership_id><parent_class_id>3</parent_class_id><parent_object_id>1</parent_object_id><collection_id>2</collection_id><child_class_id>2</child_class_id><child_object_id>8</child_object_id></t_membership>
      <t_membership><membership_id>8</membership_id><parent_class_id>3</parent_class_id><parent_object_id>1</parent_object_id><collection_id>2</collection_id><child_class_id>2</child_class_id><child_object_id>9</child_object_id></t_membership>
      <t_membership><membership_id>9</membership_id><parent_class_id>3</parent_class_id><parent_object_id>1</parent_object_id><collection_id>1</collection_id><child_class_id>1</child_class_id><child_object_id>10</child_object_id></t_membership>
      <t_membership><membership_id>10</membership_id><parent_class_id>3</parent_class_id><parent_object_id>1</parent_object_id><collection_id>1</collection_id><child_class_id>1</child_class_id><child_object_id>11</child_object_id></t_membership>
      <t_membership><membership_id>11</membership_id><parent_class_id>3</parent_class_id><parent_object_id>1</parent_object_id><collection_id>1</collection_id><child_class_id>1</child_class_id><child_object_id>12</child_object_id></t_membership>
      <t_membership><membership_id>12</membership_id><parent_class_id>3</parent_class_id><parent_object_id>1</parent_object_id><collection_id>2</collection_id><child_class_id>2</child_class_id><child_object_id>13</child_object_id></t_membership>
      <t_membership><membership_id>13</membership_id><parent_class_id>3</parent_class_id><parent_object_id>1</parent_object_id><collection_id>2</collection_id><child_class_id>2</child_class_id><child_object_id>14</child_object_id></t_membership>
      <t_membership><membership_id>14</membership_id><parent_class_id>3</parent_class_id><parent_object_id>1</parent_object_id><collection_id>1</collection_id><child_class_id>1</child_class_id><child_object_id>15</child_object_id></t_membership>
      <t_membership><membership_id>15</membership_id><parent_class_id>3</parent_class_id><parent_object_id>1</parent_object_id><collection_id>1</collection_id><child_class_id>1</child_class_id><child_object_id>16</child_object_id></t_membership>
      $(broken_memberships)

      <t_data><data_id>1</data_id><membership_id>1</membership_id><property_id>1</property_id><value>100</value></t_data>
      <t_data><data_id>2</data_id><membership_id>1</membership_id><property_id>1</property_id><value>250</value></t_data>
      <t_data><data_id>3</data_id><membership_id>2</membership_id><property_id>1</property_id><value>999</value></t_data>
      <t_data><data_id>4</data_id><membership_id>3</membership_id><property_id>1</property_id><value>10</value></t_data>
      <t_data><data_id>5</data_id><membership_id>3</membership_id><property_id>1</property_id><value>20</value></t_data>
      <t_data><data_id>6</data_id><membership_id>4</membership_id><property_id>1</property_id><value>555</value></t_data>
      <t_data><data_id>7</data_id><membership_id>5</membership_id><property_id>1</property_id><value>77</value></t_data>
      <t_data><data_id>8</data_id><membership_id>6</membership_id><property_id>2</property_id><value>-1</value></t_data>
      <t_data><data_id>9</data_id><membership_id>7</membership_id><property_id>2</property_id><value>-1</value></t_data>
      <t_data><data_id>10</data_id><membership_id>8</membership_id><property_id>2</property_id><value>-1</value></t_data>
      <t_data><data_id>11</data_id><membership_id>9</membership_id><property_id>1</property_id><value>88</value></t_data>
      <t_data><data_id>12</data_id><membership_id>10</membership_id><property_id>1</property_id><value>500</value></t_data>
      <t_data><data_id>13</data_id><membership_id>10</membership_id><property_id>1</property_id><value>33</value></t_data>
      <t_data><data_id>14</data_id><membership_id>11</membership_id><property_id>1</property_id><value>99</value></t_data>
      <t_data><data_id>15</data_id><membership_id>12</membership_id><property_id>2</property_id><value>-1</value></t_data>
      <t_data><data_id>16</data_id><membership_id>13</membership_id><property_id>2</property_id><value>0</value></t_data>
      <t_data><data_id>17</data_id><membership_id>14</membership_id><property_id>1</property_id><value>66</value></t_data>
      <t_data><data_id>18</data_id><membership_id>15</membership_id><property_id>1</property_id><value>44</value></t_data>
      $(broken_data)

      <t_date_from><data_id>1</data_id><date>2024-01-01T00:00:00</date></t_date_from>
      <t_date_from><data_id>2</data_id><date>2026-01-01T00:00:00</date></t_date_from>
      <t_date_from><data_id>3</data_id><date>2024-01-01T00:00:00</date></t_date_from>
      <t_date_from><data_id>12</data_id><date>2026-01-01T00:00:00</date></t_date_from>
      <t_date_from><data_id>13</data_id><date>2020-01-01T00:00:00</date></t_date_from>
      <t_date_to><data_id>3</data_id><date>2025-06-30T00:00:00</date></t_date_to>

      <t_band><data_id>5</data_id><band_id>2</band_id></t_band>

      <t_tag><data_id>6</data_id><object_id>7</object_id></t_tag>
      <t_tag><data_id>11</data_id><object_id>8</object_id></t_tag>
      <t_tag><data_id>13</data_id><object_id>8</object_id></t_tag>
      <t_tag><data_id>14</data_id><object_id>9</object_id></t_tag>
      <t_tag><data_id>17</data_id><object_id>13</object_id></t_tag>
      <t_tag><data_id>18</data_id><object_id>14</object_id></t_tag>
      $(broken_tag)
      $(trace_filler)

      <t_text><data_id>8</data_id><class_id>2</class_id><value>M1-3,11,12</value></t_text>
      <t_text><data_id>9</data_id><class_id>2</class_id><value>M4-10</value></t_text>
      <t_text><data_id>10</data_id><class_id>2</class_id><value>D1,H1; D15,H1</value></t_text>
      $(filler)
    </MasterDataSet>
    """
    write(path, xml)
    return path
end

"""
    _isp_trace_fixture_columns(table::AbstractString)

Columns the trace queries require of `table`, or `("id",)` for a table they do not read.

# Arguments
- `table`: PLEXOS table name.

# Returns
- `Tuple` of column names.
"""
function _isp_trace_fixture_columns(table::AbstractString)
    required = Dict(
        AustralianElectricityMarketsData._ISP_TRACE_REFERENCE_COLUMNS...,
        AustralianElectricityMarketsData._ISP_TRACE_BINDING_COLUMNS...,
    )
    return get(required, table, ("id",))
end

"""
    _isp_trace_fixture_record(table::AbstractString, index::Integer = 1) -> String

One XML record for `table` carrying every column the trace queries read, each valued `index`.

# Arguments
- `table`: PLEXOS table name.
- `index`: value written to every field.

# Returns
- `String` the XML record.
"""
function _isp_trace_fixture_record(table::AbstractString, index::Integer = 1)
    fields = join(["<$(column)>$(index)</$(column)>" for column in _isp_trace_fixture_columns(table)])
    return "<$(table)>$(fields)</$(table)>"
end

"""
    write_isp_cache_fixture(dir; scenarios = ["2026 ISP Step Change", "2026 ISP Slower Growth"])

Write one scenario folder per entry of `scenarios`, each holding a PLEXOS XML export with one
record in every table of [`ISP_XML_TABLES`](@ref), carrying the columns the trace queries read.
The first scenario's `t_object` carries two records and the second's three, so cross-scenario
isolation is observable.
"""
function write_isp_cache_fixture(dir; scenarios = ["2026 ISP Step Change", "2026 ISP Slower Growth"])
    for (index, scenario) in enumerate(scenarios)
        folder = joinpath(dir, scenario)
        mkpath(folder)
        objects = index == 1 ? 2 : 3
        records = String[]
        for table in ISP_XML_TABLES
            count = table == "t_object" ? objects : 1
            for i in 1:count
                push!(records, _isp_trace_fixture_record(table, i))
            end
        end
        write(
            joinpath(folder, "$(scenario).xml"),
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<MasterDataSet>\n" *
                join(records, "\n") * "\n</MasterDataSet>\n",
        )
    end
    return dir
end

"""
    write_isp_trace_fixture(dir; missing_reference = false)

Write a scenario XML with Data File references and the CSV traces they point to.

The two `Filename` data rows are untagged, as in the real export. Two `Rating` rows are
tagged to the Data File objects so the bindings view has two non-`Filename` rows. One
reference uses backslashes and the two identical `DEMO` CSVs use CRLF line endings, so both
path normalisation and CRLF record splitting are exercised.

# Arguments
- `dir`: directory to write the fixture under.
- `missing_reference`: add a Data File reference to a CSV that does not exist.

# Returns
- `String` the fixture directory.
"""
function write_isp_trace_fixture(dir; missing_reference = false)
    scenario = joinpath(dir, "model", "2026 ISP Model", "2026 ISP Step Change")
    demand = joinpath(scenario, "Traces", "demand")
    shared = joinpath(dir, "wind", "Traces", "wind")
    mkpath(demand)
    mkpath(shared)
    write(joinpath(demand, "DEMO.csv"), "Year,Month,Day,01\r\n2026,7,1,10\r\n2026,7,1,20\r\n")
    write(
        joinpath(demand, "DEMO_COPY.csv"),
        "Year,Month,Day,01\r\n2026,7,1,10\r\n2026,7,1,20\r\n",
    )
    write(joinpath(shared, "SHARED.csv"), "Year,Value\n2026,5\n")
    records = String[
        "<t_class><class_id>1</class_id><name>Data File</name></t_class>",
        "<t_class><class_id>2</class_id><name>Generator</name></t_class>",
        "<t_property><property_id>1</property_id><name>Filename</name></t_property>",
        "<t_property><property_id>2</property_id><name>Rating</name></t_property>",
        "<t_object><object_id>10</object_id><name>DEMO_GEN</name></t_object>",
        "<t_object><object_id>20</object_id><name>DEMO</name></t_object>",
        "<t_object><object_id>21</object_id><name>SHARED</name></t_object>",
        "<t_membership><membership_id>100</membership_id><parent_object_id>1</parent_object_id><child_object_id>20</child_object_id></t_membership>",
        "<t_membership><membership_id>101</membership_id><parent_object_id>1</parent_object_id><child_object_id>21</child_object_id></t_membership>",
        "<t_data><data_id>1000</data_id><membership_id>100</membership_id><property_id>1</property_id></t_data>",
        "<t_data><data_id>1001</data_id><membership_id>101</membership_id><property_id>1</property_id></t_data>",
        "<t_data><data_id>1002</data_id><membership_id>100</membership_id><property_id>2</property_id><value>5</value></t_data>",
        "<t_data><data_id>1003</data_id><membership_id>101</membership_id><property_id>2</property_id><value>7</value></t_data>",
        "<t_tag><data_id>1002</data_id><object_id>20</object_id><action_id>1</action_id></t_tag>",
        "<t_tag><data_id>1003</data_id><object_id>21</object_id><action_id>1</action_id></t_tag>",
        "<t_text><data_id>1000</data_id><class_id>1</class_id><value>Traces\\demand\\DEMO.csv</value></t_text>",
        "<t_text><data_id>1001</data_id><class_id>1</class_id><value>Traces/wind/SHARED.csv</value></t_text>",
    ]
    if missing_reference
        push!(
            records,
            "<t_object><object_id>22</object_id><name>ABSENT</name></t_object>",
            "<t_membership><membership_id>102</membership_id><parent_object_id>1</parent_object_id><child_object_id>22</child_object_id></t_membership>",
            "<t_data><data_id>1004</data_id><membership_id>102</membership_id><property_id>1</property_id></t_data>",
            "<t_tag><data_id>1004</data_id><object_id>22</object_id><action_id>1</action_id></t_tag>",
            "<t_text><data_id>1004</data_id><class_id>1</class_id><value>Traces/demand/ABSENT.csv</value></t_text>",
        )
    end
    for table in ISP_XML_TABLES
        startswith(table, "t_") || continue
        any(occursin("<$(table)>", record) for record in records) && continue
        push!(records, "<$(table)><id>1</id></$(table)>")
    end
    mkpath(scenario)
    write(
        joinpath(scenario, "2026 ISP Step Change Model.xml"),
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<MasterDataSet>\n" *
            join(records, "\n") * "\n</MasterDataSet>\n",
    )
    return dir
end
