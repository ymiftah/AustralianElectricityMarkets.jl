export resolve_properties

"""
    resolve_properties(db, scenario, class, properties, horizon_start; band = 1)

Resolve scalar PLEXOS properties for every object of `class`, at `horizon_start`.

PLEXOS stores a property as many records scoped by date, band and tag. The precedence
implemented here, in order:

1. An object's records are those on memberships where the object is the **child**.
2. **Date scoping.** A record applies when `date_from <= horizon_start` (absent = unbounded
   below) and `date_to >= horizon_start` (absent = unbounded above). Where several applicable
   records remain, the one with the **latest** `date_from` wins; records with no `date_from`
   rank last. Picking the earliest instead is the classic failure — it silently returns a
   superseded capacity.
3. **Bands.** Only records in `band`; an untagged record is band 1.
4. **Tags.** A record is applicable when it is **untagged**, or tagged to a `Timeslice`
   object whose `Include` month expression contains `horizon_start`'s month (e.g. `"M4-10"`
   matches April–October). Records tagged to a Data File or Variable object, or to a
   non-matching or non-month Timeslice (a day/hour timeslice such as `"D1,H1; D15,H1"`), are
   excluded. Among applicable records, a timeslice-matched one **outranks** an untagged one —
   real ISP data often carries no untagged annual record at all, only a seasonal split, so the
   untagged fallback only wins when nothing more specific applies.
5. **Fallback.** An object with no applicable record takes the property's own
   `default_value`. `missing` is never propagated.

# Arguments
- `db`: an open [`AEMDB`](@ref).
- `scenario`: schema name loaded by [`load_isp_xml!`](@ref).
- `class`: PLEXOS class name, e.g. `"Generator"`.
- `properties`: property names to resolve, e.g. `["Max Capacity", "Build Cost"]`.
- `horizon_start`: the date properties are resolved at.
- `band`: band to select. Defaults to 1.

# Returns
- `DataFrame` with `name`, `category`, and one `Float64` column per requested property.
"""
function resolve_properties(
        db::AEMDB,
        scenario::Symbol,
        class::AbstractString,
        properties,
        horizon_start::Date;
        band::Integer = 1,
    )
    schema = isp_scenario_schema(scenario)
    requested = String.(collect(properties))
    isempty(requested) && throw(ArgumentError("no properties requested for class $(class)"))
    _assert_properties_exist(db, schema, class, requested)

    objects = _query(
        db,
        """
        SELECT o.name AS name, COALESCE(c.name, '-') AS category
        FROM $(schema).t_object o
        JOIN $(schema).t_class cl ON cl.class_id = o.class_id
        LEFT JOIN $(schema).t_category c ON c.category_id = o.category_id
        WHERE cl.name = ?
        ORDER BY o.name
        """,
        (class,),
    )
    isempty(objects.name) &&
        throw(ArgumentError("no objects of class $(repr(class)) in scenario $(scenario)"))

    matched_timeslices = _matching_timeslice_ids(db, schema, month(horizon_start))
    tag_filter = isempty(matched_timeslices) ? "tg.data_id IS NULL" :
        "(tg.data_id IS NULL OR tg.object_id IN ($(_sql_string_list(matched_timeslices))))"

    resolved = _query(
        db,
        """
        WITH applicable AS (
            SELECT
                o.name                                            AS name,
                p.name                                             AS property,
                TRY_CAST(d.value AS DOUBLE)                        AS value,
                CAST(df.date AS TIMESTAMP)                         AS date_from,
                CASE WHEN tg.data_id IS NOT NULL THEN 1 ELSE 0 END AS is_timeslice_matched
            FROM $(schema).t_data d
            JOIN $(schema).t_membership m ON m.membership_id = d.membership_id
            JOIN $(schema).t_object     o ON o.object_id     = m.child_object_id
            JOIN $(schema).t_class      cl ON cl.class_id    = o.class_id
            JOIN $(schema).t_property   p ON p.property_id   = d.property_id
            LEFT JOIN $(schema).t_band      b  ON b.data_id  = d.data_id
            LEFT JOIN $(schema).t_date_from df ON df.data_id = d.data_id
            LEFT JOIN $(schema).t_date_to   dt ON dt.data_id = d.data_id
            LEFT JOIN $(schema).t_tag       tg ON tg.data_id = d.data_id
            WHERE cl.name = ?
              AND $(tag_filter)
              AND COALESCE(TRY_CAST(b.band_id AS INTEGER), 1) = ?
              AND (df.date IS NULL OR CAST(df.date AS TIMESTAMP) <= ?)
              AND (dt.date IS NULL OR CAST(dt.date AS TIMESTAMP) >= ?)
        )
        SELECT name, property, value
        FROM (
            SELECT *, row_number() OVER (
                PARTITION BY name, property
                ORDER BY is_timeslice_matched DESC, date_from DESC NULLS LAST
            ) AS rank
            FROM applicable
        )
        WHERE rank = 1
        """,
        (class, Int(band), DateTime(horizon_start), DateTime(horizon_start)),
    )

    defaults = _property_defaults(db, schema, class, requested)
    out = select(objects, :name, :category)
    for property in requested
        lookup = Dict(
            r.name => r.value
                for r in eachrow(resolved) if r.property == property && !ismissing(r.value)
        )
        out[!, property] = [get(lookup, n, defaults[property]) for n in out.name]
    end
    return out
