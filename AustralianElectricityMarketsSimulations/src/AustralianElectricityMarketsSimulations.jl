module AustralianElectricityMarketsSimulations

import AustralianElectricityMarkets
using AustralianElectricityMarkets: BidType, ConstraintSense, FCASService, FCASTrapezium,
    FCAS_REGULATION_MARKETS, GenericConstraint, InterconnectorLossModel, InterconnectorTerm,
    NEM_SERIES, OfferSide, RegionTerm, UnitTerm, energy_max_avail_series_name, offer_side, side_suffix, has_schedule_classification, is_semi_scheduled, get_energy_offer, get_fcas_offer, FCASBidDirection, fcas_bid_direction, fcas_series_name, mnsp_series_name, fcas_service_name, get_bid_type, get_constraint_weight,
    get_defaulted_constraint_weights, get_devices, get_dropped_terms, get_duid, get_enablement_max,
    get_enablement_min, get_energy_availability, get_factor, get_fcas_agc_ramp_capability,
    get_fcas_agc_status, get_fcas_offer_curve, get_fcas_requirements, get_initial_mw, get_interconnector,
    get_limit_type, get_lower_slope_coeff, get_max_avail, get_missing_constraint_intervals, get_region,
    get_scaled_fcas_trapezium, get_sense, get_service, get_skipped_constraints, get_source,
    get_storage_energy_max_avail, get_terms, get_upper_slope_coeff, loss_curve_vertex_values,
    is_non_scheduled_load, loss_segments, nem_dispatch_devices, remove_single_series!, replace_single_series!, scale_fcas_trapezium,
    single_series
using Chain
using DataFrames
using Dates
using HiGHS
using HydroPowerSimulations
using JuMP
using PowerSimulations
using PowerSystems

import PowerSimulations as PSI
import PowerSystems as PSY

# Reached through PSI/PSY rather than declared as direct dependencies, so they cannot version-skew
# from the pinned PowerSimulations.
const IS = PSY.IS
const PM = PSI.PM

include("time_basis.jl")
include("cvp_factors.jl")

include("types/constraint_formulations.jl")
include("types/dispatch.jl")
include("types/energy_limits.jl")
include("types/fixed_loads.jl")
include("types/energy_offers.jl")
include("types/storage.jl")
include("types/tie_break.jl")
include("types/interconnector_losses.jl")
include("types/mnsp.jl")
include("types/logging.jl")

include("formulations/slacks.jl")
include("formulations/series_parameters.jl")
include("formulations/generic_constraints.jl")
include("formulations/penalty_costs.jl")
include("checks/nem_constraints.jl")
include("formulations/dispatch.jl")
include("formulations/energy_limits.jl")
include("formulations/fixed_loads.jl")
include("formulations/energy_offers.jl")
include("checks/dispatch_envelope.jl")
include("formulations/storage.jl")
include("formulations/tie_break.jl")
include("formulations/interconnector_losses.jl")
include("formulations/mnsp.jl")
include("psi_compat.jl")
include("formulations/fcas.jl")
include("checks/fcas.jl")
include("preprocessing/fcas.jl")
include("preprocessing/tie_break.jl")
include("checks/tie_break.jl")
include("checks/replay_inputs.jl")
include("preprocessing/inputs.jl")
include("preprocessing/replication.jl")
include("execution/replication.jl")
include("execution/simulation.jl")
include("execution/interconnector_loss_gaps.jl")


export DISPATCH_INTERVAL_HOURS, DISPATCH_INTERVAL, interval_hours, interval_cost_coefficient
export REPLICATION_PARTS, replication_template
export prepare_replication!, replication_simulation, run_replication, replication_results, REPLICATION_OPTIMIZER
export ENERGY_OFFER_CVP_FACTOR, EnergyOfferSurplusSlack, EnergyOfferDeficitSlack,
    EnergyDecrementalOfferSurplusSlack, EnergyDecrementalOfferDeficitSlack
