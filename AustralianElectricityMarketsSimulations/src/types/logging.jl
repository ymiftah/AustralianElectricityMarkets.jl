# Drops PSI's per-container "resulted in a MILP" warning, emitted once per dual container.
struct _DropMILPWarning <: Base.CoreLogging.AbstractLogger
    inner::Base.CoreLogging.AbstractLogger
end

_DropMILPWarning() = _DropMILPWarning(Base.CoreLogging.current_logger())

Base.CoreLogging.min_enabled_level(l::_DropMILPWarning) = Base.CoreLogging.min_enabled_level(l.inner)

Base.CoreLogging.shouldlog(l::_DropMILPWarning, args...) = Base.CoreLogging.shouldlog(l.inner, args...)

Base.CoreLogging.catch_exceptions(l::_DropMILPWarning) = Base.CoreLogging.catch_exceptions(l.inner)

function Base.CoreLogging.handle_message(l::_DropMILPWarning, level, message, args...; kwargs...)
    occursin("resulted in a MILP", string(message)) && return nothing
    return Base.CoreLogging.handle_message(l.inner, level, message, args...; kwargs...)
end
