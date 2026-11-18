# Literate sources

Sources are grouped by the topic and purpose of each page:

| Folder | Contents |
| --- | --- |
| `overview/` | Background on the National Electricity Market |
| `formulation/` | NEMDE model, energy, FCAS, interconnectors, fast-start and pricing chapters |
| `tutorials/` | Toy-market walkthroughs using JuMP, PowerSimulations.jl and AEM / AEMSim |
| `howto/` | System construction, dispatch, market clearing and NEMDE run guides |
| `shared/` | Toy-market data, reference solver and source-inlining helper used by the tutorials |

`docs/make.jl` lists the page groups and renders them into the flat `docs/src/examples/`
folder. Source folders do not change the published page paths. Shared helpers are included
by pages or the build script and are not rendered as separate pages.

The three tutorials form a sequence: `nemde_jump.jl`, `nemde_psi.jl`, then `nemde_aem.jl`.
Their hidden includes resolve from the generated examples folder during Literate execution.

To build the documentation from the repository root:

```sh
julia --project=docs docs/make.jl
```

To render just the formulation chapters and figures for local review:

```sh
julia --project=docs docs/render_formulation_review.jl
```

## Frozen pages

Some how-to pages need the full local NEMWEB cache and minutes of solve time, so CI cannot run
them. These pages are listed in `FROZEN_PAGES` in `docs/frozen_pages.jl`: `run_nemde` and the
five `template_*` pages. Run `pre-commit run -a` before rendering, since a reformatted source changes its stamp.
Render one or more of them locally with:

```sh
julia --project=docs docs/prerender.jl run_nemde template_fcas
```

With no arguments the script renders every frozen page. The rendered Markdown and its figures are
written to `docs/frozen/` and committed. `docs/make.jl` copies them into the examples folder instead
of executing the pages.

The build fails when a frozen page's source changed since it was rendered. Re-render the page and
commit the output in that case, and also after a dependency update that changes its output.