end

function _assert_properties_exist(db::AEMDB, schema::AbstractString, class::AbstractString, requested)
    known = Set(
        _query(
            db,
            """
            SELECT DISTINCT p.name AS name
            FROM $(schema).t_property p
            JOIN $(schema).t_collection col ON col.collection_id = p.collection_id
            JOIN $(schema).t_class cl ON cl.class_id = col.child_class_id
            WHERE cl.name = ?
            """,
            (class,),
        ).name,
    )
    unknown = [p for p in requested if !(p in known)]
    isempty(unknown) || throw(
        ArgumentError(
            "unknown $(class) properties: $(join(unknown, ", ")). " *
                "Check the PLEXOS property name against $(schema).t_property.",
        ),
    )
    return nothing
end

function _property_defaults(db::AEMDB, schema::AbstractString, class::AbstractString, requested)
    rows = _query(
        db,
        """
        SELECT p.name AS name, TRY_CAST(p.default_value AS DOUBLE) AS default_value
        FROM $(schema).t_property p
        JOIN $(schema).t_collection col ON col.collection_id = p.collection_id
        JOIN $(schema).t_class cl ON cl.class_id = col.child_class_id
        WHERE cl.name = ?
        """,
        (class,),
    )
    defaults = Dict{String, Float64}()
    for row in eachrow(rows)
        row.name in requested || continue
        defaults[row.name] = ismissing(row.default_value) ? 0.0 : row.default_value
    end
    for property in requested
        haskey(defaults, property) || (defaults[property] = 0.0)
    end
    return defaults
end

"""
    _matching_timeslice_ids(db, schema, month) -> Set{String}

Find every `Timeslice` object whose `Include` expression contains `month`.

A timeslice's applicable months are stored as a text expression on its own `Include`
property (found via `t_text`, since PLEXOS carries text-valued properties out of line from
`t_data.value`), e.g. `"M4-10"` or `"M1-3,11,12"`. There are only ever a handful of
timeslices in a model, so the month parsing happens in Julia rather than in SQL.

# Arguments
- `db`: an open [`AEMDB`](@ref).
- `schema`: scenario schema name.
- `month`: calendar month (1–12) to test membership for.

# Returns
- `Set{String}` of matching `Timeslice` object ids.
"""
function _matching_timeslice_ids(db::AEMDB, schema::AbstractString, month::Integer)
    rows = _query(
        db,
        """
        SELECT o.object_id AS object_id, tx.value AS expression
        FROM $(schema).t_object o
        JOIN $(schema).t_class      cl ON cl.class_id       = o.class_id
        JOIN $(schema).t_membership m  ON m.child_object_id = o.object_id
        JOIN $(schema).t_data       d  ON d.membership_id   = m.membership_id
        JOIN $(schema).t_property   p  ON p.property_id     = d.property_id
        JOIN $(schema).t_text       tx ON tx.data_id        = d.data_id
        WHERE cl.name = 'Timeslice' AND p.name = 'Include'
        """,
    )
    matching = Set{String}()
    for row in eachrow(rows)
        ismissing(row.expression) && continue
        _month_expression_matches(row.expression, month) && push!(matching, row.object_id)
    end
    return matching
end

"""
    _month_expression_matches(expression, month) -> Bool

Test whether a PLEXOS timeslice `Include` expression contains `month`.

Only the `"M<item>[,<item>...]"` form is understood, where each `item` is a single month
(`"n"`) or an inclusive range (`"a-b"`). Any other form — a day/hour timeslice such as
`"D1,H1; D15,H1"`, or a blank expression — returns `false` rather than throwing: those
timeslices simply never match an annual-scalar resolution.

# Arguments
- `expression`: the raw `Include` text.
- `month`: calendar month (1–12) to test.

# Returns
- `Bool`.
"""
function _month_expression_matches(expression::AbstractString, month::Integer)
    m = match(r"^M(.+)$", strip(expression))
    m === nothing && return false
    for item in split(m.captures[1], ',')
        item = strip(item)
        range_match = match(r"^(\d+)-(\d+)$", item)
        if range_match !== nothing
            lo = parse(Int, range_match.captures[1])
            hi = parse(Int, range_match.captures[2])
            lo <= month <= hi && return true
        else
            single = tryparse(Int, item)
            single !== nothing && single == month && return true
        end
    end
    return false
end

"""
    _sql_string_list(values) -> String

Render `values` as a comma-separated list of single-quoted SQL string literals, for
interpolation into an `IN (...)` clause.

# Arguments
- `values`: an iterable of `AbstractString`.

# Returns
- `String`.
"""
function _sql_string_list(values)
    return join(("'" * replace(v, "'" => "''") * "'" for v in values), ", ")
end
