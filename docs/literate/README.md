# Literate sources

Sources are grouped by the topic and purpose of each page:

| Folder | Contents |
| --- | --- |
| `overview/` | Background on the National Electricity Market |
| `formulation/` | NEMDE model, energy, FCAS, interconnectors, fast-start and pricing chapters |
| `tutorials/` | Toy-market walkthroughs using JuMP, PowerSimulations.jl and AEM / AEMSim |
| `howto/` | System construction, dispatch, market clearing and FCAS interval guides |
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
