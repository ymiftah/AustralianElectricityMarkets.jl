"""Build nempy's sqlite MMS database from the local hive parquet cache, limited to given intervals.

usage: build_db.py --db FILE --intervals-file FILE [--cache DIR] [--tmp DIR] [--memory-limit 2GB]

The intervals file holds one 'YYYY/MM/DD HH:MM:SS' (SETTLEMENTDATE = interval end) per line. The
database is rebuilt from scratch on each call so its interval set is exactly the file's. The
cache is only read.
"""
import argparse, os, sys, sqlite3
from datetime import datetime, timedelta
import duckdb, pandas as pd

CACHE = os.path.expanduser('~/.nemdb_cache')
FMT = '%Y/%m/%d %H:%M:%S'
_CACHE = [CACHE]


def hive(t):
    return f"read_parquet('{_CACHE[0]}/{t}/*/*.parquet', union_by_name=true, hive_partitioning=true)"


def ts(col):
    return f"strftime({col}, '%Y/%m/%d %H:%M:%S')"


def main(intervals, DB, CACHE, tmp, memory_limit):
    dts = [datetime.strptime(i, FMT) for i in intervals]
    months = sorted({d.strftime('%Y-%m-01') for d in dts} | {(d - timedelta(hours=5)).strftime('%Y-%m-01') for d in dts})
    mlist = ','.join(f"'{m}'" for m in months)
    ilist = ','.join(f"TIMESTAMP '{d:%Y-%m-%d %H:%M:%S}'" for d in dts)
    days = sorted({(d - timedelta(hours=4, seconds=1)).strftime('%Y-%m-%d') for d in dts})
    dlist = ','.join(f"DATE '{x}'" for x in days)
    maxdt = max(dts).strftime('%Y-%m-%d %H:%M:%S')
    _CACHE[0] = CACHE
    os.makedirs(os.path.dirname(os.path.abspath(DB)), exist_ok=True)
    if os.path.exists(DB):
        os.remove(DB)
    con = sqlite3.connect(DB)
    db = duckdb.connect()
    if tmp:
        os.makedirs(tmp, exist_ok=True)
        db.execute(f"SET temp_directory='{tmp}'")
    db.execute(f"SET memory_limit='{memory_limit}'")
    db.execute("SET threads=2")

    def put(name, sql):
        df = db.execute(sql).fetchdf()
        df.to_sql(name, con, if_exists='replace', index=False)
        print(f"{name}: {len(df)} rows")

    # Dispatch results/inputs by SETTLEMENTDATE (non-intervention run only).
    for t in ['DISPATCHREGIONSUM', 'DISPATCHLOAD', 'DISPATCHPRICE', 'DISPATCHINTERCONNECTORRES', 'DISPATCHCONSTRAINT']:
        put(t, f"""select * exclude (SETTLEMENTDATE, archive_month{', LASTCHANGED, CONFIDENTIAL_TO' if t == 'DISPATCHCONSTRAINT' else ''}{', IMPORTLIMIT, EXPORTLIMIT' if t == 'DISPATCHINTERCONNECTORRES' else ''},
                     {'GENCONID_EFFECTIVEDATE' if t == 'DISPATCHCONSTRAINT' else 'RUNNO'}),
                     {ts('SETTLEMENTDATE')} as SETTLEMENTDATE
                     {', ' + ts('GENCONID_EFFECTIVEDATE') + ' as GENCONID_EFFECTIVEDATE, RUNNO' if t == 'DISPATCHCONSTRAINT' else ''}
                   from {hive(t)}
                   where archive_month in ({mlist}) and SETTLEMENTDATE in ({ilist}) and INTERVENTION = 0""")
    # Static / versioned tables.
    put('DUDETAILSUMMARY', f"""select * exclude (START_DATE, END_DATE, archive_month),
                 {ts('START_DATE')} as START_DATE, {ts('END_DATE')} as END_DATE
               from {hive('DUDETAILSUMMARY')} where START_DATE <= TIMESTAMP '{maxdt}'
               qualify row_number() over (partition by DUID, START_DATE order by archive_month desc) = 1""")
    for t, key in [('INTERCONNECTORCONSTRAINT', 'INTERCONNECTORID'), ('LOSSMODEL', 'INTERCONNECTORID,LOSSSEGMENT'),
                   ('LOSSFACTORMODEL', 'INTERCONNECTORID,REGIONID'), ('MNSP_INTERCONNECTOR', 'INTERCONNECTORID,LINKID')]:
        put(t, f"""select * exclude (EFFECTIVEDATE, VERSIONNO, archive_month), {ts('EFFECTIVEDATE')} as EFFECTIVEDATE,
                    cast(VERSIONNO as varchar) as VERSIONNO
                   from {hive(t)} where EFFECTIVEDATE <= TIMESTAMP '{maxdt}'
                   qualify row_number() over (partition by {key}, EFFECTIVEDATE, VERSIONNO order by archive_month desc) = 1""")
    put('INTERCONNECTOR', f"select distinct INTERCONNECTORID, REGIONFROM, REGIONTO from {hive('INTERCONNECTOR')}")
    # Generic constraint definitions, limited to (GENCONID, EFFECTIVEDATE, VERSIONNO) invoked in the intervals.
    con.commit()
    used = f"""(select distinct CONSTRAINTID as GENCONID, GENCONID_EFFECTIVEDATE as ED, GENCONID_VERSIONNO as V
                from {hive('DISPATCHCONSTRAINT')} where archive_month in ({mlist}) and SETTLEMENTDATE in ({ilist}) and INTERVENTION=0)"""
    gcols = {'GENCONDATA': 'GENCONID, EFFECTIVEDATE, VERSIONNO, CONSTRAINTTYPE, GENERICCONSTRAINTWEIGHT, STATUS, DYNAMICRHS',
             'SPDREGIONCONSTRAINT': 'REGIONID, EFFECTIVEDATE, VERSIONNO, GENCONID, BIDTYPE, FACTOR',
             'SPDCONNECTIONPOINTCONSTRAINT': 'CONNECTIONPOINTID, EFFECTIVEDATE, VERSIONNO, GENCONID, BIDTYPE, FACTOR',
             'SPDINTERCONNECTORCONSTRAINT': 'INTERCONNECTORID, EFFECTIVEDATE, VERSIONNO, GENCONID, FACTOR'}
    for t, cols in gcols.items():
        cl = [c.strip() for c in cols.split(',')]
        sel = ', '.join(f"{ts('x.EFFECTIVEDATE')} as EFFECTIVEDATE" if c == 'EFFECTIVEDATE' else
                        'cast(x.VERSIONNO as varchar) as VERSIONNO' if c == 'VERSIONNO' else f'x.{c}' for c in cl)
        put(t, f"""select distinct {sel} from {hive(t)} x join {used} u
                   on x.GENCONID = u.GENCONID and x.EFFECTIVEDATE = u.ED and cast(x.VERSIONNO as varchar) = cast(u.V as varchar)""")
    # Bids for the intervals (stand-in for the NEMDE XML bid collections).
    put('BIDPEROFFER_D', f"""select * exclude (SETTLEMENTDATE, INTERVAL_DATETIME, archive_month, LASTCHANGED, ENERGYLIMIT),
                 {ts('SETTLEMENTDATE')} as SETTLEMENTDATE, {ts('INTERVAL_DATETIME')} as INTERVAL_DATETIME
               from {hive('BIDPEROFFER_D')} where archive_month in ({mlist}) and INTERVAL_DATETIME in ({ilist})
               qualify row_number() over (partition by DUID, BIDTYPE, DIRECTION, INTERVAL_DATETIME order by VERSIONNO desc) = 1""")
    put('BIDDAYOFFER_D', f"""select * exclude (SETTLEMENTDATE, archive_month),{ts('SETTLEMENTDATE')} as SETTLEMENTDATE
               from {hive('BIDDAYOFFER_D')} where archive_month in ({mlist}) and SETTLEMENTDATE in ({dlist})
               qualify row_number() over (partition by DUID, BIDTYPE, DIRECTION, SETTLEMENTDATE order by VERSIONNO desc) = 1""")
    con.commit()
    # Keep the highest RUNNO per key where the cache holds reruns.
    for t, keys in [('DISPATCHREGIONSUM', 'SETTLEMENTDATE,REGIONID'), ('DISPATCHLOAD', 'SETTLEMENTDATE,DUID'),
                    ('DISPATCHPRICE', 'SETTLEMENTDATE,REGIONID'), ('DISPATCHINTERCONNECTORRES', 'SETTLEMENTDATE,INTERCONNECTORID'),
                    ('DISPATCHCONSTRAINT', 'SETTLEMENTDATE,CONSTRAINTID')]:
        n = con.execute(f"select count(*) from (select 1 from {t} group by {keys} having count(*)>1)").fetchone()[0]
        print(f"{t}: duplicate keys {n}")
    for t in ['DISPATCHLOAD', 'DISPATCHPRICE', 'DISPATCHCONSTRAINT', 'DISPATCHREGIONSUM', 'DISPATCHINTERCONNECTORRES']:
        con.execute(f"create index if not exists ix_{t} on {t}(SETTLEMENTDATE)")
    con.commit()
    con.close()


if __name__ == '__main__':
    p = argparse.ArgumentParser()
    p.add_argument('--db', required=True)
    p.add_argument('--intervals-file', required=True)
    p.add_argument('--cache', default=CACHE)
    p.add_argument('--tmp', default=os.environ.get('TMPDIR'))
    p.add_argument('--memory-limit', default='2GB')
    a = p.parse_args()
    ivs = [l.strip() for l in open(a.intervals_file) if l.strip()]
    main(ivs, a.db, os.path.expanduser(a.cache), a.tmp, a.memory_limit)
