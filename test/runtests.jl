using AustralianElectricityMarkets
using Test

using Dates
using DuckDB
using Chain
using DataFrames: nrow, DataFrame
using PowerSystems

include("fixtures/mock_data.jl")
include("fixtures/input_builders.jl")
# Create mock data in a temporary directory for the duration of the test session
const AEM_TEST_HIVE_DIR = mktempdir()
create_mock_data(AEM_TEST_HIVE_DIR)

include("integration/pscb_fixture.jl")
include("integration/pscb_nemweb_data.jl")
const AEM_TEST_PSCB_HIVE_DIR = mktempdir()
create_pscb_nemweb_data(AEM_TEST_PSCB_HIVE_DIR)

# Test groups, in run order: name => (testset title, files). Pass group names as test arguments
# to run only those, e.g. `Pkg.test(; test_args = ["fcas", "timeseries_setters"])`.
const TEST_GROUPS = [
    "package_boundaries" => ("Package boundaries", ["package_boundaries.jl"]),
    "raw_readers" => ("Raw reader tests", ["readers/raw.jl", "readers/intervals.jl"]),
    "intervention" => ("Intervention run selection", ["readers/intervention.jl"]),
    "isp" => ("ISP reader tests", ["readers/isp.jl"]),
    "datareader" => ("Data reader tests", ["datareader.jl"]),
    "reader_aggregation" => ("Reader aggregation and historical regions", ["readers/aggregation.jl"]),
    "network_models" => (
        "Network models",
        ["network_models/common.jl"],
    ),
    "nemde_network" => ("NEMDE network configuration", ["network_models/nemde_network_configuration.jl"]),
    "hdf5_storage" => ("HDF5 storage resource lifetime", ["hdf5_storage.jl"]),
    "timeseries_setters" => ("Time series setter tests", ["timeseries_setters.jl", "bid_conversion.jl"]),
    "market_bids" => ("Market bids", ["market_bids.jl"]),
    "interval_inputs" => ("Per-interval inputs", ["interval_inputs.jl"]),
    "mnsp" => ("MNSP offers", ["mnsp_offers.jl"]),
    "fcas" => ("FCAS types", ["fcas/fcas.jl"]),
    "fcas_scaling" => ("FCAS trapezium scaling", ["fcas/scaling.jl"]),
    "constraints" => ("Constraint types", ["constraints/constraints.jl"]),
    "interconnector_losses" => ("Interconnector losses", ["interconnector_losses.jl"]),
    "pscb_constraints" => ("PSCB constraints and FCAS", ["integration/pscb_constraints.jl"]),
    "fcas_service" => ("PSCB FCASService", ["fcas/fcas_service.jl"]),
    "system_build_coverage" => ("System build coverage and JSON round-trip", ["integration/system_build_coverage.jl"]),
    "tie_break_service" => ("Energy tie-break service", ["tie_break_service.jl"]),
    "nem_offer_cost" => ("NEMOfferCost", ["types/nem_offer_cost.jl"]),
    "unit_data" => ("NEM unit data structs", ["types/unit_data.jl"]),
    "network_data" => ("NEM network data structs", ["types/network_data.jl"]),
    "nemde_inputs_stage" => ("NEMDE inputs stage", ["nemde_inputs/stage.jl"]),
    "nemde_inputs_energy" => ("NEMDE inputs energy offers", ["nemde_inputs/energy.jl"]),
    "nemde_inputs_mnsp" => ("NEMDE inputs MNSP fixed loads", ["nemde_inputs/mnsp.jl"]),
    "nemde_inputs_ramps" => ("NEMDE inputs ramp rates", ["nemde_inputs/ramps.jl"]),
    "nemde_inputs_state" => ("NEMDE inputs observed state", ["nemde_inputs/state.jl"]),
    "nemde_inputs_fcas_kernels" => ("NEMDE inputs FCAS kernels", ["nemde_inputs/fcas_kernels.jl"]),
    "nemde_inputs_fcas" => ("NEMDE inputs FCAS effective offers", ["nemde_inputs/fcas.jl", "nemde_inputs/fcas_inputs.jl"]),
    "nemde_inputs_tie_break" => ("NEMDE inputs tie-break scales", ["nemde_inputs/tie_break.jl"]),
    "nemde_inputs_prices" => ("NEMDE inputs energy band prices", ["nemde_inputs/prices.jl"]),
    "nemde_inputs_loss_demand" => ("NEMDE inputs loss demand coefficients", ["nemde_inputs/loss_demand.jl"]),
    "nemde_inputs_constraints" => ("NEMDE inputs constraint availability", ["nemde_inputs/constraints.jl"]),
    "nemde_inputs_units" => ("NEMDE inputs run-unit series and accessors", ["nemde_inputs/nemde_units.jl"]),
    "nemde_inputs_range" => ("NEMDE inputs forecasts and date-range rules", ["nemde_inputs/range.jl"]),
    "nemde_inputs_closed_loop" => ("NEMDE inputs of a closed-loop interval", ["nemde_inputs/closed_loop.jl"]),
    "fast_start" => ("Fast-start state and two-run kernel", ["fast_start.jl"]),
    "aqua" => ("Aqua", ["aqua.jl"]),
]

const SELECTED_GROUPS = let known = first.(TEST_GROUPS)
    unknown = setdiff(ARGS, known)
    isempty(unknown) || error("Unknown test group(s) $(unknown); choose from $(known).")
    isempty(ARGS) ? known : ARGS
end

for (name, (title, files)) in TEST_GROUPS
    name in SELECTED_GROUPS || continue
    @testset "$title" begin
        foreach(include, files)
    end
end
