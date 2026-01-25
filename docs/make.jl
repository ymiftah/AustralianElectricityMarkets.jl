using AustralianElectricityMarkets
using Documenter
using DocumenterVitepress

DocMeta.setdocmeta!(
    AustralianElectricityMarkets,
    :DocTestSetup,
    :(using AustralianElectricityMarkets);
    recursive = true,
)

# Add titles of sections and overrides page titles
const titles = Dict(
    "examples" => "Getting started",
    "build_system" => "Build the system",
    "economic_dispatch" => "Economic dispatch",
    "interchanges" => "Area balance with interchanges",
    "market_bids" => "Market clearing",
    "95-reference.md" => "Reference",
)

function recursively_list_pages(folder; path_prefix = "")
    pages_list = Any[]
    for file in readdir(folder)
        if file == "index.md" || file == ".vitepress"
            # We add index.md separately to make sure it is the first in the list
            continue
        end
        # this is the relative path according to our prefix, not @__DIR__, i.e., relative to `src`
        relpath = joinpath(path_prefix, file)
        # full path of the file
        fullpath = joinpath(folder, file)

        if isdir(fullpath)
            # If this is a folder, enter the recursion case
            subsection = recursively_list_pages(fullpath; path_prefix = relpath)

            # Ignore empty folders
            if length(subsection) > 0
                title = if haskey(titles, relpath)
                    titles[relpath]
                else
                    # @error "Bad usage: '$relpath' does not have a title set. Fix in 'docs/make.jl'"
                    relpath
                end
                push!(pages_list, title => subsection)
            end

            continue
        end

        if splitext(file)[2] != ".md" # non .md files are ignored
            continue
        elseif haskey(titles, relpath) # case 'title => path'
            push!(pages_list, titles[relpath] => relpath)
        else # case 'title'
            push!(pages_list, relpath)
        end
    end

    return pages_list
end

function list_pages()
    root_dir = joinpath(@__DIR__, "src")
    pages_list = recursively_list_pages(root_dir)

    return ["index.md"; pages_list]
end

makedocs(;
    modules = [AustralianElectricityMarkets],
    authors = "Youssef Miftah <miftahyo@outlook.fr> and contributors",
    repo = "https://github.com/ymiftah/AustralianElectricityMarkets.jl/blob/{commit}{path}#{line}",
    sitename = "AustralianElectricityMarkets.jl",
    source = "src",
    build = "build",
    format = DocumenterVitepress.MarkdownVitepress(
        repo = "https://github.com/ymiftah/AustralianElectricityMarkets.jl",
        devbranch = "main",
        devurl = "dev",
        # md_output_path = ".",
        # build_vitepress = false
    ),
    pages = [
        "Home" => "index.md",
        "How-to" => [
            "Gather data" => "examples/gather_data.md",
        ],
        "Tutorials" => [
            "Build the system" => "examples/build_system.md",
            "Economic dispatch" => "examples/economic_dispatch.md",
            "Area balance with interchanges" => "examples/interchanges.md",
            "Market clearing" => "examples/market_bids.md",
        ],
        "Reference" => "95-reference.md",
    ],
    warnonly = true,
    checkdocs = :none,
    # clean=false,
)

DocumenterVitepress.deploydocs(;
    repo = "github.com/ymiftah/AustralianElectricityMarkets.jl",
    target = "build",
    push_preview = true,
    devbranch = "main",
    branch = "gh-pages",
)
