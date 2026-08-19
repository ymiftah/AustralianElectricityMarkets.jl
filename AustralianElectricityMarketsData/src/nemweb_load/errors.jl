"""
    MissingDataError

Exception raised when NEMWEB genuinely does not publish the requested data - an
HTTP 404 under every known URL pattern. `populate` logs this and moves on, since a
month AEMO never published is not a failure.

Never used for a *transient* fetch failure: see [`TransientDownloadError`](@ref) for why
conflating the two is dangerous.
"""
struct MissingDataError <: Exception
    msg::String
end

"""
    TransientDownloadError

Exception raised when a NEMWEB download fails for a reason that says nothing about whether
the data exists - rate limiting (403/429), a server error (5xx), or a connection-level
failure - and still fails after [`_DOWNLOAD_MAX_ATTEMPTS`](@ref) attempts with backoff.

Deliberately **not** a [`MissingDataError`](@ref) and deliberately not swallowed by
`populate`. Bulk-populating a wide date range trips NEMWEB's rate limiter easily, and if a
403 were reported as "no data available" the run would appear to succeed while silently
leaving holes in the cache - indistinguishable, afterwards, from months AEMO never
published. Failing loudly means an interrupted bulk load is visible and re-runnable
(`populate` is idempotent and gap-fills).
"""
struct TransientDownloadError <: Exception
    msg::String
end
