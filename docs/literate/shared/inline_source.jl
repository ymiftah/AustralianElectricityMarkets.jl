# Literate `preprocess` hook: a line `#@source <tag>` in a page becomes a highlighted code block
# holding the lines of `toy_market.jl` between its `#>> <tag>` and `#<< <tag>` markers, so the
# page always shows the code that the model actually uses.

function inline_toy_source(content::AbstractString)
    lines = readlines(joinpath(@__DIR__, "toy_market.jl"))
    return replace(
        content, r"^#@source (\w+)[ \t]*$"m => function (m)
            tag = match(r"^#@source (\w+)", m).captures[1]
            first = findfirst(==("#>> $tag"), lines)
            last = findfirst(==("#<< $tag"), lines)
            body = lines[(first + 1):(last - 1)]
            return join(["# ```julia"; ["# " * l for l in body]; "# ```"], "\n")
        end
    )
end
