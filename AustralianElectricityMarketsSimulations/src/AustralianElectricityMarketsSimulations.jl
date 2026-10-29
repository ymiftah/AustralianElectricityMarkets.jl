module AustralianElectricityMarketsSimulations

import AustralianElectricityMarkets
using AustralianElectricityMarkets: BidType, ConstraintSense, FCASService, FCASTrapezium,
    FCAS_REGULATION_MARKETS, GenericConstraint, InterconnectorLossModel, InterconnectorTerm,
    EnergyTieBreak, NEM_SERIES, OfferSide, RegionTerm, UnitTerm, TIE_BREAK_CVP_FACTOR, TIE_BREAK_SERVICE_NAME,
    set_tie_break_scales!, DISPATCH_INTERVAL,
    UNIT_RAMP_CVP_FACTOR, INTERCONNECTOR_FLOW_CVP_FACTOR, ENERGY_OFFER_CVP_FACTOR, ENERGY_UIGF_CVP_FACTOR,
    ENERGY_MAX_AVAIL_CVP_FACTOR, AREA_BALANCE_CVP_FACTOR, FIXED_LOADING_CVP_FACTOR,
    MNSP_RAMP_CVP_FACTOR, MNSP_OFFER_CVP_FACTOR, MNSP_AVAILABILITY_CVP_FACTOR, constraint_cvp_factor,
    energy_max_avail_series_name, offer_side, side_suffix, has_schedule_classification, is_semi_scheduled, get_energy_offer, get_fcas_offer, FCASBidDirection, fcas_bid_direction, fcas_series_name, mnsp_series_name, fcas_service_name, fcas_service, fcas_offer_series_name, get_bid_type, get_constraint_weight,
    get_defaulted_constraint_weights, get_devices, get_dropped_terms, get_duid, get_enablement_max,
    get_enablement_min, get_energy_availability, get_factor, get_fcas_agc_ramp_capability,
    get_fcas_agc_status, get_fcas_requirements, get_initial_mw, get_interconnector,
    get_limit_type, get_lower_slope_coeff, get_max_avail, get_missing_constraint_intervals, get_region,
    get_scaled_fcas_trapezium, get_sense, get_service, get_skipped_constraints, get_source,
    get_storage_energy_max_avail, get_terms, get_upper_slope_coeff, loss_curve_vertex_values,
    is_non_scheduled_load, loss_segments, nem_dispatch_devices,
    FCAS_BAND_COUNT, set_fcas_effective_offers!,
    FCAS_CAPACITY_CVP_FACTOR, FCAS_RAMPING_CVP_FACTOR, FCAS_MAXAVAIL_CVP_FACTOR, FCAS_BDU_RAMPING_CVP_FACTOR,
    fcas_effective_series_name, fcas_ramping_series_name, fcas_upper_regulation_service, fcas_offer_sides,
    tie_break_series_name, tie_groups,
    _tie_break_offers, _tie_break_active_bands, _tie_break_stamp_bands, _other_regulation, _financial_year_mpc, _financial_year_start
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

include("types/constraint_formulations.jl")
include("types/dispatch.jl")
include("types/energy_limits.jl")
include("types/fixed_loads.jl")
include("types/energy_offers.jl")
include("types/tie_break.jl")
include("types/interconnector_losses.jl")
include("types/mnsp.jl")
include("types/mnsp_limits.jl")

include("formulations/slacks.jl")
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
include("formulations/mnsp_limits.jl")
include("psi_compat.jl")
include("formulations/fcas.jl")
include("checks/fcas.jl")
include("checks/tie_break.jl")
include("checks/financial_year.jl")
include("checks/replay_inputs.jl")
include("checks/replication_steps.jl")
include("execution/replication.jl")


export DISPATCH_INTERVAL, interval_hours, interval_cost_coefficient
export REPLICATION_PARTS, replication_template, replication_decision_model, check_replication_steps
export EnergyOfferSurplusSlack, EnergyOfferDeficitSlack,
    EnergyDecrementalOfferSurplusSlack, EnergyDecrementalOfferDeficitSlack
