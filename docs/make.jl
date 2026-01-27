using AustralianElectricityMarkets
using Documenter
using DocumenterVitepress

DocMeta.setdocmeta!(
    AustralianElectricityMarkets,
    :DocTestSetup,
    :(using AustralianElectricityMarkets);
    recursive = true,
)

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
            "Build the system" => "examples/build_system.md",
            "Economic dispatch" => "examples/economic_dispatch.md",
            "Market clearing" => "examples/market_bids.md",
            "Market clearing with interchanges" => "examples/interchanges.md",
        ],
        "Roadmap" => "roadmap.md",
        "Reference" => "95-reference.md",
    ],
    warnonly = true,
    checkdocs = :none,
    # clean = false,
)

DocumenterVitepress.deploydocs(;
    repo = "github.com/ymiftah/AustralianElectricityMarkets.jl",
    target = "build",
    push_preview = true,
    devbranch = "main",
    branch = "gh-pages",
)
