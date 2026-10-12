function Base.show(io::IO, db::AEMDB)
    return print(io, "AEMDB(hive_location=\"$(db.config.hive_location)\", filesystem=\"$(get_filesystem(db.config))\")")
end


function Base.show(io::IO, ::MIME"text/plain", db::AEMDB)
    println(io, "AEMDB")
    println(io, "  hive_location: ", db.config.hive_location)
    println(io, "  filesystem: ", get_filesystem(db.config))
    println(io, "  tables:")

    rows = map(list_available_tables()) do name
        source = get_table(db, Symbol(name))
        range = cached_date_range(source)
        coverage = range === nothing ? "(not cached)" : "$(range[1]) … $(range[2])"
        (name, coverage)
    end

    name_width = maximum(length(r[1]) for r in rows)
    for (name, coverage) in rows
        println(io, "    ", rpad(name, name_width), "  ", coverage)
    end
    return
end
