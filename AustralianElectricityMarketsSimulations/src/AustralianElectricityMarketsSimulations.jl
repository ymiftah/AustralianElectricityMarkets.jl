module AustralianElectricityMarketsSimulations

import AustralianElectricityMarkets
using AustralianElectricityMarkets: BidType, ConstraintSense, FCASService, FCAS_REGULATION_MARKETS,
    GenericConstraint, InterconnectorLossModel, InterconnectorTerm, EnergyTieBreak, NEM_SERIES, NEM_TELEMETRY_SERIES, NEM_OBSERVED_SERIES, NEM_INTERCONNECTOR_SERIES, NEM_MNSP_SERIES, NEM_CONSTRAINT_SERIES,
    NEMInterconnectorLimits, NEMInterconnectorRegistration, InterconnectorKind, NEMMNSPBid, NEMMNSPLink, NEMMNSPObservedState,
    MNSPDirection, OfferSide,
    RegionTerm, UnitTerm, TIE_BREAK_CVP_FACTOR, TIE_BREAK_SERVICE_NAME, DISPATCH_INTERVAL,
    UNIT_RAMP_CVP_FACTOR, INTERCONNECTOR_FLOW_CVP_FACTOR, ENERGY_OFFER_CVP_FACTOR, ENERGY_UIGF_CVP_FACTOR,
    ENERGY_MAX_AVAIL_CVP_FACTOR, AREA_BALANCE_CVP_FACTOR, FIXED_LOADING_CVP_FACTOR, MNSP_RAMP_CVP_FACTOR,
    MNSP_OFFER_CVP_FACTOR, MNSP_AVAILABILITY_CVP_FACTOR, constraint_cvp_factor,
    energy_offer_series_name, offer_side, side_suffix, has_registration, is_semi_scheduled, get_registration, FCASBidDirection,
    fcas_bid_direction, fcas_series_name, fcas_service_name,
    get_bid_type, get_defaulted_constraint_weights, get_devices, get_dropped_terms, get_duid, get_factor,
    get_interconnector, get_missing_constraint_intervals, get_region, get_sense, get_skipped_constraints,
    get_terms, loss_curve_vertex_values, is_non_scheduled_load, loss_segments, nem_dispatch_devices,
    NEM_DISPATCH_DEVICE_TYPES, single_series, remove_single_series!, replace_single_series!,
    _nem_offer_cost, _fcas_units_multiplier, _get_fcas_offer_curve, get_energy_bids,
    get_fcas_bids, energy_offer_sides, FCASTrapezium, get_enablement_min, get_enablement_max, get_max_avail, get_upper_slope_coeff,
    get_lower_slope_coeff, scale_fcas_trapezium,
    FCAS_CAPACITY_CVP_FACTOR, FCAS_RAMPING_CVP_FACTOR, FCAS_MAXAVAIL_CVP_FACTOR,
    FCAS_BDU_RAMPING_CVP_FACTOR, _financial_year_mpc,
    _financial_year_start, get_fcas_requirements, get_service
using Chain
using DataFrames: DataFrame, ByRow, combine, eachrow, groupby, leftjoin, nrow, rename, select, sort!, transform
using Dates
using HiGHS
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

include("offers/derivation.jl")
include("offers/accessors.jl")
include("offers/initial_state.jl")
include("offers/fcas_effective.jl")
include("offers/tie_break.jl")
include("offers/effective_offers.jl")
include("offers/loss_demand.jl")

include("types/constraint_formulations.jl")
include("types/dispatch.jl")
include("types/energy_limits.jl")
include("types/fixed_loads.jl")
include("types/energy_offers.jl")
include("types/tie_break.jl")
include("types/interconnector_losses.jl")
include("types/mnsp.jl")
include("types/mnsp_limits.jl")
include("types/state.jl")
# The state-dependent derivation methods dispatch on NEMUnitState.
include("offers/state_derivation.jl")

