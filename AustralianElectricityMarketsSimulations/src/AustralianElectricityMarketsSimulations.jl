module AustralianElectricityMarketsSimulations

using AustralianElectricityMarkets
using Chain
using DataFrames
using Dates
using DuckDB
using HiGHS
using HydroPowerSimulations
using JuMP
using PowerSimulations
using PowerSystems
using Statistics

import PowerSimulations as PSI
import PowerSystems as PSY

# Reached through PSI/PSY rather than declared as direct dependencies, so they cannot version-skew
# from the pinned PowerSimulations.
const IS = PSY.IS
const PM = PSI.PM

include("types/errors.jl")
include("time_basis.jl")

include("types/constraint_formulations.jl")
include("types/dispatch.jl")
include("types/energy_limits.jl")
include("types/energy_offers.jl")
include("types/storage.jl")
include("types/tie_break.jl")
include("types/interconnector_losses.jl")
include("types/mnsp.jl")
include("types/logging.jl")

include("formulations/constraint_formulations.jl")
include("formulations/generic_constraints.jl")
include("checks/nem_constraints.jl")
include("formulations/dispatch.jl")
include("formulations/energy_limits.jl")
include("formulations/energy_offers.jl")
include("checks/dispatch_envelope.jl")
include("formulations/storage.jl")
include("formulations/tie_break.jl")
include("formulations/interconnector_losses.jl")
include("formulations/mnsp.jl")
include("checks/interconnector_losses.jl")
include("psi_compat.jl")
include("formulations/fcas.jl")
include("checks/fcas.jl")
include("preprocessing/fcas.jl")
include("preprocessing/tie_break.jl")
include("checks/tie_break.jl")
include("checks/replay_inputs.jl")
include("preprocessing/inputs.jl")
include("execution/replication.jl")
include("execution/simulation.jl")

using AustralianElectricityMarkets.Readers: read_uigf_as_dict
@doc (@doc AustralianElectricityMarkets.IntervalInputs) IntervalInputs
@doc (@doc AustralianElectricityMarkets.Readers.read_interval_inputs) read_interval_inputs
@doc (@doc AustralianElectricityMarkets.Readers.read_published_interval) read_published_interval

export DISPATCH_INTERVAL_HOURS, DISPATCH_INTERVAL, interval_hours, interval_cost_coefficient
export IntervalInputs, read_interval_inputs, read_published_interval
export REPLICATION_PARTS, replication_template, replication_system, replicate_range
export ENERGY_OFFER_CVP_FACTOR, EnergyOfferSurplusSlack, EnergyOfferDeficitSlack,
    EnergyDecrementalOfferSurplusSlack, EnergyDecrementalOfferDeficitSlack
export EnergyMaxAvailOutConstraint, EnergyMaxAvailInConstraint, EnergyMaxAvailOutSlack, EnergyMaxAvailInSlack
export EnergyMaxAvailTimeSeriesParameter, EnergyUIGFTimeSeriesParameter,
    EnergyMaxAvailConstraint, EnergyUIGFConstraint, EnergyMaxAvailSlack, EnergyUIGFSlack,
    ENERGY_MAX_AVAIL_CVP_FACTOR, ENERGY_UIGF_CVP_FACTOR
export energy_bounds
export scale_trapezium
export AbstractNEMConstraintFormulation, NEMConstraintLHS, NEMConstraintLimit,
    NEMConstraintRHSParameter, LinearFactorLimit, FCASMarket
export GenericConstraintSlackUp, GenericConstraintSlackDown, MARKET_PRICE_CAP_BY_FINANCIAL_YEAR
export FCASCapacityVariable, FCASSideCapacityVariable, FCASUnitRegulationTarget,
    FCASJointCapacityLHS, FCASJointCapacityConstraint, FCASBDURampingConstraint,
    FCASJointRampingConstraint, FCASJointCapacitySlack, FCASJointRampingSlack,
    FCASMaxAvailConstraint, FCASMaxAvailSlack, FCASBDURampingSlack,
    FCASOfferBandVariable, FCASOfferLimitParameter, FCASBandWidthParameter, FCASUpperSlopeParameter,
    FCASLowerSlopeParameter, FCASRampingLimitParameter, FCASBandPriceParameter,
    FCAS_BAND_COUNT, FCAS_INACTIVE_LIMIT_MW, set_fcas_effective_offers!,
    FCAS_MAXAVAIL_CVP_FACTOR, FCAS_BDU_RAMPING_CVP_FACTOR, FCAS_CAPACITY_CVP_FACTOR,
    FCAS_RAMPING_CVP_FACTOR, AREA_BALANCE_CVP_FACTOR,
    UNIT_RAMP_CVP_FACTOR, UnitRampUpSlack, UnitRampDownSlack,
    INTERCONNECTOR_FLOW_CVP_FACTOR, InterconnectorFlowSurplusSlack, InterconnectorFlowDeficitSlack
export filter_buildable_generic_constraints, compute_fcas_prices
export check_fcas_services, check_dispatch_envelope
export AbstractNEMDispatch, NEMReplayDispatch, NEMLookaheadDispatch,
    RampUpRateTimeSeriesParameter, RampDownRateTimeSeriesParameter,
    InitialPowerTimeSeriesParameter
export nem_dispatch_participants, set_nem_dispatch_models!
export TIE_BREAK_CVP_FACTOR, TIE_BREAK_SERVICE_NAME, TieBreakScaleParameter, TieBreakMarket, TieBreakSlackUp,
    TieBreakSlackDown, TieBreakConstraint, set_tie_break_scales!, check_tie_break_pairs
export NEMInterconnectorLoss, InterconnectorLossVariable, InterconnectorLossSegmentVariable,
    InterconnectorFlowSegmentConstraint, InterconnectorLossDefinitionConstraint,
    InterconnectorLossSegmentFullVariable, InterconnectorLossSegmentOrderConstraint,
    LossDemandCoefficientParameter
export MNSPLinkFlowVariable, MNSPLinkFlowConstraint, MNSPLinkDirectionVariable,
    MNSPLinkLossVariable, MNSPLinkBandVariable, MNSPBandWidthParameter, MNSPForwardBandWidthParameter,
    MNSPReverseBandWidthParameter, MNSPMaxAvailParameter, MNSPForwardMaxAvailParameter,
    MNSPReverseMaxAvailParameter, MNSPBandPriceParameter
export interconnector_loss_gaps, check_interconnector_loss_segments

end
