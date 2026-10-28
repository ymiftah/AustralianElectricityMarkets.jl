"""Regression tests for saved replay analysis; no Julia or market data required."""

import csv
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
import simulation_statistics as report


class ReplayStatisticsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def csv(self, path, fields, rows):
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("w", newline="") as stream:
            writer = csv.writer(stream)
            writer.writerow(fields)
            writer.writerows(rows)

    def day(self, name="run", completed=True):
        run = self.root / name
        day = run / "2026-04-07"
        day.mkdir(parents=True)
        (day / "provenance.toml").write_text('revision = "abc"\nhdf5 = "0.17.5"\n')
        if completed:
            self.csv(run / "days.csv", ["trading_day", "status", "elapsed_s", "execute_s"],
                     [[day.name, "completed", 100, 80]])
        return run, day

    def dispatch(self, day, rows):
        self.csv(day / "comparison_dispatch.csv",
                 ["SETTLEMENTDATE", "DUID", "TOTALCLEARED_published", "TOTALCLEARED_solved"], rows)

    def test_signed_and_absolute_percentiles(self):
        stats = report.error_distribution([-10, 0, 2])
        self.assertAlmostEqual(stats["mae"], 4)
        self.assertAlmostEqual(stats["bias"], -8 / 3)
        self.assertAlmostEqual(stats["p95"], 9.2)
        self.assertAlmostEqual(stats["signed_p5"], -9)
        self.assertEqual(report.distribution([])["n"], 0)

    def test_missing_duplicate_and_out_of_day_rows_are_not_zero_filled(self):
        run, day = self.day()
        self.dispatch(day, [
            ["2026-04-07T04:05:00", "A", 10, 12],
            ["2026-04-07T04:10:00", "A", 3, ""],
            ["2026-04-07T04:15:00", "A", 0, 1],
            ["2026-04-07T04:15:00", "A", 0, 7],
            ["2026-04-08T04:05:00", "A", 0, 9],
        ])
        stats = report.analyze([run])["days"][0]["comparisons"]["dispatch_mw"]
        self.assertEqual(stats["errors"]["n"], 1)
        self.assertEqual(stats["errors"]["mae"], 2)
        self.assertEqual(stats["missing_nonzero_published"], 1)
        self.assertEqual(stats["duplicate_keys"], 1)
        self.assertEqual(stats["out_of_day_rows"], 1)
        self.assertEqual(stats["groups"]["A"]["paired_intervals"], 1)

    def test_overlapping_days_and_partial_days_excluded_from_pool(self):
        first, a = self.day("one")
        second, b = self.day("two")
        partial, c = self.day("partial", completed=False)
        for day in [a, b, c]:
            self.dispatch(day, [["2026-04-07T04:05:00", "A", 1, 2]])
        result = report.analyze([first, second, partial])
        self.assertEqual(result["pooled"]["dispatch_mw"]["n"], 1)
        self.assertEqual(result["unique_completed_days"], 1)
        self.assertEqual(result["days"][2]["status"], "in_progress")
        self.assertTrue(any("overlap" in x for x in result["warnings"]))

    def test_nested_solve_timers_not_added_to_parent_twice(self):
        run, day = self.day()
        fields = ["phase", "execution_count", "interval_aest", "wall_s",
                  "timed_solve_s", "pricing_s", "auxiliary_s"]
        self.csv(day / "chunk_1/problems/dispatch/interval_timings.csv", fields, [
            ["solve_impl", 0, "2026-04-07T04:05:00", 50, 40, 8, 1],
            ["result_write", 0, "2026-04-07T04:05:00", 5, "NaN", "NaN", "NaN"],
            ["parameter_update", 1, "2026-04-07T04:10:00", 10, "NaN", "NaN", "NaN"],
        ])
        timings = report.analyze([run])["days"][0]["timing"]
        self.assertEqual(timings["execution_unattributed_s"], 15)
        self.assertEqual(timings["series"]["mip"]["total_s"], 40)
        self.assertEqual(timings["series"]["solve_wrapper_residual"]["total_s"], 1)

    def test_schema_two_solve_and_write_rows_are_counted(self):
        run, day = self.day()
        fields = ["phase", "execution_count", "interval_aest", "wall_s", "timed_solve_s", "pricing_s", "auxiliary_s", "schema_version"]
        self.csv(day / "chunk_1/problems/dispatch/interval_timings.csv", fields, [
            ["parameter_update", 0, "2026-04-07T04:05:00", 4, "NaN", "NaN", "NaN", 2],
            ["solve_and_write", 0, "2026-04-07T04:05:00", 50, 40, 8, 1, 2],
        ])
        timings = report.analyze([run])["days"][0]["timing"]
        self.assertEqual(timings["written_intervals"], 1)
        self.assertEqual(timings["series"]["mip"]["total_s"], 40)
        self.assertEqual(timings["series"]["solve_and_write"]["total_s"], 50)

    def test_incomplete_final_csv_record_is_ignored(self):
        path = self.root / "memory.csv"
        path.write_text("timestamp,rss_mib\na,100\nb,2")
        warnings = []
        self.assertEqual(list(report.read_csv(path, warnings)), [{"timestamp": "a", "rss_mib": "100"}])
        self.assertTrue(warnings)

    def test_cumulative_native_snapshots_use_last_total(self):
        run, day = self.day()
        for chunk, calls, seconds in [(1, 1, 6), (2, 2, 10)]:
            (day / f"timers_execute_chunk_{chunk}.toml").write_text(
                '[inner_timers."Execute Simulation"]\n'
                f'n_calls = {calls}\n'
                '[inner_timers."Execute Simulation".inner_timers."Execute dispatch".inner_timers."Update State"]\n'
                f'time_ns = {seconds * 10**9}\n')
        self.assertEqual(report.analyze([run])["days"][0]["timing"]["native_state_s"], 10)

    def test_missing_regions_are_visible_and_outputs_are_serializable(self):
        run, day = self.day()
        self.csv(day / "comparison_prices.csv",
                 ["SETTLEMENTDATE", "REGIONID", "ROP_published", "ROP_solved", "RRP_published"],
                 [["2026-04-07T04:05:00", "NSW1", 10, 12, 999]])
        result = report.analyze([run])
        comparison = result["days"][0]["comparisons"]["energy_price"]
        self.assertEqual(comparison["errors"]["mae"], 2)
        self.assertEqual(comparison["groups"]["TAS1"]["n"], 0)
        self.assertEqual(comparison["groups"]["TAS1"]["expected_intervals"], 288)
        output = self.root / "report"
        report.save_report(result, output)
        self.assertTrue((output / "report.md").exists())
        self.assertTrue((output / "statistics.json").exists())


if __name__ == "__main__":
    unittest.main()
