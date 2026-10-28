# 0085. Market Price Cap penalties fixed at build, one financial year per simulation

## Status

Accepted. Supersedes [0070](0070-per-slack-market-price-cap-parameters.md) and
[0065](0065-market-price-cap-repricing.md): penalties are no longer re-priced at each step.

## Context

Penalty slacks priced at the Market Price Cap were registered as a per-slack
`MarketPriceCapPenaltyParameter` and re-priced at each simulation step, so a model built once followed
the cap across 1 July. PowerSimulations now prices time-series values natively through cost targets,
and the replay chunks already split at 00:05 on 1 July.

## Decision

Each Market Price Cap penalty is a constant of the invariant objective, priced at the Market Price Cap of
the container's initial interval. The pre-flight check `check_single_financial_year` refuses a simulation
whose first and last intervals fall in different financial years, so that one cap holds throughout.
Penalty factors and caps are unchanged. The financial year of an interval ending at `t` is the year of
`t - 5 minutes`, so the interval ending 00:00 on 1 July belongs to the earlier year.

## Consequences

- A range across 1 July is refused before build; callers split it at 00:05 on 1 July.
- Generic-constraint slack costs use native cost targets scaled by the build-time cap, as do the
  Market Price Cap penalties of the other slacks.
- The `MarketPriceCapPenaltyParameter` type is removed.
