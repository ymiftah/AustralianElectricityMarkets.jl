# nempy side of `compare_dispatch.jl`

These Python files run stock [nempy](https://github.com/UNSW-CEEM/nempy) on AEMO's own NEMDE
case-file XMLs for chosen dispatch intervals and write comparison CSVs that
`../compare_dispatch.jl` reads. nempy is optional: without it the script compares AEMSim with
NEMDE's published values only.

Pinned revision: nempy commit `2d3cef0` (v3.0.3), solving with CBC through `mip` 1.16rc0.

| File | Role |
| --- | --- |
| `fetch_xml.py` | Downloads one NEMDE zip (about 170 MB) per market day from NEMWEB, extracts the requested interval XMLs into the XML cache and deletes the zip. Skips XMLs already cached. |
| `build_db.py` | Builds nempy's sqlite MMS database from the hive cache (read only), limited to the requested intervals. |
| `run_interval_xml.py` | Runs nempy per interval and writes `prices.csv`, `unit_dispatch.csv`, `interconnector_flows.csv` and the `*_comparison.csv` files against AEMO's published values into `<out>/<YYYYMMDD_HHMMSS>/`, with a `done` marker (or `error.txt`). |
| `cbc_workaround.py` | Routes every CBC call through a Python wrapper and disables garbage collection; without it CBC segfaults after `Cbc_solve` in some environments. |

## Setup

```bash
# Python 3.11 environment (uv); nempy at the pinned commit, installed editable from a clone
uv venv --python 3.11 ~/nempy-venv
git clone https://github.com/UNSW-CEEM/nempy ~/nempy && git -C ~/nempy checkout 2d3cef0
uv pip install --python ~/nempy-venv/bin/python -e ~/nempy \
    mip==1.16rc0 pandas==2.1.4 numpy==1.26.* duckdb pyarrow
```

Then pass the interpreter and the clone to the Julia script, or export them once:

```bash
export NEMPY_PYTHON=~/nempy-venv/bin/python
export NEMPY_SRC=~/nempy/src      # only needed when nempy is not pip-installed
```

`curl` must be on the PATH for the downloads.

## How `compare_dispatch.jl` calls it

For the intervals without a `done` marker it writes `<nempy-dir>/intervals.txt`
(`YYYY/MM/DD HH:MM:SS`, the interval end) and runs, with `run(...)`:

```bash
python fetch_xml.py --intervals-file F --xml-cache <nempy-dir>/xml_cache --dl-dir <nempy-dir>/dl
python build_db.py --db <nempy-dir>/db/historical_mms.db --intervals-file F --cache <hive> --tmp <tmp> --memory-limit 3GB
python run_interval_xml.py --db <nempy-dir>/db/historical_mms.db --xml-cache <nempy-dir>/xml_cache \
    --out <nempy-dir>/out --intervals-file CHUNK    # chunks of 25 intervals
```

`--nempy-dir` defaults to `<out>/nempy`; point several runs at one directory to share the
downloaded XML. `--no-fetch` skips `fetch_xml.py`. One interval takes about 5 s and 300 MB.

The nempy numbers are computed against the pricing run (`INTERVENTION = 0`) tables.
