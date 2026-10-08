"""Download NEMDE case-file zips from NEMWEB and extract only the needed interval XMLs.

One zip (about 170 MB) is downloaded per market day, the XMLs of the requested intervals are
extracted into the cache and the zip is deleted. Intervals already in the cache are skipped.

usage: fetch_xml.py --intervals-file FILE --xml-cache DIR [--dl-dir DIR] [--nempy-src DIR] [--dry-run]

FILE holds one interval end per line as 'YYYY/MM/DD HH:MM:SS' (SETTLEMENTDATE). --nempy-src
defaults to $NEMPY_SRC (the nempy `src` directory when nempy is not pip-installed).
"""
import argparse
import collections
import glob
import os
import subprocess
import sys
import zipfile

URL = ('https://www.nemweb.com.au/Data_Archive/Wholesale_Electricity/NEMDE/{y}/NEMDE_{y}_{mo}/'
       'NEMDE_Market_Data/NEMDE_Files/NemSpdOutputs_{y}{mo}{d}_loaded.zip')


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--intervals-file', required=True)
    p.add_argument('--xml-cache', required=True)
    p.add_argument('--dl-dir', default=None, help='where the zip is held while extracting (default: <xml-cache>/../dl)')
    p.add_argument('--nempy-src', default=os.environ.get('NEMPY_SRC'))
    p.add_argument('--dry-run', action='store_true')
    a = p.parse_args()
    if a.nempy_src:
        sys.path.insert(0, a.nempy_src)
    from nempy.historical_inputs.xml_cache import XMLCacheManager

    dl_dir = a.dl_dir or os.path.join(os.path.dirname(os.path.abspath(a.xml_cache)), 'dl')
    os.makedirs(a.xml_cache, exist_ok=True)
    manager = XMLCacheManager(a.xml_cache)
    need = collections.defaultdict(list)
    for line in open(a.intervals_file).read().split('\n'):
        if not line.strip():
            continue
        manager.interval = line.strip()
        y, mo, d = manager._get_market_year_month_day_as_str()
        name = manager.get_file_name().replace('_OCD', '')
        if not glob.glob(os.path.join(a.xml_cache, name[:-7] + '*')):
            need[(y, mo, d)].append(name)
    print(f'{sum(map(len, need.values()))} XML files missing on {len(need)} market days')
    if a.dry_run:
        for (y, mo, d), names in need.items():
            print(f'would download {URL.format(y=y, mo=mo, d=d)} for {len(names)} intervals')
        return 0
    os.makedirs(dl_dir, exist_ok=True)
    for (y, mo, d), names in need.items():
        z = os.path.join(dl_dir, f'NemSpdOutputs_{y}{mo}{d}_loaded.zip')
        if not os.path.exists(z):
            subprocess.check_call(['curl', '-sSf', '-o', z, URL.format(y=y, mo=mo, d=d)])
        with zipfile.ZipFile(z) as zf:
            members = zf.namelist()
            for n in names:
                hits = [h for h in members if h.startswith(n[:-7])]
                print(y, mo, d, n, '->', hits)
                for h in hits:
                    zf.extract(h, a.xml_cache)
        os.remove(z)
    return 0


if __name__ == '__main__':
    sys.exit(main())
