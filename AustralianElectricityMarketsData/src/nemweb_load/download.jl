# ── HTTP fetch — download and cache a NEMWEB archive ZIP ─────────────────────

"""
    _get_archive(table_name::String, year::Int, month::Int; download! = _download_and_cache) -> Vector{String}

Download and cache the NEMWEB archive ZIP file(s) for one month. When the `PUBLIC_DVD_...`
URL returns 404, fetches the numbered `PUBLIC_ARCHIVE#...#FILEnn#...` parts until one returns 404.

# Arguments
- `table_name::String`: Name of the NEMWEB table
- `year::Int`: Year to download
- `month::Int`: Month to download

# Returns
- `Vector{String}`: Paths to the downloaded ZIP file(s), in part order (caller is
  responsible for deletion)
"""
function _get_archive(
        table_name::String, year::Int, month::Int;
        download! = _download_and_cache,
    )::Vector{String}
    url = replace(
        NEMWEB_URL,
        "{year}" => year,
        "{month:02d}" => lpad(month, 2, '0'),
        "{table}" => table_name
    )

    # Only a 404 (MissingDataError) justifies trying the other naming pattern - AEMO uses
    # PUBLIC_DVD for some months and the numbered PUBLIC_ARCHIVE#...#FILEnn# pattern for
    # others. A TransientDownloadError propagates immediately instead: when NEMWEB is
    # rate-limiting us, retrying a second URL only adds load, and the retry/backoff already
    # happened inside _download_and_cache.
    tmp_zip = tempname(_local_tmp_dir()) * ".zip"
    try
        @info "Downloading from primary URL" url
        download!(url, tmp_zip)
        return [tmp_zip]
    catch e
        e isa MissingDataError || rethrow()
    end

    zip_paths = String[]
    for part in Iterators.countfrom(1)
        url_alt = replace(
            NEMWEB_URL_ALT,
            "{year}" => year,
            "{month:02d}" => lpad(month, 2, '0'),
            "{table}" => table_name,
            "{part:02d}" => lpad(part, 2, '0'),
        )
        part_zip = tempname(_local_tmp_dir()) * ".zip"
        try
            @info "Downloading from alternative URL" url_alt part
            download!(url_alt, part_zip)
        catch e2
            rm(part_zip; force = true)
            if e2 isa MissingDataError
                part > 1 && break
                foreach(p -> rm(p; force = true), zip_paths)
                throw(
                    MissingDataError(
                        "Requested data for table: $table_name, year: $year, month: $month\n" *
                            "returned HTTP 404 under both known URL patterns, so AEMO does not publish it.\n" *
                            "Check http://nemweb.com.au/#mms-data-model to confirm availability."
                    )
                )
            end
            foreach(p -> rm(p; force = true), zip_paths)
            rethrow()
        end
        push!(zip_paths, part_zip)
    end

    return zip_paths
end


"Maximum attempts per URL before giving up with a [`TransientDownloadError`](@ref)."
const _DOWNLOAD_MAX_ATTEMPTS = 5

"Base seconds for the exponential backoff between download attempts."
const _DOWNLOAD_BASE_DELAY_S = 2.0

"""
Seconds without data before a download is abandoned as transient.
"""
const _DOWNLOAD_READ_TIMEOUT_S = 300

"Seconds to wait for the TCP connection itself."
const _DOWNLOAD_CONNECT_TIMEOUT_S = 30


"""
    _is_transient_status(status::Integer) -> Bool

Whether an HTTP status is retryable: `403` (NEMWEB rate limiting), `408`, `425`, `429` and
`500`, `502`, `503`, `504`.
"""
_is_transient_status(status::Integer) =
    status in (403, 408, 425, 429, 500, 502, 503, 504)


"""
    _fetch_with_retry(url::String; headers = Pair{String, String}[], ok = (200,),
                      dest = nothing, http_get = HTTP.get) -> HTTP.Response

GET `url`, retrying transient failures with exponential backoff.

Throws [`MissingDataError`](@ref) on a non-transient status outside `ok` (404 included), or
[`TransientDownloadError`](@ref) if a transient failure ([`_is_transient_status`](@ref))
persists across [`_DOWNLOAD_MAX_ATTEMPTS`](@ref) attempts.

# Arguments
- `url::String`: URL to fetch.
- `headers`: Request headers.
- `ok`: Statuses that count as success.
- `dest`: When a path, the body is streamed to it, truncated at the start of every attempt,
  instead of being buffered in the response. The file is left in place only on success.
- `http_get`: The request function.

# Returns
- `HTTP.Response`: The successful response; its body is empty when `dest` is set.
"""
function _fetch_with_retry(
        url::String; headers = Pair{String, String}[], ok = (200,),
        dest::Union{Nothing, String} = nothing, http_get = HTTP.get,
    )
    last_reason = "unknown"
    for attempt in 1:_DOWNLOAD_MAX_ATTEMPTS
        transient = false
        response = nothing
        try
            # status_exception=false so a non-2xx comes back as a response to classify
            # rather than an exception; retry=false so backoff stays in one place here.
            # The timeouts turn a wedged socket into a retryable failure instead of an
            # indefinite hang (see _DOWNLOAD_READ_TIMEOUT_S).
            options = (
                headers, status_exception = false, retry = false,
                readtimeout = _DOWNLOAD_READ_TIMEOUT_S,
                connect_timeout = _DOWNLOAD_CONNECT_TIMEOUT_S,
            )
            response = if isnothing(dest)
                http_get(url; options...)
            else
                open(dest, "w") do io
                    http_get(url; options..., response_stream = io)
                end
            end
        catch e
            # Connection-level failure (DNS, reset, timeout) - no status to classify, and
            # transient by nature.
            (e isa HTTP.Exceptions.HTTPError || e isa Base.IOError) || rethrow()
            transient = true
            last_reason = sprint(showerror, e)
        end

        if !isnothing(response)
            if response.status in ok
                return response
            elseif _is_transient_status(response.status)
                transient = true
                last_reason = "HTTP $(response.status)"
            else
                throw(MissingDataError("HTTP $(response.status): Unable to download from $url"))
            end
        end

        if transient && attempt < _DOWNLOAD_MAX_ATTEMPTS
            delay = _DOWNLOAD_BASE_DELAY_S * 2.0^(attempt - 1)
            @warn "Transient download failure; retrying" url reason = last_reason attempt delay_s = delay
            sleep(delay)
        end
    end
    return throw(
        TransientDownloadError(
            "$last_reason after $_DOWNLOAD_MAX_ATTEMPTS attempts: $url\n" *
                "NEMWEB is likely rate-limiting. This is NOT a missing month - re-run to gap-fill."
        )
    )
end


"""
    _download_and_cache(url::String, cache_path::String; http_get = HTTP.get) -> Nothing

Stream `url` to `cache_path` through [`_fetch_with_retry`](@ref), without holding the body in
memory. A failed download leaves no file at `cache_path`.

# Arguments
- `url::String`: URL to download.
- `cache_path::String`: Destination file; its directory is created.
- `http_get`: The request function.

# Returns
- `Nothing`.
"""
function _download_and_cache(url::String, cache_path::String; http_get = HTTP.get)
    mkpath(dirname(cache_path))
    try
        _fetch_with_retry(url; dest = cache_path, http_get)
    catch
        rm(cache_path; force = true)
        rethrow()
    end
    return
end
