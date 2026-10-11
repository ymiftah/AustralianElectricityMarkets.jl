using AustralianElectricityMarkets
using AustralianElectricityMarketsData
using AustralianElectricityMarketsCache
using Documenter
using DocumenterVitepress
using Literate
using CairoMakie

include(joinpath(@__DIR__, "literate", "inline_source.jl"))

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
for name in ["nem", "fcas", "nemde_model", "nemde_jump", "nemde_psi", "nemde_aem", "build_system", "economic_dispatch", "market_bids", "interchanges", "clearing-with-batteries"]
    Literate.markdown(
        joinpath(@__DIR__, "literate", "$name.jl"),
        joinpath(@__DIR__, "src", "examples");
        execute = true,
        credit = false,
        preprocess = inline_toy_source,
    )
end

makedocs(;
    modules = [
        AustralianElectricityMarkets,
        AustralianElectricityMarkets.Readers,
        AustralianElectricityMarketsData,
        AustralianElectricityMarketsCache,
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
            "The National Electricity Market" => [
                "Overview" => "examples/nem.md",
                "FCAS in the NEM" => "examples/fcas.md",
            ],
            "Introduction to PowerSimulations.jl" => [
                "NEMDE as a JuMP model" => "examples/nemde_jump.md",
                "From JuMP to PowerSimulations.jl" => "examples/nemde_psi.md",
                "Building it with AEM and AEMSim" => "examples/nemde_aem.md",
            ],
        ],
        "How-to" => [
            "Gather data" => "examples/gather_data.md",
            "Build the system" => "examples/build_system.md",
            "Economic dispatch" => "examples/economic_dispatch.md",
            "Dispatch replay" => "dispatch_replay.md",
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
