"""Select monorepo test suites from changed paths or a GitHub event."""

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys


PROJECTS = {
    "AustralianElectricityMarkets": ".",
    "AustralianElectricityMarketsCache": "AustralianElectricityMarketsCache",
    "AustralianElectricityMarketsData": "AustralianElectricityMarketsData",
    "AustralianElectricityMarketsSimulations": "AustralianElectricityMarketsSimulations",
}
ROOT = "AustralianElectricityMarkets"
CACHE = "AustralianElectricityMarketsCache"
DATA = "AustralianElectricityMarketsData"
SIMULATIONS = "AustralianElectricityMarketsSimulations"


def select_packages(paths):
    selected = set()
    for path in paths:
        # All projects share dependency resolution through the workspace manifest.
        if path.endswith(".toml") or path == ".github/workflows/Test.yml" or path.startswith(".github/scripts/"):
            selected.update(PROJECTS)
        elif path.startswith(f"{CACHE}/test/"):
            selected.add(CACHE)
        elif path.startswith(f"{CACHE}/src/"):
            selected.update(PROJECTS)
        elif path.startswith(f"{DATA}/test/"):
            selected.add(DATA)
        elif path.startswith(f"{DATA}/src/"):
            # Root package-boundary tests exercise population alongside the readers.
            selected.update([DATA, ROOT])
        elif path.startswith((f"{SIMULATIONS}/src/", f"{SIMULATIONS}/test/")):
            selected.add(SIMULATIONS)
        elif path.startswith(("src/", "data/")):
            selected.update([ROOT, SIMULATIONS])
        elif path.startswith("test/fixtures/"):
            selected.update([ROOT, DATA, SIMULATIONS])
        elif path in ("test/integration/pscb_fixture.jl", "test/integration/pscb_nemweb_data.jl"):
            selected.update([ROOT, SIMULATIONS])
        elif path.startswith("test/"):
            selected.add(ROOT)
    return [{"package": name, "project": project} for name, project in PROJECTS.items() if name in selected]


def event_paths(event_name, event):
    if event_name == "pull_request":
        base = event["pull_request"]["base"]["sha"]
        head = event["pull_request"]["head"]["sha"]
        revisions = f"{base}...{head}"
    elif event_name == "push" and not event.get("ref", "").startswith("refs/tags/"):
        base = event.get("before", "")
        if not base or set(base) == {"0"}:
            return None
        revisions = f"{base}..{event['after']}"
    else:
        return None
    try:
        # Disable rename detection so both the old and new package paths are selected.
        result = subprocess.run(
            ["git", "diff", "--name-only", "--no-renames", "-z", revisions, "--"],
            check=True,
            capture_output=True,
        )
    except subprocess.CalledProcessError:
        print("Cannot compare Git revisions; running all package suites.", file=sys.stderr)
        return None
    return os.fsdecode(result.stdout).split("\0")[:-1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--paths", nargs="*")
    source.add_argument("--all", action="store_true")
    source.add_argument("--event-file", type=Path)
    parser.add_argument("--event", default=os.environ.get("GITHUB_EVENT_NAME"))
    args = parser.parse_args()
    paths = None if args.all else args.paths
    if args.event_file:
        paths = event_paths(args.event, json.loads(args.event_file.read_text()))
    projects = select_packages(paths) if paths is not None else [
        {"package": name, "project": project} for name, project in PROJECTS.items()
    ]
    value = json.dumps(projects, separators=(",", ":"))
    print(value)
    if output := os.environ.get("GITHUB_OUTPUT"):
        with open(output, "a") as stream:
            stream.write(f"projects={value}\nhas_tests={str(bool(projects)).lower()}\n")
    if summary := os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(summary, "a") as stream:
            names = ", ".join(project["package"] for project in projects) or "None (no test inputs changed)"
            stream.write(f"Selected test suites: {names}\n")
    return


if __name__ == "__main__":
    main()
