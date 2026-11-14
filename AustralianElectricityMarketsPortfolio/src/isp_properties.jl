"""
    isp_property_catalogue(source::ISPSourceData; class = nothing)::DataFrame

List the properties of `source` with their class, default and object count, flagging property names that map to more than one property id within a class.

# Arguments

- `source::ISPSourceData`: source data read by [`read_isp_source`](@ref).

# Keywords

- `class`: class name to keep, for example `"Generator"`. `nothing` keeps every class.

# Returns

- `DataFrame` with the columns `property_id`, `name`, `collection_id`, `collection_name`, `class_name`, `default_value`, `object_count` and `is_ambiguous`. `class_name` is the child class of the property's collection and `is_ambiguous` is `true` when the same name maps to several property ids in that class.

# Example

```julia
catalogue = isp_property_catalogue(source; class = "Generator")
```
"""
function isp_property_catalogue(source::ISPSourceData; class::Union{AbstractString, Nothing} = nothing)::DataFrame
    table = _property_classes(source)
    ids_by_name = Dict{Tuple{String, String}, Set{String}}()
    for row in eachrow(table)
        push!(get!(() -> Set{String}(), ids_by_name, (row.class_name, row.name)), row.property_id)
    end
    object_counts = Dict{String, Int}()
    for class_name in source.objects.class_name
        object_counts[class_name] = get(object_counts, class_name, 0) + 1
    end
    table.object_count = [get(object_counts, c, 0) for c in table.class_name]
    table.is_ambiguous = [length(ids_by_name[(row.class_name, row.name)]) > 1 for row in eachrow(table)]
    if class !== nothing
        table = table[table.class_name .== String(class), :]
    end
    return sort(table, [:class_name, :name, :property_id])
end

"""
    isp_matching_timeslices(source::ISPSourceData, month::Integer)::Vector{ISPTimeSlice}

Return the active timeslices of `source` whose months contain `month`.

A timeslice matches when any of its `Include` text expressions covers `month`. A timeslice with no `Include` text is matched by its own name when the name has the form `"M<1-12>"`; an active timeslice with neither throws.

# Arguments

- `source::ISPSourceData`: source data read by [`read_isp_source`](@ref).
- `month::Integer`: calendar month, from 1 to 12.

# Returns

- `Vector{ISPTimeSlice}`: matching timeslices in the order of `source.timeslices`.

# Example

```julia
winter = isp_matching_timeslices(source, 7)
```
"""
function isp_matching_timeslices(source::ISPSourceData, month::Integer)::Vector{ISPTimeSlice}
    1 <= month <= 12 || throw(ArgumentError("month must be between 1 and 12, got $(month)"))
    matching = ISPTimeSlice[]
    for slice in source.timeslices
        slice.is_active || continue
        if isempty(slice.include_texts)
            self_named = _self_named_month(slice.name)
            self_named === nothing && throw(
                ArgumentError(
                    "Timeslice $(repr(slice.name)) (object_id $(slice.object_id)) is active " *
                        "(Include = -1) but has no Include text expression and its name is " *
                        "not of the form \"M<1-12>\"; cannot determine which months it covers.",
                ),
            )
            self_named == month && push!(matching, slice)
        elseif any(expression -> _month_expression_matches(expression, month), slice.include_texts)
            push!(matching, slice)
        end
    end
    return matching
end

