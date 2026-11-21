# Literate sources

Sources are grouped by the topic and purpose of each page:

| Folder | Contents |
| --- | --- |
| `overview/` | Background on the National Electricity Market |
| `formulation/` | NEMDE model, energy, FCAS, interconnectors, fast-start and pricing chapters |
| `tutorials/` | Toy-market walkthroughs using JuMP, PowerSimulations.jl and AEM / AEMSim |
| `howto/` | System construction, dispatch, market clearing and NEMDE run guides |
| `shared/` | Toy-market data, reference solver and source-inlining helper used by the tutorials |

`docs/frozen_pages.jl` lists the page groups. `docs/prerender.jl` renders each page into the
frozen folder, and `docs/make.jl` copies it into the flat `docs/src/examples/` folder. Source folders
do not change the published page paths. Shared helpers are included by pages and are not rendered
as separate pages.

The three tutorials form a sequence: `nemde_jump.jl`, `nemde_psi.jl`, then `nemde_aem.jl`.
Their hidden includes resolve from the source folder during Literate execution.

To build the documentation from the repository root:

```sh
julia --project=docs docs/make.jl
```

To render just the formulation chapters and figures for local review:

```sh
julia --project=docs docs/render_formulation_review.jl
```

## Frozen pages

Every Literate page is frozen. CI never executes them: `docs/make.jl` copies the rendered Markdown
and figures from `docs/frozen/` into the examples folder. The page list, grouped by folder, is
`LITERATE_PAGES` in `docs/frozen_pages.jl`. Run `pre-commit run -a` before rendering, since a
reformatted source changes its stamp.

Render one or more pages locally with:

```sh
julia --project=docs docs/prerender.jl run_nemde template_fcas
```

With no arguments the script renders every page. The rendered Markdown and its figures are written
to `docs/frozen/` and committed. The regional and NEMDE how-tos need the January 2025 NEMWEB cache
under `~/.nemdb_cache`.

The build fails when a page's source, or a shared file it uses from `shared/`, changed since the page
was rendered. Re-render the page and commit the output in that case, and also after a dependency
update that changes its output.
