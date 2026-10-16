"""Offline checks only. Synthetic readings do not validate physical hardware."""
import argparse
import csv
import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import numpy as np

import collect_data
import live_fall_detection as live
from calibrate_gyro import estimate_calibration, load_gyro_bias
from six_axis_data import read_sensor_vectors, resolve_recording
from extract_recording_features import validate_feature_columns, summarize
from stream_health import StreamHealth, positive_seconds
from test_serial_samples import FakeSerial


def stationary_rows():
    return [{"elapsed_s": str(i / 10), "ax": "0", "ay": "0", "az": "9.80665",
             "gx": "0.01", "gy": "-0.02", "gz": "0.03",
             "label": "stationary_calibration", "placement": "bench",
             "acceleration_unit": "m/s^2", "gyroscope_unit": "rad/s"} for i in range(100)]


class CalibrationTests(unittest.TestCase):
    def test_stationary_bias_roundtrip_and_correction(self):
        result = estimate_calibration(stationary_rows())
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "bias.json"
            with path.open("w") as target:
                json.dump(result, target)
            bias = load_gyro_bias(path)
        np.testing.assert_allclose(bias, [.01, -.02, .03])
        np.testing.assert_allclose(np.array([.01, -.02, .03]) - bias, 0, atol=1e-12)

    def test_rejects_movement_bad_acceleration_gaps_units_and_nonfinite(self):
        changes = [("az", "8.9"), ("gx", "nan"), ("gx", "0.4"),
                   ("gyroscope_unit", "deg/s"), ("label", "walking"),
                   ("elapsed_s", "20")]
        for key, value in changes:
            rows = stationary_rows()
            rows[20][key] = value
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                estimate_calibration(rows)
        rows = stationary_rows()
        for row in rows:
            row["az"] = "8.9"
        with self.assertRaisesRegex(ValueError, "acceleration"):
            estimate_calibration(rows)

    def test_missing_samples_and_wrong_json_rejected(self):
        with self.assertRaises(ValueError):
            estimate_calibration(stationary_rows()[:20])
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "bad.json"
            with path.open("w") as target:
                json.dump({"schema_version": 1, "sensor": "MPU6050", "gyroscope_unit": "rad/s",
                           "bias_rads": [0, float("nan"), 0]}, target)
            with self.assertRaises(ValueError):
                load_gyro_bias(path)


class ReaderTests(unittest.TestCase):
    def test_only_two_sensor_streams_and_empty_shape(self):
        data = "i,x,y,z,t,sensor\n0,1,2,3,0,acg\n1,9,9,9,0,mgm\n2,4,5,6,0,gyro\n"
        with patch.object(Path, "open", return_value=io.StringIO(data)):
            vectors, count = read_sensor_vectors(Path("unused"))
        self.assertEqual(set(vectors), {"acg", "gyro"})
        self.assertEqual(count, 3)
        np.testing.assert_array_equal(vectors["gyro"], [[4, 5, 6]])
        with patch.object(Path, "open", return_value=io.StringIO("i,x,y,z,t,sensor\n")):
            vectors, _ = read_sensor_vectors(Path("unused"))
        self.assertEqual(vectors["gyro"].shape, (0, 3))

    def test_invalid_data_and_path_escape_rejected(self):
        with patch.object(Path, "open", return_value=io.StringIO("header\n0,nan,0,0,0,acg\n")):
            with self.assertRaises(ValueError):
                read_sensor_vectors(Path("unused"))
        with self.assertRaises(ValueError):
            resolve_recording(Path("/tmp/example"), "../other.csv")

    def test_live_rejects_incompatible_model_features(self):
        with self.assertRaisesRegex(ValueError, "six-axis"):
            live.predict({"feature_columns": ["unrelated_feature"]}, np.zeros((40, 3)), np.zeros((40, 3)))

    def test_training_schema_accepts_only_current_features(self):
        columns = list(summarize(np.zeros((2, 3)), "acc")) + list(summarize(np.zeros((2, 3)), "gyro"))
        validate_feature_columns(columns)
        with self.assertRaises(ValueError):
            validate_feature_columns(columns + ["extra_channel"])


class HealthTests(unittest.TestCase):
    def test_gap_and_no_data_expiry(self):
        now = [0.0]
        health = StreamHealth(clock=lambda: now[0])
        self.assertFalse(health.accept())
        now[0] = 3
        self.assertTrue(health.accept())
        now[0] = 13
        with self.assertRaisesRegex(RuntimeError, "no serial text"):
            health.check("")

    def test_bad_text_does_not_keep_session_alive(self):
        now = [0.0]
        health = StreamHealth(clock=lambda: now[0])
        for second in range(10):
            now[0] = second
            health.check("garbage")
        now[0] = 10
        with self.assertRaisesRegex(RuntimeError, "no complete six-axis"):
            health.check("garbage")

    def test_duration_validation(self):
        for value in ("nan", "inf", "0", "-1"):
            with self.assertRaises(argparse.ArgumentTypeError):
                positive_seconds(value)

    def test_timed_collection_placement_and_subject_saved(self):
        now = [0.0]
        device = FakeSerial(["0,0,9.80665,0,0,0"] * 10)
        original = device.readline

        def read():
            now[0] += .5
            return original()

        with tempfile.TemporaryDirectory() as folder:
            with patch("sys.argv", ["collect_data.py", "--port", "FAKE", "--duration", "1",
                                    "--subject-id", "p01", "--label", "standing", "--output-dir", folder]), \
                    patch.object(collect_data.serial, "Serial", return_value=device), \
                    patch.object(device, "readline", side_effect=read), \
                    patch.object(collect_data.time, "sleep"), \
                    patch.object(collect_data.time, "monotonic", side_effect=lambda: now[0]), \
                    patch("builtins.print"):
                collect_data.main()
            paths = list(Path(folder).rglob("standing_lower_back_center_waist_*.csv"))
            self.assertEqual(len(paths), 1)
            self.assertEqual(paths[0].parent.relative_to(folder), Path("p01/standing"))
            with paths[0].open() as source:
                rows = list(csv.DictReader(source))
            self.assertEqual(len(rows), 2)
            self.assertEqual(rows[0]["placement"], "lower_back_center_waist")
            self.assertEqual(rows[0]["subject_id"], "p01")
            self.assertFalse(device.is_open)

    def test_silent_serial_timeout_closes_without_creating_csv(self):
        now = [0.0]
        device = FakeSerial([])

        def read():
            now[0] += 1
            return b""

        with tempfile.TemporaryDirectory() as folder:
            with patch("sys.argv", ["collect_data.py", "--port", "FAKE", "--output-dir", folder]), \
                    patch.object(collect_data.serial, "Serial", return_value=device), \
                    patch.object(device, "readline", side_effect=read), \
                    patch.object(collect_data.time, "sleep"), \
                    patch.object(collect_data.time, "monotonic", side_effect=lambda: now[0]), \
                    patch("builtins.print") as output:
                collect_data.main()
            self.assertEqual(list(Path(folder).iterdir()), [])
            self.assertFalse(device.is_open)
            self.assertTrue(any("received no serial text" in str(call) for call in output.call_args_list))


if __name__ == "__main__":
    unittest.main()
