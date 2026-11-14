"""
    MissingDataError

Exception raised when NEMWEB genuinely does not publish the requested data - an
HTTP 404 under every known URL pattern.
"""
struct MissingDataError <: Exception
    msg::String
end


"""
    TransientDownloadError

Exception raised when a NEMWEB download fails for a reason that says nothing about whether
the data exists - rate limiting (403/429), a server error (5xx), or a connection-level
failure - and still fails after [`_DOWNLOAD_MAX_ATTEMPTS`](@ref) attempts with backoff.
Bulk-populating a wide date range trips NEMWEB's rate limiter easily, particularly on small tables.
"""
struct TransientDownloadError <: Exception
    msg::String
end


"""
    ISPReleaseError

Exception raised when the ISP archives on disk or at AEMO cannot be reconciled with the built-in
release record: a file's SHA-256 does not match, or an archive cannot be obtained at all.
"""
struct ISPReleaseError <: Exception
    msg::String
end

Base.showerror(io::IO, e::ISPReleaseError) = return print(io, e.msg)