"""
    resolve_property(source::ISPSourceData, property_id::AbstractString, horizon_start::Date; band::Integer = 1)::DataFrame

Resolve one property for every object of its class, at `horizon_start`.

The applicable records of each object are selected by band, date window and timeslice tags. Among them a timeslice-matched record wins over an untagged one, then the latest `date_from` wins, then the smallest `data_id`. An object with no applicable record takes the property's default value, which is `missing` when the property declares none.

# Arguments

- `source::ISPSourceData`: source data read by [`read_isp_source`](@ref).
- `property_id::AbstractString`: property id from [`isp_property_catalogue`](@ref).
- `horizon_start::Date`: date the property is resolved at.

# Keywords

- `band::Integer`: band to select. Defaults to 1.

# Returns

- `DataFrame` with one row per object of the property's class, ordered by object name, and the columns `object_id`, `object_name`, `category`, `value`, `data_id` and `is_default`. `data_id` is `missing` when the default was used.

# Example

```julia
capacity = resolve_property(source, "1", Date(2026, 7, 1))
```
"""
function resolve_property(
        source::ISPSourceData,
        property_id::AbstractString,
        horizon_start::Date;
        band::Integer = 1,
    )::DataFrame
    id = String(property_id)
    table = _property_classes(source)
    rows = table[table.property_id .== id, :]
    isempty(rows.property_id) && throw(ArgumentError("unknown property id $(repr(id)) in scenario $(source.scenario)"))
    class_name = first(rows.class_name)
    default = _parse_default(first(rows.default_value))
    objects = _class_objects(source, class_name)
    matched = _matched_object_ids(source, horizon_start)
    index = _index_records(source, Set([id]))
    resolved = [
        _resolve_object(get(index, (id, object_id), ISPSourceRecord[]), default, matched, horizon_start, Int(band))
            for object_id in objects.object_id
    ]
    return DataFrame(
        object_id = objects.object_id,
        object_name = objects.name,
        category = objects.category,
        value = Union{Float64, Missing}[r.value for r in resolved],
        data_id = Union{String, Missing}[r.data_id for r in resolved],
        is_default = Bool[r.is_default for r in resolved],
    )
end

"""
    resolve_properties(source::ISPSourceData, class::AbstractString, properties, horizon_start::Date; band::Integer = 1, collection_id::Union{AbstractString, Nothing} = nothing)::DataFrame

Resolve several property names for every object of `class`, at `horizon_start`.

Each name must identify one property of `class`. A name shared by several properties of the class is an error unless `collection_id` picks one of them.

# Arguments

- `source::ISPSourceData`: source data read by [`read_isp_source`](@ref).
- `class::AbstractString`: child class name, for example `"Generator"`.
- `properties`: iterable of property names, for example `["Max Capacity", "Build Cost"]`.
- `horizon_start::Date`: date the properties are resolved at.

# Keywords

- `band::Integer`: band to select. Defaults to 1.
- `collection_id`: collection the properties must belong to, or `nothing` for any.

# Returns

- `DataFrame` with one row per object of `class`, ordered by object name, and the columns `name`, `category` and one column per requested property, in the requested order. Each property column holds `Float64` or `missing` values.

# Example

```julia
df = resolve_properties(source, "Generator", ["Max Capacity"], Date(2026, 7, 1); collection_id = "1")
```
"""
function resolve_properties(
        source::ISPSourceData,
        class::AbstractString,
        properties,
        horizon_start::Date;
        band::Integer = 1,
        collection_id::Union{AbstractString, Nothing} = nothing,
    )::DataFrame
    properties isa AbstractString && throw(ArgumentError("properties must be a collection of names, got the single name $(repr(properties))"))
    names = String.(collect(properties))
    isempty(names) && throw(ArgumentError("no properties requested for class $(class)"))
    length(unique(names)) == length(names) || throw(ArgumentError("properties requested for class $(class) repeat a name: $(names)"))
    table = _property_classes(source)
    ids = [_select_property_id(table, class, name, collection_id) for name in names]
    defaults = Dict{String, Union{Float64, Missing}}(
        row.property_id => _parse_default(row.default_value) for row in eachrow(table) if row.property_id in ids
    )
    objects = _class_objects(source, class)
    matched = _matched_object_ids(source, horizon_start)
    index = _index_records(source, Set(ids))
    out = DataFrame(name = objects.name, category = objects.category)
    for (name, id) in zip(names, ids)
        out[!, name] = Union{Float64, Missing}[
            _resolve_object(get(index, (id, object_id), ISPSourceRecord[]), defaults[id], matched, horizon_start, Int(band)).value
                for object_id in objects.object_id
        ]
    end
    return out
end

"""
    _property_classes(source::ISPSourceData)::DataFrame

Return one row per property of `source`, with the child class of its collection.

# Arguments

- `source::ISPSourceData`: source data read by [`read_isp_source`](@ref).

# Returns

- `DataFrame` with the columns `property_id`, `name`, `collection_id`, `collection_name`, `class_name` and `default_value`.
"""
function _property_classes(source::ISPSourceData)::DataFrame
    collections = Dict{String, Tuple{String, String}}()
    for row in eachrow(source.collections)
        collections[String(row.collection_id)] = (String(row.collection_name), String(row.child_class_name))
    end
    table = DataFrame(
        property_id = String[],
        name = String[],
        collection_id = String[],
        collection_name = String[],
        class_name = String[],
        default_value = Union{String, Missing}[],
    )
    for row in eachrow(source.properties)
        collection_id = String(row.collection_id)
        collection_name, class_name = get(collections, collection_id, ("-", "-"))
        push!(
            table,
            (String(row.property_id), String(row.name), collection_id, collection_name, class_name, row.default_value),
        )
    end
    return table
