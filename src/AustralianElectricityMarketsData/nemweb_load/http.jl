"""
    _get_archive(table_name::String, year::Int, month::Int) -> String

Download and cache a NEMWEB data archive ZIP file. Returns path to the ZIP file.

# Arguments
- `table_name::String`: Name of the NEMWEB table
- `year::Int`: Year to download
- `month::Int`: Month to download

# Returns
- `String`: Path to the downloaded ZIP file (caller is responsible for deletion)
"""
function _get_archive(table_name::String, year::Int, month::Int)::String
    tmp_zip = tempname(_local_tmp_dir()) * ".zip"

    url = replace(
        NEMWEB_URL,
        "{year}" => year,
        "{month:02d}" => lpad(month, 2, '0'),
        "{table}" => table_name
    )
    url_alt = replace(
        NEMWEB_URL_ALT,
        "{year}" => year,
        "{month:02d}" => lpad(month, 2, '0'),
        "{table}" => table_name
    )

    try
        @info "Downloading from primary URL" url
        _download_and_cache(url, tmp_zip)
    catch e
        e isa HTTP.Exceptions.HTTPError || rethrow()
        try
            @info "Downloading from alternative URL" url_alt
            _download_and_cache(url_alt, tmp_zip)
        catch e2
            e2 isa HTTP.Exceptions.HTTPError || rethrow()
            throw(
                MissingDataError(
                    "Requested data for table: $table_name, year: $year, month: $month\n" *
                        "not downloaded. Please check your internet connection.\n" *
                        "Also check http://nemweb.com.au/#mms-data-model to see if your requested data is available."
                )
            )
        end
    end

    return tmp_zip   # return the zip path, not an extracted CSV
end

"""
    _download_and_cache(url::String, cache_path::String)

Download file from URL and save to cache.
"""
function _download_and_cache(url::String, cache_path::String)
    response = HTTP.get(url)
    if response.status != 200
        throw(MissingDataError("HTTP $(response.status): Unable to download from $url"))
    end
    mkpath(dirname(cache_path))
    return write(cache_path, response.body)
end
