"""
    MissingDataError

Exception raised when NEMWEB does not publish the requested data (HTTP 404 under every
known URL pattern).
"""
struct MissingDataError <: Exception
    msg::String
end


"""
    TransientDownloadError

Exception raised when a NEMWEB download still fails after [`_DOWNLOAD_MAX_ATTEMPTS`](@ref)
attempts with backoff on rate limiting (403/429), a server error (5xx) or a connection failure.
"""
struct TransientDownloadError <: Exception
    msg::String
end
