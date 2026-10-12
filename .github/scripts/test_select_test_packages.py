import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("select_test_packages.py")
ALL = [
    "AustralianElectricityMarkets",
    "AustralianElectricityMarketsCache",
    "AustralianElectricityMarketsData",
    "AustralianElectricityMarketsSimulations",
]


class PackageSelectionTests(unittest.TestCase):
    def select(self, *args, cwd=None):
        result = subprocess.run(
            [sys.executable, str(SCRIPT), *args],
            cwd=cwd,
            env={k: v for k, v in os.environ.items() if k not in ("GITHUB_OUTPUT", "GITHUB_STEP_SUMMARY")},
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_package_and_shared_changes_select_consumers(self):
        cases = [
            (["AustralianElectricityMarketsSimulations/src/formulations/fcas.jl"], [ALL[3]]),
            (["AustralianElectricityMarketsSimulations/test/fcas_market.jl"], [ALL[3]]),
            (["AustralianElectricityMarketsData/src/populate.jl"], [ALL[0], ALL[2]]),
            (["AustralianElectricityMarketsData/test/runtests.jl"], [ALL[2]]),
            (["AustralianElectricityMarketsCache/src/connection.jl"], ALL),
            (["AustralianElectricityMarketsCache/test/runtests.jl"], [ALL[1]]),
            (["src/readers/demand.jl"], [ALL[0], ALL[3]]),
            (["test/datareader.jl"], [ALL[0]]),
            (["test/fixtures/mock_data.jl"], [ALL[0], ALL[2], ALL[3]]),
            (["test/integration/pscb_fixture.jl"], [ALL[0], ALL[3]]),
            (["test/integration/pscb_nemweb_data.jl"], [ALL[0], ALL[3]]),
            (["test/integration/pscb_constraints.jl"], [ALL[0]]),
            (["data/ISP2025/asset.csv"], [ALL[0], ALL[3]]),
            (["Project.toml"], ALL),
            (["Manifest.toml"], ALL),
            (["AustralianElectricityMarketsData/Project.toml"], ALL),
            (["AustralianElectricityMarketsSimulations/test/Project.toml"], ALL),
            (["docs/Project.toml"], ALL),
            ([".github/workflows/Test.yml"], ALL),
            ([".github/scripts/select_test_packages.py"], ALL),
            (["README.md", "docs/src/index.md"], []),
            (["AustralianElectricityMarketsData/README.md"], []),
            ([], []),
            (["test/datareader.jl", "test/datareader.jl"], [ALL[0]]),
        ]
        for paths, expected in cases:
            with self.subTest(paths=paths):
                projects = self.select("--paths", *paths)
                self.assertEqual([p["package"] for p in projects], expected)
                for project in projects:
                    self.assertEqual(
                        project["project"],
                        "." if project["package"] == ALL[0] else project["package"],
                    )
        return

    def test_github_outputs_include_empty_selection(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory, "output")
            summary = Path(directory, "summary")
            result = subprocess.run(
                [sys.executable, str(SCRIPT), "--paths", "README.md"],
                env={**os.environ, "GITHUB_OUTPUT": str(output), "GITHUB_STEP_SUMMARY": str(summary)},
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            values = dict(line.split("=", 1) for line in output.read_text().splitlines())
            self.assertEqual(json.loads(values["projects"]), [])
            self.assertEqual(values["has_tests"], "false")
            self.assertIn("no test inputs changed", summary.read_text())
        return

    def test_full_runs(self):
        self.assertEqual([p["package"] for p in self.select("--all")], ALL)
        with tempfile.TemporaryDirectory() as directory:
            event = Path(directory, "event.json")
            for name, payload in [
                ("workflow_dispatch", {}),
                ("push", {"ref": "refs/tags/v1", "before": "a" * 40}),
                ("push", {"ref": "refs/heads/main", "before": "0" * 40}),
                ("push", {"ref": "refs/heads/main", "before": "a" * 40, "after": "b" * 40}),
            ]:
                with self.subTest(name=name, payload=payload):
                    event.write_text(json.dumps(payload))
                    projects = self.select("--event", name, "--event-file", str(event), cwd=directory)
                    self.assertEqual([p["package"] for p in projects], ALL)
        return

    def test_git_ranges_and_cross_package_renames(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)

            def git(*args):
                return subprocess.check_output(["git", *args], cwd=root, text=True).strip()

            git("init", "-q")
            git("config", "user.email", "ci@example.com")
            git("config", "user.name", "CI test")
            original = root / "AustralianElectricityMarketsData/src/file.jl"
            original.parent.mkdir(parents=True)
            original.write_text("initial\n")
            git("add", ".")
            git("commit", "-qm", "base")
            base = git("rev-parse", "HEAD")
            git("checkout", "-qb", "feature")
            moved = root / "AustralianElectricityMarketsSimulations/src/file.jl"
            moved.parent.mkdir(parents=True)
            original.rename(moved)
            git("add", "-A")
            git("commit", "-qm", "move between packages")
            head = git("rev-parse", "HEAD")
            event = root / "event.json"
            event.write_text(json.dumps({"ref": "refs/heads/main", "before": base, "after": head}))
            selected = self.select("--event", "push", "--event-file", str(event), cwd=root)
            self.assertEqual([p["package"] for p in selected], [ALL[0], ALL[2], ALL[3]])

            # Base-only changes must not select extra suites for a pull request.
            git("checkout", "-qb", "base-advanced", base)
            cache = root / "AustralianElectricityMarketsCache/src/file.jl"
            cache.parent.mkdir(parents=True)
            cache.write_text("base-only\n")
            git("add", str(cache.relative_to(root)))
            git("commit", "-qm", "advance base")
            advanced = git("rev-parse", "HEAD")
            event.write_text(json.dumps({"pull_request": {"base": {"sha": advanced}, "head": {"sha": head}}}))
            selected = self.select("--event", "pull_request", "--event-file", str(event), cwd=root)
            self.assertEqual([p["package"] for p in selected], [ALL[0], ALL[2], ALL[3]])
        return


if __name__ == "__main__":
    unittest.main()
