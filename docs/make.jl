using AustralianElectricityMarkets
using Documenter

DocMeta.setdocmeta!(
    AustralianElectricityMarkets,
    :DocTestSetup,
    :(using AustralianElectricityMarkets);
    recursive = true,
)

makedocs(;
    modules = [AustralianElectricityMarkets, AustralianElectricityMarkets.RegionModel],
    authors = "Youssef Miftah <miftahyo@outlook.fr> and contributors",
    sitename = "AustralianElectricityMarkets.jl",
    format = Documenter.HTML(;
        canonical = "https://ymiftah.github.io/AustralianElectricityMarkets.jl",
        edit_link = "main",
        assets = String[],
    ),
    pages = ["Home" => "index.md"],
)

deploydocs(; repo = "github.com/ymiftah/AustralianElectricityMarkets.jl", devbranch = "main")
