using AustralianElectricityMarket
using Documenter

DocMeta.setdocmeta!(AustralianElectricityMarket, :DocTestSetup, :(using AustralianElectricityMarket); recursive=true)

makedocs(;
    modules=[AustralianElectricityMarket],
    authors="Youssef Miftah <miftahyo@outlook.fr> and contributors",
    sitename="AustralianElectricityMarket.jl",
    format=Documenter.HTML(;
        canonical="https://ymiftah.github.io/AustralianElectricityMarket.jl",
        edit_link="main",
        assets=String[],
    ),
    pages=[
        "Home" => "index.md",
    ],
)

deploydocs(;
    repo="github.com/ymiftah/AustralianElectricityMarket.jl",
    devbranch="main",
)
