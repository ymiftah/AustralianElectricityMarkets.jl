"""Run STOCK nempy (its NEMDE-XML RawInputsLoader) for dispatch intervals and compare with AEMO.

nempy is pinned at commit 2d3cef0 (v3.0.3), solved with CBC through mip 1.16rc0. Market inputs
come from the NEMDE case-file XMLs in --xml-cache; the MMS tables nempy still reads come from the
sqlite database built by build_db.py.

usage: run_interval_xml.py --db FILE --xml-cache DIR --out DIR [--nempy-src DIR]
                           (--intervals-file FILE | 'YYYY/MM/DD HH:MM:SS' ...)

Writes <out>/<YYYYMMDD_HHMMSS>/{prices,unit_dispatch,interconnector_flows,price_comparison,
unit_comparison,interconnector_comparison}.csv and a `done` marker. Intervals with a `done`
marker are skipped; a failing interval writes `error.txt` and the run continues.
"""
import argparse
import os
import sqlite3
import sys
import traceback
import warnings

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cbc_workaround  # noqa: F401,E402  (must precede nempy)

import numpy as np  # noqa: E402
import pandas as pd  # noqa: E402

warnings.filterwarnings('ignore')

REGIONS = ['QLD1', 'NSW1', 'VIC1', 'SA1', 'TAS1']
SVC = {'raise_reg': 'RAISEREG', 'lower_reg': 'LOWERREG', 'raise_6s': 'RAISE6SEC', 'raise_60s': 'RAISE60SEC',
       'raise_5min': 'RAISE5MIN', 'lower_6s': 'LOWER6SEC', 'lower_60s': 'LOWER60SEC', 'lower_5min': 'LOWER5MIN',
       'raise_1s': 'RAISE1SEC', 'lower_1s': 'LOWER1SEC'}


def tag(interval):
    return interval.replace('/', '').replace(':', '').replace(' ', '_')


