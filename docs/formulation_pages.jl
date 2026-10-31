const FORMULATION_PAGES = [
    "nemde_model", "nemde_energy", "nemde_fcas", "nemde_interconnectors",
    "nemde_fast_start", "nemde_prices",
]

const FORMULATION_FIGURE_DESCRIPTIONS = Dict(
    "nemde_energy" => ["Battery availability in each direction and the range reachable by ramping"],
    "nemde_fcas" => [
        "FCAS enablement with a market-wide requirement and with an added local requirement",
        "FCAS trapezium with its five parameters and three energy targets",
        "Offered and adjusted FCAS trapeziums under AGC limits, AGC ramp rate and UIGF",
        "Contingency trapezium after enabling raise or lower regulation",
        "Offered, scaled, actually available and enabled FCAS quantities",
    ],
    "nemde_interconnectors" => ["Quadratic loss curve with its chords, as placed and shifted to zero at zero flow"],
    "nemde_fast_start" => ["Fast-start inflexibility profile with fixed output in modes 1 and 2 and a floor in modes 3 and 4"],
)

function formulation_figure_descriptions(content, name)
    descriptions = get(FORMULATION_FIGURE_DESCRIPTIONS, name, String[])
    for (i, matched) in enumerate(eachmatch(r"!\[\]\(([^)]+\.(?:png|svg))\)", content))
        content = replace(content, matched.match => "![$(descriptions[i])]($(matched.captures[1]))")
    end
    return content
end
