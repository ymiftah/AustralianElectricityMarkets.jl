# Roadmap

The Australian Electricity Market Operator makes available a wealth of market data and forecasts. This unique transparency and further the availability of public GIS data sources should allow to derive a relatively accurate model of the Eastern australian power grid, making it a perfect test bed with real data.

The following points are the planned next steps in the development of this package:

## Short-term

- [ ] Inclusion of all unit types in the system.
- [ ] Review assumptions made for the operational costs.
- [ ] Create a full network configuration with all lines (using GIS data) for AC/DC operation problems (work started in [nemdb](https://github.com/ymiftah/nemdb)).
- [ ] Account for Commissioning / Decomissioning dates to model the system at different years.
- [ ] Parse latest ISP assumptions for operation costs.
- [ ] Extend PowerSimulations with constraints specific to the NEM (e.g. FCAS constraints, interconnector constraints).
- [ ] Separate the AustrlianElectricityMarketData module in its own package.

## Mid/Long-term

- [ ] Extend the parsing of ISP inputs.
- [ ] Interface with [GenX](https://github.com/GenXProject/GenX.jl) for resource capacity expansion modelling.
- [ ] Develop a general interface in a package `ElectricityMarkets.jl`.
- [ ] Full documentation of the interface.
- [ ] PoC of the interface with another region's electricity market.
