"""
    MissingCacheError

Exception a table is missing from the cache in the requested interval.
"""
struct MissingCacheError <: Exception
    msg::String
end
