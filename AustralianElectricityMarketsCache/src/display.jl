function Base.show(io::IO, db::AEMDB)
    return print(io, "AEMDB(hive_location=\"$(db.config.hive_location)\", filesystem=\"$(get_filesystem(db.config))\")")
end


function Base.show(io::IO, ::MIME"text/plain", db::AEMDB)
    println(io, "AEMDB")
    println(io, "  hive_location: ", db.config.hive_location)
    println(io, "  filesystem: ", get_filesystem(db.config))
    println(io, "  tables:")

    # One connection serves every table's partition listing on a remote filesystem.
    conn = islocal(db.config) ? nothing : _new_duckdb_connection(get_filesystem(db.config))
    rows = try
        map(list_available_tables()) do name
            source = get_table(db, Symbol(name))
            range = cached_date_range(source; conn)
            coverage = range === nothing ? "(not cached)" : "$(range[1]) … $(range[2])"
            (name, coverage)
        end
    finally
        isnothing(conn) || DBInterface.close!(conn)
    end

    name_width = maximum(length(r[1]) for r in rows)
    for (name, coverage) in rows
        println(io, "    ", rpad(name, name_width), "  ", coverage)
    end
    return
end
