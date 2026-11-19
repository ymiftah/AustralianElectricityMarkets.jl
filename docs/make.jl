using AustralianElectricityMarkets
using AustralianElectricityMarketsData
using AustralianElectricityMarketsCache
using AustralianElectricityMarketsSimulations
using Documenter
using DocumenterVitepress

include(joinpath(@__DIR__, "frozen_pages.jl"))

DocMeta.setdocmeta!(
    AustralianElectricityMarkets,
    :DocTestSetup,
    :(using AustralianElectricityMarkets);
    recursive = true,
)

foreach(name -> copy_frozen_page(name, joinpath(@__DIR__, "src", "examples")), FROZEN_PAGES)

makedocs(;
    modules = [
        AustralianElectricityMarkets,
        AustralianElectricityMarkets.Readers,
        AustralianElectricityMarketsData,
        AustralianElectricityMarketsCache,
        AustralianElectricityMarketsSimulations,
        AustralianElectricityMarkets.RegionModel,
        AustralianElectricityMarkets.NetworkConfigurations,
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
            ],
            "NEMDE formulation" => [
                "Overview" => "examples/nemde_model.md",
                "Energy bids and participants" => "examples/nemde_energy.md",
                "FCAS capability and co-optimisation" => "examples/nemde_fcas.md",
                "Interconnectors and losses" => "examples/nemde_interconnectors.md",
                "Fast-start dispatch" => "examples/nemde_fast_start.md",
                "Violations, tie-breaking and prices" => "examples/nemde_prices.md",
            ],
            "Introduction to PowerSimulations.jl" => [
                "NEMDE as a JuMP model" => "examples/nemde_jump.md",
                "From JuMP to PowerSimulations.jl" => "examples/nemde_psi.md",
                "Building it with AEM and AEMSim" => "examples/nemde_aem.md",
            ],
        ],
        "How-to" => [
            "Gather data" => "examples/gather_data.md",
            "Build a regional system" => "examples/build_system.md",
            "Economic dispatch" => "examples/economic_dispatch.md",
            "Market bids" => "examples/market_bids.md",
            "Interchanges" => "examples/interchanges.md",
            "Clearing with batteries" => "examples/clearing-with-batteries.md",
            "Run NEMDE dispatch" => "examples/run_nemde.md",
            "NEMDE templates" => ["Energy-only template" => "examples/template_energy_only.md", "Lossless interconnectors" => "examples/template_interconnected.md", "Interconnector losses" => "examples/template_losses.md", "FCAS markets" => "examples/template_fcas.md", "Generic constraints" => "examples/template_constraints.md"],
            "Batch runs and benchmark" => "batch_run.md",
        ],
        "Roadmap" => "roadmap.md",
        "Reference" => [
            "API" => "95-reference.md",
        ],
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
