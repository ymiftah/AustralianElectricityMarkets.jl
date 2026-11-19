using SHA

include(joinpath(@__DIR__, "formulation_pages.jl"))
include(joinpath(@__DIR__, "literate", "shared", "inline_source.jl"))

## Every Literate page is frozen: `docs/prerender.jl` renders it into `FROZEN_DIR`, and
## `docs/make.jl` copies the committed output, so the docs build never runs Literate code.
const FROZEN_DIR = joinpath(@__DIR__, "frozen")
const SHARED_DIR = joinpath(@__DIR__, "literate", "shared")
const LITERATE_PAGES = [
    "formulation" => FORMULATION_PAGES,
    "overview" => ["nem"],
    "tutorials" => ["nemde_jump", "nemde_psi", "nemde_aem"],
    "howto" => [
        "build_system", "economic_dispatch", "market_bids", "interchanges", "clearing-with-batteries",
        "run_nemde", "template_energy_only", "template_interconnected", "template_losses",
        "template_fcas", "template_constraints",
    ],
]
const FROZEN_PAGES = [n for (_, ns) in LITERATE_PAGES for n in ns]

_prerender_command(name::AbstractString) = "julia --project=docs docs/prerender.jl $name"

# The `.md` page and its Literate figures (`<name>-<n>.<ext>`) of one page.
_is_page_file(f::AbstractString, name::AbstractString) = f == "$name.md" || startswith(f, "$name-")

function _page_group(name::AbstractString)
    for (group, names) in LITERATE_PAGES
        name in names && return group
    end
    error("$name is not a Literate page; choose from $(join(FROZEN_PAGES, ", "))")
end

_page_source(name::AbstractString) = joinpath(@__DIR__, "literate", _page_group(name), "$name.jl")

"""
    frozen_stamp(name) -> String

Return the first line of a frozen page: the SHA-256 of its Literate source and of the shared files it uses.

A shared file counts as used when its basename appears in the page source. `inline_source.jl` and
`toy_market.jl` also count when the page contains `#@source`. The files are hashed in sorted path order.

# Arguments

- `name`: the page name, without the `.jl` or `.md` extension.

# Returns

An HTML comment of the form `<!-- frozen source=<sha> -->`.
"""
function frozen_stamp(name::AbstractString)
    src = _page_source(name)
    text = read(src, String)
    shared = [joinpath(SHARED_DIR, f) for f in readdir(SHARED_DIR) if endswith(f, ".jl") && contains(text, splitext(f)[1])]
    contains(text, "#@source") && append!(shared, joinpath.(SHARED_DIR, ["inline_source.jl", "toy_market.jl"]))
    paths = sort(unique([src; shared]))
    src_sha = bytes2hex(SHA.sha256(reduce(vcat, read.(paths))))
    return "<!-- frozen source=$src_sha -->"
end

"""
    literate_options(name) -> NamedTuple

Return the keyword arguments that render the Literate page `name` with `Literate.markdown`.

Formulation pages write PNG figures and get their figure descriptions. The other pages keep Literate's default figure formats.

# Arguments

- `name`: the page name, one of `FROZEN_PAGES`.

# Returns

A `NamedTuple` of keyword arguments for `Literate.markdown`.
"""
function literate_options(name::AbstractString)
    options = (;
        execute = true,
        credit = false,
        preprocess = inline_toy_source,
        postprocess = name in FORMULATION_PAGES ? (content -> formulation_figure_descriptions(content, name)) : identity,
    )
    name in FORMULATION_PAGES || return options
    return merge(options, (; image_formats = [(MIME("image/png"), ".png")]))
end

"""
    copy_frozen_page(name, outdir) -> String

Copy the committed output of a frozen page into `outdir`, without its stamp line, together with its figures.

Throws when the page is missing or its source changed since it was frozen.

# Arguments

- `name`: the page name, one of `FROZEN_PAGES`.
- `outdir`: the directory that receives the page and its figures.

# Returns

The path of the written `.md` file.
"""
function copy_frozen_page(name::AbstractString, outdir::AbstractString)
    md = joinpath(FROZEN_DIR, "$name.md")
    isfile(md) || error("Frozen page $name has no rendered output at $md; render it with `$(_prerender_command(name))`.")
    content = read(md, String)
    stale = "The source of frozen page $name changed since it was frozen; re-render it with `$(_prerender_command(name))`."
    contains(content, '\n') || error(stale)
    recorded, body = split(content, '\n'; limit = 2)
    strip(recorded) == frozen_stamp(name) || error(stale)
    out = joinpath(outdir, "$name.md")
    write(out, body)
    for f in readdir(FROZEN_DIR)
        _is_page_file(f, name) && f != "$name.md" && cp(joinpath(FROZEN_DIR, f), joinpath(outdir, f); force = true)
    end
    return out
end