def run(interval, con, xml_cache, out_root):
    from nempy import markets
    from nempy.historical_inputs import mms_db, units, demand, interconnectors, constraints
    from nempy.historical_inputs import loaders, xml_cache as xc

    out = os.path.join(out_root, tag(interval))
    os.makedirs(out, exist_ok=True)
    mdb = mms_db.DBManager(con)
    xm = xc.XMLCacheManager(xml_cache)
    ld = loaders.RawInputsLoader(nemde_xml_cache_manager=xm, market_management_system_database=mdb)
    ld.set_interval(interval)
    ui = units.UnitData(ld)
    ii = interconnectors.InterconnectorData(ld)
    ci = constraints.ConstraintData(ld)
    di = demand.DemandData(ld)
    m = markets.SpotMarket(market_regions=REGIONS, unit_info=ui.get_unit_info())
    vb, pb = ui.get_processed_bids()
    m.set_unit_volume_bids(vb)
    m.set_unit_price_bids(pb)
    V = ci.get_constraint_violation_prices()
    m.set_unit_bid_capacity_constraints(ui.get_unit_bid_availability(), violation_cost=V['unit_capacity'])
    m.set_unconstrained_intermittent_generation_forecast_constraint(ui.get_unit_uigf_limits(), violation_cost=V['uigf'])
    fsp = ui.get_fast_start_profiles_for_dispatch()
    m.set_unit_ramp_rate_constraints(ui.get_bid_ramp_rates(), ui.get_scada_ramp_rates(), fsp,
                                     run_type='fast_start_first_run', violation_cost=V['ramp_rate'])
    ui.add_fcas_trapezium_constraints()
    m.set_fcas_max_availability(ui.get_fcas_max_availability(), violation_cost=V['fcas_max_avail'])
    m.set_energy_and_regulation_capacity_constraints(ui.get_fcas_regulation_trapeziums(), violation_cost=V['fcas_profile'])
    m.set_joint_ramping_constraints_reg(ui.get_scada_ramp_rates(inlude_initial_output=True), fsp,
                                        run_type='fast_start_first_run', violation_cost=V['fcas_profile'])
    m.set_joint_capacity_constraints(ui.get_contingency_services(), violation_cost=V['fcas_profile'])
    idefs = ii.get_interconnector_definitions()
    lf, bp = ii.get_interconnector_loss_model()
    m.set_interconnectors(idefs)
    m.set_interconnector_losses(lf, bp)
    cost = ci.get_violation_costs()
    m.set_fcas_requirements_constraints(ci.get_fcas_requirements(), violation_cost=cost)
    m.set_generic_constraints(ci.get_rhs_and_type_excluding_regional_fcas_constraints(), violation_cost=cost)
    m.link_units_to_generic_constraints(ci.get_unit_lhs())
    m.link_interconnectors_to_generic_constraints(ci.get_interconnector_lhs())
    m.set_demand_constraints(di.get_operational_demand(), violation_cost=V['regional_demand'])
    m.set_tie_break_constraints(V['tiebreak'])
    # The first run (no fast start) decides fast start commitment; the second run adds those constraints.
    m.dispatch()
    fsp2 = ui.get_fast_start_profiles_for_dispatch(m.get_unit_dispatch())
    m.set_fast_start_constraints(
        fsp2.loc[:, ['unit', 'end_mode', 'time_in_end_mode', 'mode_two_length', 'mode_four_length', 'min_loading']],
        violation_cost=V['fast_start'])
    fsp3 = fsp2.loc[:, ['unit', 'end_mode', 'time_since_end_of_mode_two', 'min_loading']]
    m.set_unit_ramp_rate_constraints(ui.get_bid_ramp_rates(), ui.get_scada_ramp_rates(), fsp3,
                                     run_type='fast_start_second_run', violation_cost=V['ramp_rate'])
    m.set_joint_ramping_constraints_reg(ui.get_scada_ramp_rates(inlude_initial_output=True), fsp3,
                                        run_type='fast_start_second_run', violation_cost=V['fcas_profile'])
    if ci.is_over_constrained_dispatch_rerun():
        mpc = V['voll']
        m.dispatch(allow_over_constrained_dispatch_re_run=True, energy_market_floor_price=-1000.0,
                   energy_market_ceiling_price=mpc, fcas_market_ceiling_price=1000.0)
    else:
        m.dispatch(allow_over_constrained_dispatch_re_run=False)

    ep = m.get_energy_prices().rename(columns={'price': 'nempy_price'})
    ep['service'] = 'ENERGY'
    fp = m.get_fcas_prices().rename(columns={'price': 'nempy_price'})
    fp['service'] = fp['service'].map(SVC)
    prices = pd.concat([ep, fp])
    prices['interval'] = interval
    prices.to_csv(f'{out}/prices.csv', index=False)
    ud = m.get_unit_dispatch()
    ud['interval'] = interval
    ud.to_csv(f'{out}/unit_dispatch.csv', index=False)
    fl = m.get_interconnector_flows()
    fl['interval'] = interval
    fl.to_csv(f'{out}/interconnector_flows.csv', index=False)

    # ---- AEMO comparison (published values from the MMS database) ----
    q = lambda s: pd.read_sql_query(s, con, params=(interval,))
    dp = q('select * from DISPATCHPRICE where SETTLEMENTDATE=?')
    cmp = []
    e = ep.merge(dp, left_on='region', right_on='REGIONID')
    e2 = e.loc[:, ['region', 'nempy_price', 'ROP', 'RRP']]
    e2['service'] = 'ENERGY'
    cmp.append(e2.rename(columns={'ROP': 'aemo_ROP', 'RRP': 'aemo_RRP'}))
    for s in SVC.values():
        f = fp[fp['service'] == s].merge(dp, left_on='region', right_on='REGIONID')
        if f.empty:
            continue
        f['aemo_ROP'] = f[f'{s}ROP']
        f['aemo_RRP'] = f[f'{s}RRP']
        cmp.append(f.loc[:, ['region', 'service', 'nempy_price', 'aemo_ROP', 'aemo_RRP']])
    pd.concat(cmp).to_csv(f'{out}/price_comparison.csv', index=False)

    # Net MW (generation minus load) against TOTALCLEARED and the FCAS targets.
    u = ud.copy()
    u['dispatch'] = np.where(u['dispatch_type'] == 'load', -u['dispatch'], u['dispatch'])
    u = u.groupby(['unit', 'service'], as_index=False)['dispatch'].sum()
    dl = q('select * from DISPATCHLOAD where SETTLEMENTDATE=?')
    ucmp = []
    for s, col in {'energy': 'TOTALCLEARED', **SVC}.items():
        n = u[u['service'] == s].set_index('unit')['dispatch']
        a = dl.set_index('DUID')[col]
        j = pd.concat([n.rename('nempy'), a.rename('aemo')], axis=1)
        j = j.dropna() if s == 'energy' else j.fillna(0.0)
        j['service'] = col
        ucmp.append(j.rename_axis('unit').reset_index())
    pd.concat(ucmp).to_csv(f'{out}/unit_comparison.csv', index=False)

    ir = q('select * from DISPATCHINTERCONNECTORRES where SETTLEMENTDATE=?')
    fac = idefs.loc[:, ['interconnector', 'link', 'generic_constraint_factor']]
    f = fl.merge(fac, on=['interconnector', 'link'], how='left')
    f['flow'] = f['flow'] * f['generic_constraint_factor'].fillna(1)
    f = f.groupby('interconnector', as_index=False)[['flow', 'losses']].sum()
    f = f.merge(ir.rename(columns={'INTERCONNECTORID': 'interconnector'}), on='interconnector', how='inner')
    f.to_csv(f'{out}/interconnector_comparison.csv', index=False)
    open(f'{out}/done', 'w').write('ok\n')


def main():
    p = argparse.ArgumentParser()
    p.add_argument('intervals', nargs='*')
    p.add_argument('--intervals-file')
    p.add_argument('--db', required=True)
    p.add_argument('--xml-cache', required=True)
    p.add_argument('--out', required=True)
    p.add_argument('--nempy-src', default=os.environ.get('NEMPY_SRC'))
    a = p.parse_args()
    if a.nempy_src:
        sys.path.insert(0, a.nempy_src)
    intervals = list(a.intervals)
    if a.intervals_file:
        intervals += [l.strip() for l in open(a.intervals_file) if l.strip()]
    con = sqlite3.connect(a.db)
    failed = 0
    for i in intervals:
        d = os.path.join(a.out, tag(i))
        if os.path.exists(os.path.join(d, 'done')):
            print('skip (done)', i)
            continue
        try:
            run(i, con, a.xml_cache, a.out)
            print('ok', i, flush=True)
        except Exception:
            failed += 1
            os.makedirs(d, exist_ok=True)
            open(os.path.join(d, 'error.txt'), 'w').write(traceback.format_exc())
            print('FAILED', i, traceback.format_exc().strip().splitlines()[-1], flush=True)
    return 1 if failed and failed == len(intervals) else 0


if __name__ == '__main__':
    sys.exit(main())
