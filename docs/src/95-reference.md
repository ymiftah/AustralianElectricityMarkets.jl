# [Reference](@id reference)

## Contents

```@contents
Pages = ["95-reference.md"]
```

## Index

```@index
Pages = ["95-reference.md"]
```

## AustralianElectricityMarkets

```@autodocs
Modules = [AustralianElectricityMarkets]
```

## AustralianElectricityMarketsSimulations

NEMDE run in PowerSimulations.jl: dispatch problems, device, FCAS, constraint and loss
formulations, the problem template and sequence, and the readers of solved results.

```@autodocs
Modules = [AustralianElectricityMarketsSimulations]
```

## Cache population and infrastructure

```@docs
AustralianElectricityMarketsData.populate
AustralianElectricityMarketsData.populate_legacy_archive
AustralianElectricityMarketsCache.AEMDB
AustralianElectricityMarketsCache.DataSource
AustralianElectricityMarketsCache.get_table
```
