"""
    MissingDataError

Exception raised when requested data is not available from NEMWEB.
"""
struct MissingDataError <: Exception
    msg::String
end