export EnergyMaxAvailOutConstraint, EnergyMaxAvailInConstraint, EnergyMaxAvailOutSlack, EnergyMaxAvailInSlack
export EnergyMaxAvailTimeSeriesParameter, EnergyUIGFTimeSeriesParameter,
    EnergyMaxAvailConstraint, EnergyUIGFConstraint, EnergyMaxAvailSlack, EnergyUIGFSlack
export FixedLoadTimeSeriesParameter, FixedLoadInvokedTimeSeriesParameter, EnergyFixedLoadConstraint,
    EnergyFixedLoadSurplusSlack, EnergyFixedLoadDeficitSlack
export NEMConstraintLHS, NEMConstraintLimit,
    NEMConstraintRHSParameter, LinearFactorLimit, FCASMarket
export GenericConstraintSlackUp, GenericConstraintSlackDown
export FCASCapacityVariable, FCASSideCapacityVariable, FCASUnitRegulationTarget,
    FCASJointCapacityLHS, FCASJointCapacityConstraint, FCASBDURampingConstraint,
    FCASJointRampingConstraint, FCASJointCapacitySlack, FCASJointRampingSlack,
    FCASMaxAvailConstraint, FCASMaxAvailSlack, FCASBDURampingSlack,
    FCASOfferBandVariable, FCASOfferBandConstraint, FCASOfferLimitParameter, FCASBandWidthParameter, FCASUpperSlopeParameter,
    FCASLowerSlopeParameter, FCASRampingLimitParameter, FCASBandPriceParameter,
    UnitRampUpSlack, UnitRampDownSlack,
    InterconnectorFlowSurplusSlack, InterconnectorFlowDeficitSlack
export check_fcas_services, check_dispatch_envelope, check_single_financial_year
export AbstractNEMDispatch, NEMReplayDispatch,
    RampUpRateTimeSeriesParameter, RampDownRateTimeSeriesParameter,
    InitialPowerTimeSeriesParameter
export nem_dispatch_participants, set_nem_dispatch_models!
export TieBreakScaleParameter, TieBreakMarket, TieBreakSlackUp,
    TieBreakSlackDown, TieBreakConstraint, check_tie_break_pairs
export NEMInterconnectorLoss, InterconnectorLossVariable, InterconnectorLossSegmentVariable,
    InterconnectorFlowSegmentConstraint, InterconnectorLossDefinitionConstraint,
    InterconnectorLossSegmentFullVariable, InterconnectorLossSegmentOrderConstraint,
    LossDemandCoefficientParameter
export MNSPLinkFlowVariable, MNSPLinkFlowConstraint, MNSPLinkBandConstraint, MNSPLinkMaxAvailConstraint,
    MNSPLinkDirectionConstraint, MNSPLinkLossConstraint, MNSPLinkLossSplitConstraint, MNSPLinkDirectionVariable,
    MNSPLinkLossVariable, MNSPLinkBandVariable, MNSPBandWidthParameter, MNSPForwardBandWidthParameter,
    MNSPReverseBandWidthParameter, MNSPMaxAvailParameter, MNSPForwardMaxAvailParameter,
    MNSPReverseMaxAvailParameter, MNSPBandPriceParameter

export MNSPInitialFlowParameter, MNSPForwardRampRateParameter, MNSPReverseRampRateParameter, MNSPForwardFixedLoadParameter, MNSPReverseFixedLoadParameter, MNSPForwardFixedLoadInvokedParameter, MNSPReverseFixedLoadInvokedParameter, MNSPMaxAvailSlack, MNSPOfferSlack, MNSPRampUpSlack, MNSPRampDownSlack, MNSPFixedLoadSurplusSlack, MNSPFixedLoadDeficitSlack, MNSPRampConstraint, MNSPFixedLoadConstraint


include("precompile.jl")

end
