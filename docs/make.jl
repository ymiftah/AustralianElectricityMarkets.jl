using AustralianElectricityMarkets
using Documenter
using DocumenterVitepress
using Literate
using CairoMakie

DocMeta.setdocmeta!(
    AustralianElectricityMarkets,
    :DocTestSetup,
    :(using AustralianElectricityMarkets);
    recursive = true,
)

## All example pages plot with CairoMakie in the same process (see the Literate loop
## below); setting the theme once here, before any of them run, applies it to every chart.
set_theme!(theme_dark())

## Generate Literate examples
for name in ["nem", "fcas", "build_system", "economic_dispatch", "market_bids", "interchanges", "clearing-with-batteries"]
    Literate.markdown(
        joinpath(@__DIR__, "literate", "$name.jl"),
        joinpath(@__DIR__, "src", "examples");
        execute = true,
        credit = false,
    )
end

makedocs(;
    modules = [
        AustralianElectricityMarkets,
        AustralianElectricityMarkets.RegionModel,
        AustralianElectricityMarkets.BidTypeModule,
    ],
    authors = "Youssef Miftah <miftahyo@outlook.fr> and contributors",
    repo = "https://github.com/ymiftah/AustralianElectricityMarkets.jl/blob/{commit}{path}#{line}",
    sitename = "AustralianElectricityMarkets.jl",
    source = "src",
    build = "build",
    format = DocumenterVitepress.MarkdownVitepress(
        repo = "https://github.com/ymiftah/AustralianElectricityMarkets.jl",
        devbranch = "main",
        devurl = "dev",
        # md_output_path = ".",  # for local test
        # build_vitepress = false  # for local test
    ),
    pages = [
        "Home" => "index.md",
        "Explanation" => [
            "The National Electricity Market" => "examples/nem.md",
            "FCAS in the NEM" => "examples/fcas.md",
        ],
        "How-to" => [
            "Gather data" => "examples/gather_data.md",
            "Build the system" => "examples/build_system.md",
            "Economic dispatch" => "examples/economic_dispatch.md",
            "Market clearing" => "examples/market_bids.md",
            "Market clearing with interchanges" => "examples/interchanges.md",
            "Market clearing with batteries" => "examples/clearing-with-batteries.md",
        ],
        "Roadmap" => "roadmap.md",
        "Reference" => "95-reference.md",
    ],
    checkdocs = :none,
    # clean = false, # for local test
)

DocumenterVitepress.deploydocs(;
    repo = "github.com/ymiftah/AustralianElectricityMarkets.jl",
    target = "build",
    push_preview = true,
    devbranch = "main",
    branch = "gh-pages",
)
