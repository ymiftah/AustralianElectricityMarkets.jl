# The key of `device`'s `SingleTimeSeries` named `name`.
function _series_key(device, name::AbstractString)
    for key in IS.get_time_series_keys(device)
        key isa IS.StaticTimeSeriesKey && IS.get_name(key) == name && return key
    end
    throw(ArgumentError("\"$(get_name(device))\" has no SingleTimeSeries named \"$name\"."))
end
