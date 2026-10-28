# ── Pre-2015 monthly archives ────────────────────────────────────────────────

"First month for which NEMWEB hosts an MMSDM monthly archive."
const LEGACY_ARCHIVE_FIRST_MONTH = Date(2009, 7, 1)

"Last month published only as a monolithic archive; from 2015-01 NEMWEB hosts one ZIP per table."
const LEGACY_ARCHIVE_LAST_MONTH = Date(2014, 12, 1)

"Tables that define generic constraints: the definition row and its LHS terms."
const CONSTRAINT_DEFINITION_TABLES = [
    :GENCONDATA, :SPDREGIONCONSTRAINT, :SPDINTERCONNECTORCONSTRAINT, :SPDCONNECTIONPOINTCONSTRAINT,
]

const NEMWEB_MONTHLY_ARCHIVE_URL = "https://nemweb.com.au/Data_Archive/Wholesale_Electricity/MMSDM/{year}/MMSDM_{year}_{month:02d}.zip"

"Bytes fetched per range request when reading a remote archive."
const _REMOTE_BLOCK_BYTES = 1 << 20


"""
    _RemoteBytes(fetch_range, length) <: AbstractVector{UInt8}

Read-only byte vector over a remote file, fetched lazily in [`_REMOTE_BLOCK_BYTES`](@ref) blocks.
`fetch_range(lo, hi)` returns bytes `lo:hi` (zero-based, inclusive). Lets `ZipArchives.ZipReader`
read a ZIP's central directory and single entries without downloading the whole file.
"""
mutable struct _RemoteBytes{F} <: AbstractVector{UInt8}
    fetch_range::F
    length::Int
    blocks::Dict{Int, Vector{UInt8}}
end

_RemoteBytes(fetch_range, length::Integer) = _RemoteBytes(fetch_range, Int(length), Dict{Int, Vector{UInt8}}())

Base.size(v::_RemoteBytes) = (v.length,)
Base.IndexStyle(::Type{<:_RemoteBytes}) = IndexLinear()

function Base.getindex(v::_RemoteBytes, i::Int)
    @boundscheck checkbounds(v, i)
    block = (i - 1) ÷ _REMOTE_BLOCK_BYTES
    bytes = get!(v.blocks, block) do
        lo = block * _REMOTE_BLOCK_BYTES
        return v.fetch_range(lo, min(lo + _REMOTE_BLOCK_BYTES, v.length) - 1)
    end
    return bytes[(i - 1) % _REMOTE_BLOCK_BYTES + 1]
end


"""
    _open_monthly_archive(year::Int, month::Int) -> _RemoteBytes

Open the monolithic MMSDM archive `MMSDM_<year>_<month>.zip` for range reads. Throws
[`MissingDataError`](@ref) when NEMWEB does not host it.
"""
function _open_monthly_archive(year::Int, month::Int)
    url = replace(
        NEMWEB_MONTHLY_ARCHIVE_URL,
        "{year}" => year, "{month:02d}" => lpad(month, 2, '0'),
    )
    fetch_range(lo, hi) = _fetch_with_retry(url; headers = ["Range" => "bytes=$lo-$hi"], ok = (206,)).body
    probe = _fetch_with_retry(url; headers = ["Range" => "bytes=0-0"], ok = (206,))
    total = parse(Int, last(split(HTTP.header(probe, "Content-Range"), '/')))
    return _RemoteBytes(fetch_range, total)
end


"""
    _get_legacy_archive(table_name::String, year::Int, month::Int; open_archive = _open_monthly_archive) -> Vector{String}

Extract `table_name`'s `PUBLIC_DVD_<table>_<yyyymm>010000.zip` from the month's monolithic archive
into a temporary file, reading only that entry. Returns its path (caller deletes it). Throws
[`MissingDataError`](@ref) when the archive has no entry for the table.
"""
function _get_legacy_archive(
        table_name::String, year::Int, month::Int;
        open_archive = _open_monthly_archive,
    )::Vector{String}
    reader = ZipReader(open_archive(year, month))
    member = "PUBLIC_DVD_$(table_name)_$(year)$(lpad(month, 2, '0'))010000.zip"
    entry = findfirst(e -> basename(e) == member, zip_names(reader))
    isnothing(entry) && throw(
        MissingDataError("$member is not in the MMSDM_$(year)_$(lpad(month, 2, '0')).zip archive")
    )
    tmp_zip = tempname(_local_tmp_dir()) * ".zip"
    write(tmp_zip, zip_readentry(reader, zip_names(reader)[entry]))
    return [tmp_zip]
end


"""
    populate_legacy_archive(db::AEMDB, table_name::Symbol, start_date::Date, end_date::Date; force_new::Bool=false)
    populate_legacy_archive(db::AEMDB; tables=CONSTRAINT_DEFINITION_TABLES, start_date=Date(2009, 7, 1),
                            end_date=Date(2014, 12, 1), force_new::Bool=false)

Populate the Hive cache for months before 2015, when NEMWEB hosts only one monolithic
`MMSDM_<yyyy>_<mm>.zip` per month (1.5 to 2.2 GB) instead of one ZIP per table. Each requested table's
entry is read with HTTP range requests, so a month costs a few MB instead of the full archive, then written
through the same pipeline as [`populate`](@ref). Months already cached are skipped.

Use case: generic-constraint definitions. `GENCONDATA` and the `SPD*CONSTRAINT` term tables are
effective-dated, and a monthly archive carries only the versions that became effective that month. A constraint
last revised before 2015 (for example `N_NIL_TE_B`, effective 2012-07-04, or the Murraylink and Basslink
`*_ZERO` constraints, effective 2013-08-21) is still invoked in `DISPATCHCONSTRAINT` today, but its definition
appears only in a pre-2015 archive, so a cache populated from 2015-01 reports it as having no definition.
The default tables are the four that define constraints.

# Arguments
- `db::AEMDB`: the cache connection.
- `table_name::Symbol` / `tables`: tables to populate; each needs a `PUBLIC_DVD_<table>` entry in the archive.
- `start_date`, `end_date`: first and last month to fetch, within 2009-07 to 2014-12.
- `force_new`: re-fetch months already cached.

# Example
```julia
db = aem_connect()
populate_legacy_archive(db)                                   # constraint definitions, 2009-07 to 2014-12
populate_legacy_archive(db, :GENCONDATA, Date(2013, 8, 1), Date(2013, 8, 1))
```
"""
function populate_legacy_archive(
        db::AEMDB, table_name::Symbol, start_date::Date, end_date::Date;
        force_new::Bool = false,
    )
    if start_date < LEGACY_ARCHIVE_FIRST_MONTH || end_date > LEGACY_ARCHIVE_LAST_MONTH
        throw(
            ArgumentError(
                "populate_legacy_archive covers $(LEGACY_ARCHIVE_FIRST_MONTH) to $(LEGACY_ARCHIVE_LAST_MONTH); " *
                    "use `populate` from 2015-01"
            )
        )
    end
    source = get_table(db, table_name)
    return populate(source, start_date:Month(1):end_date; force_new, fetch_archive = _get_legacy_archive)
end

function populate_legacy_archive(
        db::AEMDB; tables::Vector{Symbol} = CONSTRAINT_DEFINITION_TABLES,
        start_date::Date = LEGACY_ARCHIVE_FIRST_MONTH, end_date::Date = LEGACY_ARCHIVE_LAST_MONTH,
        force_new::Bool = false,
    )
    for table_name in tables
        populate_legacy_archive(db, table_name, start_date, end_date; force_new)
    end
    return
end
