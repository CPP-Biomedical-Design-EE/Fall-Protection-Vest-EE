"""Tests for offline analysis of collector recordings."""

import csv
import tempfile
import unittest
from pathlib import Path

import numpy as np

from analyze_recording import GRAVITY, analyze_recording


FIELDS = (
    "elapsed_s", "label", "subject_id", "ax", "ay", "az", "gx", "gy", "gz",
    "acceleration_unit", "gyroscope_unit", "stream_discontinuity", "sample_interval_s",
)


class AnalyzeRecordingTests(unittest.TestCase):
    def write_recording(self, folder, rows):
        path = Path(folder) / "recording.csv"
        with path.open("w", newline="", encoding="utf-8") as target:
            writer = csv.DictWriter(target, fieldnames=FIELDS)
            writer.writeheader()
            writer.writerows(rows)
        return path

    def test_calculates_magnitudes_and_acceleration_direction_change(self):
        with tempfile.TemporaryDirectory() as folder:
            rows = [
                {"elapsed_s": "0.00", "label": "jump", "subject_id": "P01",
                 "ax": "0", "ay": "0", "az": str(GRAVITY), "gx": "0", "gy": "0", "gz": "0",
                 "acceleration_unit": "m/s^2", "gyroscope_unit": "rad/s", "stream_discontinuity": "0",
                 "sample_interval_s": ""},
                {"elapsed_s": "0.01", "label": "jump", "subject_id": "P01",
                 "ax": "0", "ay": "0", "az": str(GRAVITY), "gx": "0", "gy": "0", "gz": "1",
                 "acceleration_unit": "m/s^2", "gyroscope_unit": "rad/s", "stream_discontinuity": "0",
                 "sample_interval_s": "0.010000"},
                {"elapsed_s": "0.02", "label": "jump", "subject_id": "P01",
                 "ax": str(GRAVITY), "ay": "0", "az": "0", "gx": "0", "gy": "0", "gz": "0",
                 "acceleration_unit": "m/s^2", "gyroscope_unit": "rad/s", "stream_discontinuity": "1",
                 "sample_interval_s": "0.010000"},
            ]
            path = self.write_recording(folder, rows)
            metadata, signals, summary = analyze_recording(path, reference_seconds=0.01)

        self.assertEqual(metadata, {"label": "jump", "subject_id": "P01"})
        np.testing.assert_allclose(signals["acceleration_g"], [1, 1, 1])
        self.assertAlmostEqual(signals["gyroscope_dps"][1], np.rad2deg(1))
        self.assertAlmostEqual(signals["acceleration_direction_change_deg"][2], 90)
        self.assertAlmostEqual(summary["estimated_sample_rate_hz"], 100)
        self.assertEqual(summary["sample_rate_source"], "device sample intervals")
        self.assertEqual(summary["stream_discontinuities"], 1)

    def test_rejects_unexpected_units(self):
        with tempfile.TemporaryDirectory() as folder:
            rows = [{"elapsed_s": "0", "label": "walk", "subject_id": "P01",
                     "ax": "0", "ay": "0", "az": str(GRAVITY), "gx": "0", "gy": "0", "gz": "0",
                     "acceleration_unit": "g", "gyroscope_unit": "rad/s", "stream_discontinuity": "0"}]
            path = self.write_recording(folder, rows)
            with self.assertRaisesRegex(ValueError, "m/s\^2 and rad/s"):
                analyze_recording(path)


if __name__ == "__main__":
    unittest.main()