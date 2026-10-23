# Turns a checkout into what a registry user resolves: drops [sources], the root [workspace] and all manifests.
import TOML

function _strip_project!(path::AbstractString, root::AbstractString)
    data = TOML.parsefile(path)
    changed = delete!(data, "sources") !== nothing
    if path == joinpath(root, "Project.toml") && haskey(data, "workspace")
        delete!(data, "workspace")
        changed = true
    end
    if changed
        open(io -> TOML.print(io, data), path, "w")
        println("edited ", relpath(path, root))
    end
    return nothing
end

function _is_manifest(name::AbstractString)
    return name == "Manifest.toml" || (startswith(name, "Manifest-v") && endswith(name, ".toml"))
end

function registered_mode(root::AbstractString)
    for (dir, dirs, files) in walkdir(root)
        filter!(!=(".git"), dirs)
        for file in files
            path = joinpath(dir, file)
            if file in ("Project.toml", "JuliaProject.toml")
                _strip_project!(path, root)
            elseif _is_manifest(file)
                rm(path)
                println("deleted ", relpath(path, root))
            end
        end
    end
    return nothing
end

registered_mode(abspath(isempty(ARGS) ? pwd() : ARGS[1]))