end

"""
    _select_property_id(table::DataFrame, class::AbstractString, name::AbstractString, collection_id)::String

Return the single property id named `name` in `class`, restricted to `collection_id` when given.

# Arguments

- `table::DataFrame`: result of [`_property_classes`](@ref).
- `class::AbstractString`: child class name.
- `name::AbstractString`: property name.
- `collection_id`: collection the property must belong to, or `nothing` for any.

# Returns

- `String`: the property id.
"""
function _select_property_id(table::DataFrame, class::AbstractString, name::AbstractString, collection_id)::String
    mask = (table.name .== name) .& (table.class_name .== class)
    scope = ""
    if collection_id !== nothing
        mask = mask .& (table.collection_id .== String(collection_id))
        scope = " in collection $(repr(String(collection_id)))"
    end
    candidates = table[mask, :]
    isempty(candidates.property_id) && throw(ArgumentError("no $(class) property named $(repr(name))$(scope)"))
    if nrow(candidates) > 1
        listed = join(
            ["property_id $(repr(r.property_id)) (collection_id $(repr(r.collection_id)))" for r in eachrow(candidates)],
            "; ",
        )
        throw(
            ArgumentError(
                "property $(repr(name)) is ambiguous in class $(class): $(listed); pass collection_id to choose one",
            ),
        )
    end
    return String(only(candidates.property_id))
end

"""
    _class_objects(source::ISPSourceData, class::AbstractString)::DataFrame

Return the objects of `class`, sorted by name.

# Arguments

- `source::ISPSourceData`: source data read by [`read_isp_source`](@ref).
- `class::AbstractString`: class name.

# Returns

- `DataFrame` with the columns `object_id`, `name`, `class_name` and `category`.
"""
function _class_objects(source::ISPSourceData, class::AbstractString)::DataFrame
    selected = source.objects[source.objects.class_name .== class, :]
    return sort(selected, :name)
end

"""
    _matched_object_ids(source::ISPSourceData, horizon_start::Date)::Set{String}

Return the object ids of the timeslices that match the month of `horizon_start`.

# Arguments

- `source::ISPSourceData`: source data read by [`read_isp_source`](@ref).
- `horizon_start::Date`: date whose month is tested.

# Returns

- `Set{String}`: matching timeslice object ids.
"""
function _matched_object_ids(source::ISPSourceData, horizon_start::Date)::Set{String}
    slices = isp_matching_timeslices(source, Dates.month(horizon_start))
    return Set{String}(slice.object_id for slice in slices)
end

"""
    _index_records(source::ISPSourceData, property_ids)::Dict{Tuple{String,String},Vector{ISPSourceRecord}}

Group the records of the given properties by `(property_id, object_id)`.

# Arguments

- `source::ISPSourceData`: source data read by [`read_isp_source`](@ref).
- `property_ids`: property ids to keep.

# Returns

- `Dict{Tuple{String,String},Vector{ISPSourceRecord}}`: records in source order for each property and object.
"""
function _index_records(source::ISPSourceData, property_ids)::Dict{Tuple{String, String}, Vector{ISPSourceRecord}}
    index = Dict{Tuple{String, String}, Vector{ISPSourceRecord}}()
    for record in source.records
        record.property_id in property_ids || continue
        push!(get!(() -> ISPSourceRecord[], index, (record.property_id, record.object_id)), record)
    end
    return index
end

"""
    _parse_default(value)::Union{Float64,Missing}

Cast a stored default value to `Float64`, or return `missing` when it is absent or not numeric.

# Arguments

- `value`: the stored default text, or `missing`.

# Returns

- `Union{Float64,Missing}`: the parsed default.
"""
function _parse_default(value)::Union{Float64, Missing}
    ismissing(value) && return missing
    parsed = tryparse(Float64, strip(String(value)))
    return parsed === nothing ? missing : parsed
end

