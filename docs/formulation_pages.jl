const FORMULATION_PAGES = [
    "nemde_model", "nemde_energy", "nemde_fcas", "nemde_interconnectors",
    "nemde_fast_start", "nemde_prices",
]

const FORMULATION_FIGURE_DESCRIPTIONS = Dict(
    "nemde_energy" => ["Directional battery capacity and net five-minute ramp envelope"],
    "nemde_fcas" => [
        "FCAS allocation with shared and local procurement requirements",
        "FCAS trapezium with five technical limits and three operating points",
        "Submitted and effective FCAS envelopes under AGC limits, ramp scaling and UIGF",
        "Contingency capability after enabling raise or lower regulation",
        "Offered, scaled, available and enabled FCAS quantities",
    ],
    "nemde_interconnectors" => ["Analytic loss integral and unshifted versus zero-anchored dispatch chords"],
    "nemde_fast_start" => ["Fast-start fixed-output segments and declining minimum-load bound"],
)

function formulation_figure_descriptions(content, name)
    descriptions = get(FORMULATION_FIGURE_DESCRIPTIONS, name, String[])
    for (i, matched) in enumerate(eachmatch(r"!\[\]\(([^)]+\.(?:png|svg))\)", content))
        content = replace(content, matched.match => "![$(descriptions[i])]($(matched.captures[1]))")
    end
    return content
end
