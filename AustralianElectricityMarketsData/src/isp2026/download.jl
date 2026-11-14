# ── ISP archive acquisition ──────────────────────────────────────────────────

"""
    isp_archives_dir(config::HiveConfiguration, release::ISPRelease = ISP_RELEASE_2026) -> String

Directory holding the archives of `release`, `<hive_location>/ISP/<year>/archives`.
"""
function isp_archives_dir(
        config::HiveConfiguration, release::ISPRelease = ISP_RELEASE_2026
    )::String
    islocal(config) || throw(
        ArgumentError(
            "ISP archives are downloaded files and are only supported on the local filesystem; " *
                "got filesystem = $(config.filesystem)."
        )
    )
    return joinpath(config.hive_location, "ISP", string(year(release.page_date)), "archives")
end

"""
    _isp_sha256(path::AbstractString) -> String

Lowercase hex SHA-256 of the file at `path`.
"""
function _isp_sha256(path::AbstractString)::String
    return bytes2hex(open(sha256, path))
end

"""
    _isp_matches(path::AbstractString, archive::ISPArchive) -> Bool

Whether the file at `path` is exactly the published `archive`.
"""
function _isp_matches(path::AbstractString, archive::ISPArchive)::Bool
    filesize(path) == archive.bytes || return false
    return _isp_sha256(path) == archive.sha256
end

"""
    _find_isp_archive(dir::AbstractString, archive::ISPArchive) -> Union{Nothing, String}

Find `archive` in `dir` by content, so a browser's suggested filename does not matter.
"""
function _find_isp_archive(dir::AbstractString, archive::ISPArchive)::Union{Nothing, String}
    isdir(dir) || return nothing
    for name in readdir(dir)
        path = joinpath(dir, name)
        isfile(path) || continue
        _isp_matches(path, archive) && return path
    end
    return nothing
end

"""
    _check_named_isp_archive(dir::AbstractString, archive::ISPArchive) -> Union{Nothing, String}

Return `dir`'s copy of `archive` if it carries the canonical filename, throwing
[`ISPReleaseError`](@ref) when that file's bytes are not the published archive. A file under
another name is left alone: it may belong to a different release.
"""
function _check_named_isp_archive(dir::AbstractString, archive::ISPArchive)::Union{Nothing, String}
    path = joinpath(dir, archive.filename)
    isfile(path) || return nothing
    actual = _isp_sha256(path)
    actual == archive.sha256 && return path
    throw(
        ISPReleaseError(
            "$path does not match the release record for $(archive.filename): " *
                "expected sha256 $(archive.sha256), got $actual.\n" *
                "The file was left in place. Delete it and re-download the archive."
        )
    )
end

"""
    _copy_isp_archive(source::AbstractString, target::AbstractString)

Copy `source` to `target` through a staging file, so `target` never holds a partial archive.
"""
function _copy_isp_archive(source::AbstractString, target::AbstractString)
    staging = target * ".part"
    cp(source, staging; force = true)
    return mv(staging, target; force = true)
end

"""
    _download_isp_archive(url::String, path::String)

Download `url` to `path` through [`_fetch_with_retry`](@ref), making one attempt only: AEMO
answers a non-browser request with a bot challenge, which retrying cannot get past.
"""
function _download_isp_archive(url::String, path::String)
    response = _fetch_with_retry(url; max_attempts = 1)
    mkpath(dirname(path))
    return write(path, response.body)
end

"""
    _isp_missing_message(release::ISPRelease, missing, dest_dir::String) -> String

Build the single error listing every archive that could not be obtained.
"""
function _isp_missing_message(release::ISPRelease, missing, dest_dir::String)::String
    lines = String[
        "Cannot obtain $(length(missing)) of $(length(release.archives)) archives for " *
            "$(release.name) (published $(release.page_date)).",
        "",
        "Download each missing file in a browser, unchanged, into:",
        "    $dest_dir",
        "",
    ]
    for (archive, reason) in missing
        push!(lines, "  $(archive.filename)")
        push!(lines, "    browser url: $(archive.url)")
        push!(lines, "    reason:      $reason")
        push!(lines, "")
    end
    push!(
        lines,
        "AEMO refuses requests that do not come from a browser, and other failures (a full disk, " *
            "a proxy) appear in the reason above. Archives are matched by SHA-256, so a browser's " *
            "suggested filename is fine."
    )
    return join(lines, "\n")
end

"""
    acquire_isp_archives(config::HiveConfiguration, source_dir::AbstractString;
        release = ISP_RELEASE_2026, download! = _download_isp_archive) -> Dict{Symbol, String}

Obtain every archive of `release`, returning the path of each under
[`isp_archives_dir`](@ref).

Archives already in the cache directory, or in `source_dir` (typically a browser's Downloads
folder), are matched by SHA-256 rather than filename and copied to their canonical names. Only
archives present in neither place are requested over HTTP. A refusal, or downloaded bytes that
fail the release hash, is collected across every archive and raised once as an
[`ISPReleaseError`](@ref) listing each browser URL and the destination directory.

# Arguments
- `config`: cache configuration; the release must be on the local filesystem.
- `source_dir`: directory to scan for already-downloaded archives.
- `release`: release record, [`ISP_RELEASE_2026`](@ref) by default.
- `download!`: downloader taking `(url, path)`; tests substitute a stub.

# Returns
- `Dict{Symbol, String}` mapping each archive `kind` to its path in the cache directory.
"""
function acquire_isp_archives(
        config::HiveConfiguration,
        source_dir::AbstractString;
        release::ISPRelease = ISP_RELEASE_2026,
        download! = _download_isp_archive,
    )::Dict{Symbol, String}
    dest_dir = isp_archives_dir(config, release)
    mkpath(dest_dir)

    paths = Dict{Symbol, String}()
    missing = Tuple{ISPArchive, String}[]
    for archive in release.archives
        found = _check_named_isp_archive(dest_dir, archive)
        isnothing(found) && (found = _find_isp_archive(dest_dir, archive))
        if isnothing(found)
            found = _check_named_isp_archive(source_dir, archive)
            isnothing(found) && (found = _find_isp_archive(source_dir, archive))
        end

        target = joinpath(dest_dir, archive.filename)
        if !isnothing(found)
            found == target || _copy_isp_archive(found, target)
            paths[archive.kind] = target
            continue
        end

        staging = target * ".part"
        try
            @info "Downloading ISP archive" archive.kind url = archive.url
            download!(archive.url, staging)
        catch e
            rm(staging; force = true)
            e isa InterruptException && rethrow()
            push!(missing, (archive, sprint(showerror, e)))
            continue
        end

        actual = isfile(staging) ? _isp_sha256(staging) : ""
        if actual != archive.sha256
            rm(staging; force = true)
            push!(
                missing,
                (
                    archive,
                    "downloaded bytes do not match the release record: expected sha256 " *
                        "$(archive.sha256), got $(isempty(actual) ? "nothing" : actual)",
                )
            )
            continue
        end
        mv(staging, target; force = true)
        paths[archive.kind] = target
    end

    isempty(missing) || throw(ISPReleaseError(_isp_missing_message(release, missing, dest_dir)))
    return paths
end