include("formulations/slacks.jl")
include("formulations/generic_constraints.jl")
include("formulations/penalty_costs.jl")
include("checks/nem_constraints.jl")
include("formulations/dispatch.jl")
include("formulations/energy_limits.jl")
include("formulations/fixed_loads.jl")
include("offers/state_updates.jl")
include("offers/state_updates/energy.jl")
include("offers/state_updates/fcas.jl")
include("offers/state_updates/mnsp.jl")
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
include("checks/template.jl")
include("templates/template_nemde.jl")
include("checks/replay_range.jl")
include("problems/optimizer.jl")
include("problems/nem_dispatch.jl")
include("results/read_results.jl")
include("results/solved.jl")
include("results/violations.jl")
include("results/comparison.jl")
include("results/interconnector_losses.jl")


export set_effective_offers!, NEMEnergyOffer, get_energy_offer, NEMFCASOffer, get_fcas_offer,
    get_scaled_fcas_trapezium, get_fcas_agc_ramp_capability, get_fcas_agc_status, get_initial_mw,
    get_energy_availability, get_storage_energy_max_avail
export referred_offer_curves, effective_energy_availability,
    effective_ramp_limit, effective_ramp_limits, effective_regulation_enablement,
    effective_regulation_max_avail, fcas_trapezium_values, tie_break_scale,
    loss_demand_coefficient, set_loss_demand_coefficients!
export FCAS_BAND_COUNT, FCAS_INACTIVE_LIMIT_MW, fcas_effective_series_name, fcas_ramping_series_name,
    fcas_upper_regulation_service, fcas_offer_sides, tie_break_series_name, tie_groups
export StateSource, ObservedState, SimulatedState, NEMUnitState, unit_state, NEMDispatchInputs, NEMFCASInputs
export max_active_power_floor, in_fast_start_profile, fixed_load_invoked, effective_fixed_load,
    fcas_state_stranded_ok, fcas_both_sides_stranded_ok, fcas_ramping_active, fcas_ramping_limit,
    fcas_joint_ramping_exempt, mnsp_ramp_envelope, composite_ramp_rates
export DISPATCH_INTERVAL, interval_hours, interval_cost_coefficient, trading_day_steps, replay_chunks
export NEM_DISPATCH_DEVICE_TYPES, template_nemde, check_template_against_sys,
    exclude_unmodeled_services!, check_replication_steps,
    never_invoked_constraints, prepare_replay!, MNSPSlack
export NEMDispatchProblem, nemde_optimizer, NEMDE_HIGHS_OPTIONS
export EnergyOfferSurplusSlack, EnergyOfferDeficitSlack,
    EnergyDecrementalOfferSurplusSlack, EnergyDecrementalOfferDeficitSlack
export EnergyOfferBandVariable, EnergyBandWidthParameter, EnergyBandPriceParameter, EnergyOfferBandConstraint
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
export read_solved_interval, read_constraint_violations
export compare_intervals, comparison_summary, read_interconnector_loss_gaps
export AbstractNEMDispatch, NEMReplayDispatch,
    RampRateTimeSeriesParameter,
    InitialPowerTimeSeriesParameter
export nem_dispatch_participants, set_nem_dispatch_models!
export TieBreakScaleParameter, TieBreakMarket, TieBreakSlackUp,
    TieBreakSlackDown, TieBreakConstraint, check_tie_break_pairs
export NEMInterconnectorLoss, InterconnectorLossVariable, InterconnectorLossSegmentVariable,
    InterconnectorFlowSegmentConstraint, InterconnectorLossDefinitionConstraint,
    InterconnectorLossSegmentFullVariable, InterconnectorLossSegmentOrderConstraint,
    LossDemandCoefficientParameter
export MNSPLinkFlowVariable, MNSPLinkConstraint, MNSPLinkDirectionVariable,
    MNSPLinkLossVariable, MNSPLinkBandVariable, MNSPBandWidthParameter,
    MNSPMaxAvailParameter, MNSPBandPriceParameter

export MNSPOperatingParameter, MNSPSlack


include("precompile.jl")

end
