# 0061 Run chunks: one stock `PSI.Simulation` per trading day and financial year

## Status

Accepted. Entry points and pre-flight orchestration are in [0092](0092-psi-shaped-problem-interface.md); input ownership is in [0101](0101-aem-writes-aemsim-reads.md).

## What

- A model is built once per chunk and stepped, one dispatch interval per step; there is no per-interval build path.
- `dispatch_chunks(steps; chunk = :trading_day)` splits a range at every trading-day start (the interval ending 04:05), at the interval ending 00:05 on 1 July, and every `chunk` period when one is given.
- `nem_system(db, NEMDEConfiguration(); date_range)` refuses a range whose dispatch intervals span more than one trading day or financial year.
- A generic constraint invoked at none of the dispatch intervals is set unavailable with reason `:never_invoked` and recorded in the build report. One invoked at some intervals is built, its invoked series frees its row at the others, and a slack at an uninvoked interval is not reported as a violation.
- A Market Price Cap override (`market_price_cap`) must be finite and strictly positive (`_checked_market_price_cap`); this validates configuration and departs from nothing in AEMO's published cost terms.

## How

- The chunk bounds are what make build-time structure valid: the Market Price Cap, the set of modelled generic constraints and the tie-break pairs are fixed at build and cannot follow a step.
- Each chunk runs a one-interval `DecisionModel` per step over a system covering the chunk plus the two stamps after it, with `InterProblemChronology`.

## Why

- Price bands for a trading day are fixed at the 12:30 Day -1 gate closure and cannot change in a rebid; rebids change quantities only (AEMO *Spot Market Operations Timetable* v1.12 §2.1, pp. 5-6; NER 3.8.5, 3.8.22). So price-tied band pairs are constant within a trading day.
- Loss factors, which refer prices to the regional reference node, and the Market Price Cap change only with the financial year (AEMC *Schedule of reliability settings, 2026-27 financial year*, 27 February 2026, p. 1: $20,300/MWh for 2025-26, $23,200/MWh for 2026-27).
- A rebuild per trading day is preferred over re-deriving tie groups each step, because PSI has no step hook that adds or removes constraints.
