using CairoMakie
using Literate

include(joinpath(@__DIR__, "formulation_pages.jl"))
set_theme!()

function formulation_review_links()
    links = Dict("nemde-jump" => "../../docs/literate/nemde_jump.jl")
    for name in FORMULATION_PAGES
        source = read(joinpath(@__DIR__, "literate", "$name.jl"), String)
        for matched in eachmatch(r"\(@id ([^)]+)\)", source)
            anchor = matched.captures[1]
            links[anchor] = "$name.md#$anchor"
        end
    end
    return links
end

function formulation_review_markdown(content, name, links)
    content = replace(content, "@reviewref" => "@ref", "@reviewid" => "@id")
    content = formulation_figure_descriptions(content, name)
    content = replace(content, r"(?<!`)``([^`]+)``(?!`)" => s"$\1$")
    content = replace(
        content, r"\[([^\]]+)\]\(@ref ([^)]+)\)" => function (matched)
            parsed = match(r"\[([^\]]+)\]\(@ref ([^)]+)\)", matched)
            return "[$(parsed.captures[1])]($(links[parsed.captures[2]]))"
        end
    )
    content = replace(
        content, r"(?m)^(#+) \[([^\]]+)\]\(@id ([^)]+)\)" => function (matched)
            parsed = match(r"^(#+) \[([^\]]+)\]\(@id ([^)]+)\)", matched)
            return "<a id=\"$(parsed.captures[3])\"></a>\n\n$(parsed.captures[1]) $(parsed.captures[2])"
        end
    )
    content = replace(content, "../interconnector-losses.md" => "interconnector-losses.md")
    return content
end

function render_formulation_review(output = joinpath(@__DIR__, "..", "docs-review", "formulation"))
    mkpath(output)
    links = formulation_review_links()
    for name in FORMULATION_PAGES
        Literate.markdown(
            joinpath(@__DIR__, "literate", "$name.jl"), output;
            preprocess = content -> replace(content, "@ref" => "@reviewref", "@id" => "@reviewid"),
            execute = true,
            flavor = Literate.CommonMarkFlavor(),
            image_formats = [(MIME("image/png"), ".png")],
            postprocess = content -> formulation_review_markdown(content, name, links),
            credit = false,
        )
    end
    loss_reference = read(joinpath(@__DIR__, "src", "interconnector-losses.md"), String)
    loss_reference = replace(loss_reference, "examples/nemde_interconnectors.md" => "nemde_interconnectors.md")
    loss_reference = replace(loss_reference, r"\[(`[^`]+`)\]\(@ref\)" => s"\1")
    write(joinpath(output, "interconnector-losses.md"), loss_reference)
    titles = [
        "Overview", "Energy bids and participants", "FCAS capability and co-optimisation",
        "Interconnectors and losses", "Fast-start dispatch", "Violations, tie-breaking and prices",
    ]
    index = "# NEMDE formulation review\n\nGenerated from Literate sources with executed CairoMakie figures.\nKnown gaps and reconstruction assumptions are labelled in notes.\n\n"
    for (name, title) in zip(FORMULATION_PAGES, titles)
        index *= "- [$title]($name.md)\n"
    end
    index *= "- [Loss inputs and assumptions](interconnector-losses.md)\n"
    write(joinpath(output, "index.md"), index)
    return output
end

render_formulation_review()
