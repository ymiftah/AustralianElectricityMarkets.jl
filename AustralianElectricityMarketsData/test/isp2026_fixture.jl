"""
    write_isp_fixture(path::AbstractString)

Write a miniature PLEXOS `MasterDataSet` XML exercising every property-resolution rule.

Contents:
- `GEN_SUPERSEDE` — two open-ended `Max Capacity` records (2024 => 100, 2026 => 250).
  Correct resolution at a 2026-07-01 horizon is **250** (latest `date_from` wins).
- `GEN_EXPIRED` — a `Max Capacity` record that expired in 2025; falls back to the
  property default of 42.
- `GEN_BANDED` — a multi-band `Max Capacity` with bands 1 and 2 (10 and 20).
- `GEN_TAGGED` — a `Max Capacity` row tagged to the `Summer` timeslice (`M1-3,11,12`),
  which does not contain July; excluded from a 2026-07-01 resolution, so it falls back to
  the default of 42.
- `GEN_PLAIN` — a single undated record of 77.
- `GEN_TIMESLICE_MATCH` — a `Max Capacity` row tagged to the `Winter` timeslice
  (`M4-10`), which does contain July; resolves to its own value of 88 rather than the
  default.
- `GEN_SPECIFICITY` — an untagged `Max Capacity` record (500, dated 2026) and a
  `Winter`-tagged one (33, dated 2020); the timeslice-matched record wins despite its
  older `date_from`, proving specificity outranks recency.
- `GEN_ODD` — a `Max Capacity` row tagged to a non-month, day/hour timeslice
  (`D1,H1; D15,H1`); never matches, never throws, falls back to the default of 42.

Two `Timeslice` objects carry a real `Include` expression via their own `Include`
property (`Summer` = `M1-3,11,12`, `Winter` = `M4-10`), matching how AEMO's real ISP
model stores seasonal scoping. A third, `Odd`, carries a day/hour expression that the
month parser must ignore rather than error on.
"""
function write_isp_fixture(path::AbstractString)
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

      <t_text><data_id>8</data_id><class_id>2</class_id><value>M1-3,11,12</value></t_text>
      <t_text><data_id>9</data_id><class_id>2</class_id><value>M4-10</value></t_text>
      <t_text><data_id>10</data_id><class_id>2</class_id><value>D1,H1; D15,H1</value></t_text>
    </MasterDataSet>
    """
    write(path, xml)
    return path
end
