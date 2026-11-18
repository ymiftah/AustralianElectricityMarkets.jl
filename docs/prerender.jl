## Render frozen how-to pages locally, against the full NEMWEB cache, into `docs/frozen/`.
## Usage: julia --project=docs docs/prerender.jl [page...]   (no pages renders all FROZEN_PAGES)

using AustralianElectricityMarkets
using AustralianElectricityMarketsData
using AustralianElectricityMarketsCache
using AustralianElectricityMarketsSimulations
using Documenter
using DocumenterVitepress
using Literate
using CairoMakie

include(joinpath(@__DIR__, "literate", "shared", "inline_source.jl"))
include(joinpath(@__DIR__, "frozen_pages.jl"))

set_theme!(theme_dark())
CairoMakie.activate!(type = "image/png")

## Drop the log blocks Julia prints while a page runs: they carry machine-local paths.
function strip_log_blocks(content::AbstractString)
    kept = String[]
    skipping = false
    for line in split(content, '\n'; keepempty = true)
        if any(p -> startswith(line, p), ("┌ Warning", "┌ Info", "┌ Error"))
            skipping = true
        end
        skipping || push!(kept, line)
        if skipping && startswith(line, "└ ")
            skipping = false
        end
    end
    return join(kept, '\n')
end

pages = isempty(ARGS) ? FROZEN_PAGES : ARGS
for name in pages
    name in FROZEN_PAGES || error("$name is not a frozen page; choose from $(join(FROZEN_PAGES, ", "))")
end

mkpath(FROZEN_DIR)
examples = joinpath(@__DIR__, "src", "examples")
mkpath(examples)
for name in pages
    Literate.markdown(
        joinpath(@__DIR__, "literate", "howto", "$name.jl"),
        examples;
        execute = true,
        credit = false,
        preprocess = inline_toy_source,
        postprocess = strip_log_blocks,
    )
    content = read(joinpath(examples, "$name.md"), String)
    for f in readdir(FROZEN_DIR)
        _is_page_file(f, name) && rm(joinpath(FROZEN_DIR, f))
    end
    write(joinpath(FROZEN_DIR, "$name.md"), frozen_stamp(name) * "\n" * content)
    for f in readdir(examples)
        _is_page_file(f, name) && f != "$name.md" && mv(joinpath(examples, f), joinpath(FROZEN_DIR, f); force = true)
    end
    rm(joinpath(examples, "$name.md"))
    println("$name: $(round(filesize(joinpath(FROZEN_DIR, "$name.md")) / 1024; digits = 1)) KB")
end
