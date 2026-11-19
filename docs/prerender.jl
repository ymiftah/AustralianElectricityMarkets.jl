## Render Literate pages locally, against the full NEMWEB cache, into `docs/frozen/`.
## Usage: julia --project=docs docs/prerender.jl [page...]   (no pages renders all FROZEN_PAGES)

using AustralianElectricityMarkets
using AustralianElectricityMarketsData
using AustralianElectricityMarketsCache
using AustralianElectricityMarketsSimulations
using Documenter
using DocumenterVitepress
using Literate
using CairoMakie

include(joinpath(@__DIR__, "frozen_pages.jl"))

## Every page plots with CairoMakie in this process, so one theme set here, before any page runs, applies to all.
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

## DocumenterVitepress reads `$` in raw HTML output (e.g. a "price ($/MWh)" cell) as interpolation.
function escape_raw_html_dollars(content::AbstractString)
    lines = split(content, '\n'; keepempty = true)
    in_raw = false
    for (i, line) in enumerate(lines)
        if in_raw && startswith(line, "```")
            in_raw = false
        elseif in_raw
            lines[i] = replace(line, '$' => "&#36;")
        elseif startswith(line, "```@raw html")
            in_raw = true
        end
    end
    return join(lines, '\n')
end

pages = isempty(ARGS) ? FROZEN_PAGES : ARGS
for name in pages
    name in FROZEN_PAGES || error("$name is not a Literate page; choose from $(join(FROZEN_PAGES, ", "))")
end

mkpath(FROZEN_DIR)
examples = joinpath(@__DIR__, "src", "examples")
mkpath(examples)
for name in pages
    figures = literate_options(name)
    options = merge(figures, (; postprocess = content -> escape_raw_html_dollars(strip_log_blocks(figures.postprocess(content)))))
    Literate.markdown(_page_source(name), examples; options...)
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
