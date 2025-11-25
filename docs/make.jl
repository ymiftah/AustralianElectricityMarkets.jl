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
        size_threshold_warn = 200 * 2^10, # raise slightly from 100 to 200 KiB
        size_threshold = 500 * 2^10,      # raise slightly 200 to to 300 KiB
    ),
    pages = [
        "Home" => "index.md",
        "Getting started" => [
            "Explore the NEM" => "examples/build_system.md",
        ],
    ],

)

deploydocs(; repo = "github.com/ymiftah/AustralianElectricityMarkets.jl", devbranch = "main")
