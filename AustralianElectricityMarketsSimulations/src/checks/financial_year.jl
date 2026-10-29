"""
    check_single_financial_year(steps)

Verifies that the first and last intervals of `steps` fall in one financial year, so that the Market
Price Cap priced at build holds for every interval. The interval ending 00:00 on 1 July belongs to the
earlier year.

# Arguments
- `steps`: the interval-ending timestamps the simulation solves.

# Returns
`nothing`. Throws an `ArgumentError` naming both financial years when they differ.
"""
function check_single_financial_year(steps)
    first_year = _financial_year_start(first(steps))
    last_year = _financial_year_start(last(steps))
    first_year == last_year || throw(
        ArgumentError(
            "check_single_financial_year: steps run from $(first(steps)) to $(last(steps)), across the financial years " *
                "starting $first_year and $last_year; split the range at 00:05 on 1 July.",
        ),
    )
    return
end