"""
    _applies(record::ISPSourceRecord, band::Int, horizon_start::Date, matched::Set{String})::Bool

Test whether a record is a candidate value for the given band, date and timeslice matches.

A record applies when its value is numeric, its band is `band`, its date window holds at `horizon_start`, and it is either untagged or tagged to a matched timeslice. A record tagged to a Data File or Variable never applies.

# Arguments

- `record::ISPSourceRecord`: record to test.
- `band::Int`: band to select.
- `horizon_start::Date`: date the record must be valid at.
- `matched::Set{String}`: object ids of the matched timeslices.

# Returns

- `Bool`.
"""
function _applies(record::ISPSourceRecord, band::Int, horizon_start::Date, matched::Set{String})::Bool
    ismissing(record.value) && return false
    record.band == band || return false
    at = DateTime(horizon_start)
    !ismissing(record.date_from) && record.date_from > at && return false
    !ismissing(record.date_to) && record.date_to < at && return false
    isempty(record.tags) && return true
    return any(tag -> tag.object_id in matched, record.tags)
end

"""
    _precedence_key(record::ISPSourceRecord)::Tuple

Sort key under which the smallest key is the winning record among applicable records.

A tagged record is timeslice-matched and ranks first, then a dated record ranks by latest `date_from` with undated records last, then the smallest `data_id` breaks ties.

# Arguments

- `record::ISPSourceRecord`: an applicable record.

# Returns

- `Tuple`: the sort key.
"""
function _precedence_key(record::ISPSourceRecord)::Tuple
    untagged = isempty(record.tags) ? 1 : 0
    undated = ismissing(record.date_from) ? 1 : 0
    later = ismissing(record.date_from) ? 0 : -Dates.value(record.date_from)
    return (untagged, undated, later, _data_id_order(record.data_id))
end

"""
    _data_id_order(data_id::AbstractString)::Tuple{Int,String}

Order a data id numerically when it is an integer, so that `"9"` precedes `"10"`.

# Arguments

- `data_id::AbstractString`: PLEXOS data id.

# Returns

- `Tuple{Int,String}`: the sort key.
"""
function _data_id_order(data_id::AbstractString)::Tuple{Int, String}
    return (something(tryparse(Int, data_id), typemax(Int)), String(data_id))
end

"""
    _resolve_object(records, default, matched::Set{String}, horizon_start::Date, band::Int)

Resolve one object's value from its records of one property, falling back to `default`.

# Arguments

- `records`: records of the property for the object.
- `default`: the property default, `missing` when none is declared.
- `matched::Set{String}`: object ids of the matched timeslices.
- `horizon_start::Date`: date the value is resolved at.
- `band::Int`: band to select.

# Returns

- `NamedTuple` with the fields `value`, `data_id` (`missing` when the default was used) and `is_default`.
"""
function _resolve_object(records, default, matched::Set{String}, horizon_start::Date, band::Int)
    applicable = [record for record in records if _applies(record, band, horizon_start, matched)]
    isempty(applicable) && return (value = default, data_id = missing, is_default = true)
    winner = first(sort(applicable; by = _precedence_key))
    return (value = winner.value, data_id = winner.data_id, is_default = false)
end

"""
    _self_named_month(name::AbstractString)::Union{Int,Nothing}

Parse a timeslice's own name as a single-month form `"M<1-12>"`, for example `"M7"` gives `7`.

# Arguments

- `name::AbstractString`: the timeslice name.

# Returns

- `Union{Int,Nothing}`: the month, or `nothing` when the name is not of that form.
"""
function _self_named_month(name::AbstractString)::Union{Int, Nothing}
    m = match(r"^M(\d{1,2})$", name)
    m === nothing && return nothing
    n = parse(Int, m.captures[1])
    return 1 <= n <= 12 ? n : nothing
end

"""
    _month_expression_matches(expression::AbstractString, month::Integer)::Bool

Test whether a timeslice `Include` expression contains `month`.

Only the form `"M<item>[,<item>...]"` is understood, where each item is a single month or an inclusive range such as `"4-10"`. Any other expression, including a blank one, returns `false`.

# Arguments

- `expression::AbstractString`: the stored `Include` text.
- `month::Integer`: calendar month, from 1 to 12.

# Returns

- `Bool`.
"""
function _month_expression_matches(expression::AbstractString, month::Integer)::Bool
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
