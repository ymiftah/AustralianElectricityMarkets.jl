using SHA

## Frozen how-to pages need the full local NEMWEB cache, so their rendered output is committed
## under `FROZEN_DIR` by `docs/prerender.jl` and copied by `docs/make.jl`.
const FROZEN_DIR = joinpath(@__DIR__, "frozen")
const FROZEN_PAGES = ["run_nemde", "template_energy_only", "template_interconnected", "template_losses", "template_fcas", "template_constraints"]

_prerender_command(name::AbstractString) = "julia --project=docs docs/prerender.jl $name"

# The `.md` page and its Literate figures (`<name>-<n>.png`) of one page.
_is_page_file(f::AbstractString, name::AbstractString) = f == "$name.md" || startswith(f, "$name-")

"""
    frozen_stamp(name) -> String

Return the first line of a frozen page: the SHA-256 of its Literate source.

# Arguments

- `name`: the page name, without the `.jl` or `.md` extension.

# Returns

An HTML comment of the form `<!-- frozen source=<sha> -->`.
"""
function frozen_stamp(name::AbstractString)
    src_sha = bytes2hex(SHA.sha256(read(joinpath(@__DIR__, "literate", "howto", "$name.jl"))))
    return "<!-- frozen source=$src_sha -->"
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
