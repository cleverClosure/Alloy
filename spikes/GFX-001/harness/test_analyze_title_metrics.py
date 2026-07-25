#!/usr/bin/env python3
"""Tests for the GFX-001 title-metrics analyzer.

Author: Timur Isaev
"""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("analyze-title-metrics.py")


class AnalyzeTitleMetricsTests(unittest.TestCase):
    def test_summarizes_pacing_stalls_and_memory(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            metrics = root / "metrics.tsv"
            memory = root / "memory.tsv"
            output = root / "summary.json"

            metrics.write_text(
                "timestamp_ns\tevent\tobject\tduration_ns\tstatus\tdetail\n"
                "1000000\tshader\t1\t100000\tok\tcache:vs_a\n"
                "2000000\tpresent\t1\t10000\tok\t\n"
                "18667000\tpresent\t2\t20000\tok\t\n"
                "20000000\tshader\t2\t5000000\tok\tcompile:ps_b\n"
                "52000000\tpipeline\t3\t2000000\tok\tgraphics\n"
                "52001000\tpresent\t3\t30000\tok\t\n",
                encoding="utf-8",
            )
            memory.write_text(
                "elapsed_s\tpid\trss_kb\tvsz_kb\tpercent_mem\n"
                "0\t42\t102400\t204800\t1.0\n"
                "10\t42\t112640\t225280\t1.1\n"
                "20\t42\t122880\t245760\t1.2\n",
                encoding="utf-8",
            )

            completed = subprocess.run(
                [
                    sys.executable,
                    "-B",
                    str(SCRIPT),
                    str(metrics),
                    "--memory",
                    str(memory),
                    "--output",
                    str(output),
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)

            result = json.loads(output.read_text(encoding="utf-8"))
            frame_pacing = result["metrics"]["framePacing"]
            input_ordering = result["metrics"]["inputOrdering"]
            self.assertEqual(frame_pacing["presentCount"], 3)
            self.assertEqual(frame_pacing["firstPresentTimestampMs"], 2.0)
            self.assertEqual(frame_pacing["intervalMs"]["count"], 2)
            self.assertEqual(frame_pacing["thresholdCounts"]["over33_333ms"], 1)
            self.assertEqual(result["metrics"]["shader"]["cacheHitCount"], 1)
            self.assertEqual(result["metrics"]["shader"]["compileCount"], 1)
            self.assertEqual(result["metrics"]["pipeline"]["eventCount"], 1)
            self.assertEqual(input_ordering["adjacentReversalCount"], 0)
            self.assertEqual(input_ordering["maximumBackwardNs"], 0)
            self.assertTrue(input_ordering["stablySortedByTimestamp"])

            longest = frame_pacing["longestFrames"][0]
            self.assertEqual(longest["intervalMs"], 33.334)
            self.assertEqual(
                [event["event"] for event in longest["correlatedEvents"]],
                ["shader", "pipeline"],
            )

            rss = result["memory"]["rssMiB"]
            self.assertEqual(rss["start"], 100.0)
            self.assertEqual(rss["end"], 120.0)
            self.assertEqual(rss["delta"], 20.0)
            self.assertEqual(rss["linearSlopeMiBPerHour"], 3600.0)
            self.assertEqual(rss["tailHalf"]["delta"], 10.0)
            self.assertEqual(rss["tailHalf"]["linearSlopeMiBPerHour"], 3600.0)
            self.assertEqual(result["memory"]["virtualMiB"]["tailHalf"]["delta"], 20.0)

            trimmed_output = root / "trimmed.json"
            completed = subprocess.run(
                [
                    sys.executable,
                    "-B",
                    str(SCRIPT),
                    str(metrics),
                    "--start-seconds",
                    "0.002",
                    "--output",
                    str(trimmed_output),
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)

            trimmed = json.loads(trimmed_output.read_text(encoding="utf-8"))
            trimmed_pacing = trimmed["metrics"]["framePacing"]
            self.assertEqual(trimmed_pacing["presentCount"], 2)
            self.assertEqual(trimmed_pacing["firstPresentTimestampMs"], 18.667)
            self.assertEqual(trimmed_pacing["intervalMs"]["count"], 1)

    def test_stably_sorts_worker_thread_writes_and_reports_reversals(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            metrics = root / "worker-order.tsv"
            output = root / "summary.json"

            metrics.write_text(
                "timestamp_ns\tevent\tobject\tduration_ns\tstatus\tdetail\n"
                "1000000\tpresent\t1\t10000\tok\t\n"
                "3000000\tpresent\t2\t10000\tok\t\n"
                "2000000\tshader\t3\t500000\tok\tcompile:ps_worker\n"
                "5000000\tpresent\t4\t10000\tok\t\n",
                encoding="utf-8",
            )

            completed = subprocess.run(
                [
                    sys.executable,
                    "-B",
                    str(SCRIPT),
                    str(metrics),
                    "--output",
                    str(output),
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)

            result = json.loads(output.read_text(encoding="utf-8"))
            analyzed = result["metrics"]
            self.assertEqual(analyzed["inputOrdering"]["adjacentReversalCount"], 1)
            self.assertEqual(analyzed["inputOrdering"]["maximumBackwardNs"], 1000000)
            self.assertEqual(analyzed["framePacing"]["presentCount"], 3)
            self.assertEqual(analyzed["framePacing"]["intervalMs"]["count"], 2)
            self.assertEqual(
                [
                    event["detail"]
                    for event in analyzed["framePacing"]["longestFrames"][0][
                        "correlatedEvents"
                    ]
                ],
                ["compile:ps_worker"],
            )


if __name__ == "__main__":
    unittest.main()
