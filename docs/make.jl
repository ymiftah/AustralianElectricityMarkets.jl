using AustralianElectricityMarkets
using Documenter
using Literate

# This code performs the automated addition of Literate - Generated Markdowns.
julia_file_filter = x -> occursin(".jl", x)
outputdir = joinpath(pwd(), "docs", "src", "examples")
files = filter(julia_file_filter, readdir(outputdir))

for file in files
    @show file
    inputfile = joinpath(outputdir, "$file")
    outputfile = replace("$file", ".jl" => "")

    Literate.markdown(
        inputfile,
        outputdir;
        name = outputfile,
        # credit = false,
        flavor = Literate.DocumenterFlavor(),
        # documenter = true,
        execute = true,
    )
end

DocMeta.setdocmeta!(
    AustralianElectricityMarkets,
    :DocTestSetup,
    :(using AustralianElectricityMarkets);
    recursive = true,
)

makedocs(;
    modules = [AustralianElectricityMarkets],
    authors = "Youssef Miftah <miftahyo@outlook.fr> and contributors",
    sitename = "AustralianElectricityMarkets.jl",
    format = Documenter.HTML(;
        canonical = "https://ymiftah.github.io/AustralianElectricityMarkets.jl",
        edit_link = "main",
        assets = String[],
    ),
    pages = [
        "Home" => "index.md",
        "Getting started" => [
            "Explore the NEM" => "examples/build_system.md",
        ],
    ],
)

deploydocs(; repo = "github.com/ymiftah/AustralianElectricityMarkets.jl", devbranch = "main")