export EnergyMaxAvailOutConstraint, EnergyMaxAvailInConstraint, EnergyMaxAvailOutSlack, EnergyMaxAvailInSlack
export EnergyMaxAvailTimeSeriesParameter, EnergyUIGFTimeSeriesParameter,
    EnergyMaxAvailConstraint, EnergyUIGFConstraint, EnergyMaxAvailSlack, EnergyUIGFSlack,
    ENERGY_MAX_AVAIL_CVP_FACTOR, ENERGY_UIGF_CVP_FACTOR
export FixedLoadTimeSeriesParameter, FixedLoadInvokedTimeSeriesParameter, EnergyFixedLoadConstraint,
    EnergyFixedLoadSurplusSlack, EnergyFixedLoadDeficitSlack
export energy_bounds
export scale_trapezium
export NEMConstraintLHS, NEMConstraintLimit,
    NEMConstraintRHSParameter, LinearFactorLimit, FCASMarket
export GenericConstraintSlackUp, GenericConstraintSlackDown, MARKET_PRICE_CAP_BY_FINANCIAL_YEAR
export FCASCapacityVariable, FCASSideCapacityVariable, FCASUnitRegulationTarget,
    FCASJointCapacityLHS, FCASJointCapacityConstraint, FCASBDURampingConstraint,
    FCASJointRampingConstraint, FCASJointCapacitySlack, FCASJointRampingSlack,
    FCASMaxAvailConstraint, FCASMaxAvailSlack, FCASBDURampingSlack,
    FCASOfferBandVariable, FCASOfferBandConstraint, FCASOfferLimitParameter, FCASBandWidthParameter, FCASUpperSlopeParameter,
    FCASLowerSlopeParameter, FCASRampingLimitParameter, FCASBandPriceParameter,
    FCAS_BAND_COUNT, FCAS_INACTIVE_LIMIT_MW, set_fcas_effective_offers!,
    FCAS_MAXAVAIL_CVP_FACTOR, FCAS_BDU_RAMPING_CVP_FACTOR, FCAS_CAPACITY_CVP_FACTOR,
    FCAS_RAMPING_CVP_FACTOR, AREA_BALANCE_CVP_FACTOR, INTERCONNECTOR_ZERO_CVP_FACTOR, FIXED_LOADING_CVP_FACTOR,
    constraint_cvp_factor,
    UNIT_RAMP_CVP_FACTOR, UnitRampUpSlack, UnitRampDownSlack,
    INTERCONNECTOR_FLOW_CVP_FACTOR, InterconnectorFlowSurplusSlack, InterconnectorFlowDeficitSlack
export filter_buildable_generic_constraints, compute_fcas_prices
export check_fcas_services, check_dispatch_envelope
export AbstractNEMDispatch, NEMReplayDispatch, NEMLookaheadDispatch,
    RampUpRateTimeSeriesParameter, RampDownRateTimeSeriesParameter,
    InitialPowerTimeSeriesParameter
export nem_dispatch_participants, set_nem_dispatch_models!
export EnergyTieBreak, TIE_BREAK_CVP_FACTOR, TIE_BREAK_SERVICE_NAME, TieBreakScaleParameter, TieBreakMarket, TieBreakSlackUp,
    TieBreakSlackDown, TieBreakConstraint, set_tie_break_scales!, check_tie_break_pairs
export NEMInterconnectorLoss, InterconnectorLossVariable, InterconnectorLossSegmentVariable,
    InterconnectorFlowSegmentConstraint, InterconnectorLossDefinitionConstraint,
    InterconnectorLossSegmentFullVariable, InterconnectorLossSegmentOrderConstraint,
    LossDemandCoefficientParameter
export MNSPLinkFlowVariable, MNSPLinkFlowConstraint, MNSPLinkBandConstraint, MNSPLinkMaxAvailConstraint,
    MNSPLinkDirectionConstraint, MNSPLinkLossConstraint, MNSPLinkLossSplitConstraint, MNSPLinkDirectionVariable,
    MNSPLinkLossVariable, MNSPLinkBandVariable, MNSPBandWidthParameter, MNSPForwardBandWidthParameter,
    MNSPReverseBandWidthParameter, MNSPMaxAvailParameter, MNSPForwardMaxAvailParameter,
    MNSPReverseMaxAvailParameter, MNSPBandPriceParameter
export interconnector_loss_gaps, check_interconnector_loss_segments

end
