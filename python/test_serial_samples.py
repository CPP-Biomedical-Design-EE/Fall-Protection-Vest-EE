"""Offline protocol tests; no board or serial connection required."""

import unittest
import csv
import tempfile
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import numpy as np

from serial_samples import GRAVITY, SerialSampleParser
from esp32_serial import open_esp32
import esp32_serial
import collect_data
import live_fall_detection as live
import threshold_detection as threshold

BLOCK = [
    "--- ACCELEROMETER ---", "X = -0.125 m/s^2    -0.013 g",
    "Y = 0.250 m/s^2    0.025 g", "Z = 9.807 m/s^2    1.000 g",
    "--- GYROSCOPE ---", "X = 0.010 rad/s    0.573 deg/s",
    "Y = -0.020 rad/s    -1.146 deg/s", "Z = 0.030 rad/s    1.719 deg/s",
]
EXPECTED = [-0.125, 0.250, 9.807, 0.010, -0.020, 0.030]


def feed_all(parser, lines):
    results = []
    for line in lines:
        sample = parser.feed(line)
        if sample is not None:
            results.append(sample)
    return results


class ParserTests(unittest.TestCase):
    def test_andy_output_one_sample_per_block_in_si_units(self):
        parser = SerialSampleParser(acceleration_unit="g", gyroscope_unit="dps")
        startup = ["MPU6050 detected successfully!", "", "Configuration:",
                   "Accelerometer Range = +/- 8 g", "...Starting measurements..."]
        trailer = ["--- TEMPERATURE ---", "Temperature = 26.20 C", ""]
        self.assertEqual(feed_all(parser, startup + BLOCK + trailer + BLOCK), [EXPECTED] * 2)

    def test_csv_compatibility_and_conversion(self):
        parser = SerialSampleParser(acceleration_unit="g", gyroscope_unit="dps")
        self.assertIsNone(parser.feed("ax,ay,az,gx,gy,gz"))
        np.testing.assert_allclose(parser.feed("0,0,1,180,0,-180"),
                                   [0, 0, GRAVITY, np.pi, 0, -np.pi])
        for line in ("1,2,3,4,5", "1,2,3,4,5,6,7", "0,0,nan,0,0,0", "0,0,inf,0,0,0"):
            with self.assertRaises(ValueError):
                parser.feed(line)

    def test_partial_block_restarts_at_next_header(self):
        parser = SerialSampleParser()
        self.assertEqual(feed_all(parser, BLOCK[:3] + BLOCK), [EXPECTED])
        self.assertEqual(feed_all(SerialSampleParser(), BLOCK[4:]), [])

    def test_corrupt_duplicate_reordered_units_and_nonfinite_blocks_recover(self):
        for bad in ("Y = 1 m/s^2 0.1 g", "X = nan m/s^2 0 g",
                    "X = 1e999 m/s^2 0 g", "X = 1 rad/s 1 deg/s", "boot: restart"):
            parser = SerialSampleParser()
            parser.feed(BLOCK[0])
            with self.assertRaises(ValueError):
                parser.feed(bad)
            self.assertEqual(feed_all(parser, BLOCK[2:]), [])
            self.assertEqual(feed_all(parser, BLOCK), [EXPECTED])
        parser = SerialSampleParser()
        feed_all(parser, BLOCK[:2])
        with self.assertRaises(ValueError):
            parser.feed(BLOCK[1])

    def test_error_and_timeout_discard_partial_block(self):
        clock = [0.0]
        parser = SerialSampleParser(clock=lambda: clock[0])
        feed_all(parser, BLOCK[:5])
        clock[0] = 2.0
        self.assertEqual(feed_all(parser, BLOCK[5:]), [])
        feed_all(parser, BLOCK[:2])
        with self.assertRaisesRegex(ValueError, "MPU6050 not detected"):
            parser.feed("ERROR: MPU6050 not detected!")
        self.assertEqual(feed_all(parser, BLOCK[2:]), [])
        self.assertEqual(feed_all(parser, BLOCK), [EXPECTED])

    def test_explicit_formats_and_auto_switch(self):
        self.assertIsNone(SerialSampleParser("andy").feed("1,2,3,4,5,6"))
        self.assertEqual(feed_all(SerialSampleParser("csv"), BLOCK), [])
        parser = SerialSampleParser()
        self.assertEqual(feed_all(parser, BLOCK + ["1,2,3,4,5,6"] + BLOCK),
                         [EXPECTED, [1, 2, 3, 4, 5, 6], EXPECTED])


class FakeSerial:
    def __init__(self, lines):
        self.lines = iter(lines)
        self.dtr = True
        self.rts = True
        self.is_open = False

    def open(self):
        if self.dtr or self.rts:
            raise AssertionError("DTR and RTS must be inactive before opening")
        self.is_open = True

    def close(self):
        self.is_open = False

    def __enter__(self):
        if not self.is_open:
            raise AssertionError("Serial connection was not opened")
        return self

    def __exit__(self, *args):
        self.close()
        return False

    def readline(self):
        try:
            return (next(self.lines) + "\r\n").encode()
        except StopIteration:
            raise KeyboardInterrupt


class SerialConnectionTests(unittest.TestCase):
    def test_control_lines_are_inactive_before_open_and_port_closes(self):
        device = FakeSerial([])
        with patch.object(esp32_serial.serial, "Serial", return_value=device) as factory:
            with open_esp32("FAKE", 115200, timeout=.25) as opened:
                self.assertIs(opened, device)
                self.assertEqual(device.port, "FAKE")
                self.assertTrue(device.is_open)
            factory.assert_called_once_with(port=None, baudrate=115200, timeout=.25)
        self.assertFalse(device.is_open)

    def test_open_failure_closes_connection_and_preserves_error(self):
        device = FakeSerial([])
        with patch.object(esp32_serial.serial, "Serial", return_value=device), \
                patch.object(device, "open", side_effect=esp32_serial.serial.SerialException("busy")), \
                patch.object(device, "close", wraps=device.close) as close:
            with self.assertRaisesRegex(esp32_serial.serial.SerialException, "busy"):
                open_esp32("FAKE")
            close.assert_called_once()


class SerialIntegrationTests(unittest.TestCase):
    def test_collect_preview_uses_complete_andy_sample(self):
        with patch("sys.argv", ["collect_data.py", "--port", "FAKE", "--preview"]), \
                patch.object(collect_data.serial, "Serial", return_value=FakeSerial(BLOCK)), \
                patch.object(collect_data.time, "sleep"), patch("builtins.print") as output:
            collect_data.main()
        self.assertIn(unittest.mock.call("-0.125,0.25,9.807,0.01,-0.02,0.03"), output.call_args_list)

    def test_csv_recording_survives_stop_and_preserves_units_and_label(self):
        with tempfile.TemporaryDirectory() as folder:
            for _ in range(2):
                with patch("sys.argv", ["collect_data.py", "--port", "FAKE", "--label", "standing", "--output-dir", folder]), \
                        patch.object(collect_data.serial, "Serial", return_value=FakeSerial(BLOCK * 2)), \
                        patch.object(collect_data.time, "sleep"), patch("builtins.print"):
                    collect_data.main()
            paths = list(Path(folder).rglob("standing_*.csv"))
            self.assertEqual(len(paths), 2)
            self.assertEqual(paths[0].parent.relative_to(folder), Path("unknown/standing"))
            with paths[0].open(newline="") as saved:
                rows = list(csv.DictReader(saved))
            self.assertEqual(len(rows), 2)
            self.assertEqual(rows[0]["label"], "standing")
            self.assertEqual(rows[0]["acceleration_unit"], "m/s^2")
            self.assertEqual(rows[0]["gyroscope_unit"], "rad/s")
            self.assertEqual(rows[0]["input_format"], "andy")
            np.testing.assert_allclose([float(rows[0][key]) for key in collect_data.FIELD_NAMES], EXPECTED)
            self.assertGreaterEqual(float(rows[1]["elapsed_s"]), float(rows[0]["elapsed_s"]))

    def test_incomplete_input_does_not_create_csv(self):
        with tempfile.TemporaryDirectory() as folder:
            with patch("sys.argv", ["collect_data.py", "--port", "FAKE", "--output-dir", folder]), \
                    patch.object(collect_data.serial, "Serial", return_value=FakeSerial(BLOCK[:3])), \
                    patch.object(collect_data.time, "sleep"), patch("builtins.print"):
                collect_data.main()
            self.assertEqual(list(Path(folder).iterdir()), [])

    def test_live_detector_receives_two_complete_samples(self):
        args = SimpleNamespace(port="FAKE", baud=115200, input_format="auto",
                               acceleration_unit="mps2", gyroscope_unit="rads",
                               show_bad_lines=True, threshold=.7, consecutive_windows=2)
        with patch.object(live.serial, "Serial", return_value=FakeSerial(BLOCK * 2)), \
                patch.object(live.time, "sleep"), patch("builtins.print"), \
                patch.object(live, "predict", return_value=.1) as predict:
            with self.assertRaises(KeyboardInterrupt):
                live.run_serial(args, {"window_samples": 2, "step_samples": 1})
        self.assertEqual(predict.call_count, 1)
        np.testing.assert_allclose(predict.call_args.args[1], [EXPECTED[:3]] * 2)
        np.testing.assert_allclose(predict.call_args.args[2], [EXPECTED[3:]] * 2)

    def test_live_gap_discards_previous_window_and_applies_optional_bias(self):
        args = SimpleNamespace(port="FAKE", baud=115200, input_format="auto",
                               acceleration_unit="mps2", gyroscope_unit="rads",
                               show_bad_lines=True, threshold=.7, consecutive_windows=2)
        with patch.object(live.serial, "Serial", return_value=FakeSerial(BLOCK * 3)), \
                patch.object(live.time, "sleep"), patch("builtins.print"), \
                patch.object(live.StreamHealth, "accept", side_effect=[False, True, False]), \
                patch.object(live, "load_gyro_bias", return_value=np.array(EXPECTED[3:])), \
                patch.object(live, "predict", return_value=.1) as predict:
            with self.assertRaises(KeyboardInterrupt):
                live.run_serial(args, {"window_samples": 2, "step_samples": 1})
        self.assertEqual(predict.call_count, 1)
        np.testing.assert_allclose(predict.call_args.args[2], np.zeros((2, 3)))

    def test_threshold_andy_default_rate_and_si_input(self):
        with patch("sys.argv", ["threshold_detection.py"]):
            args = threshold.parse_args()
        args.port = "FAKE"
        created = []
        original = threshold.create_detector

        def record(args, rate):
            detector = original(args, rate)
            created.append(detector)
            return detector

        with patch.object(threshold.serial, "Serial", return_value=FakeSerial(BLOCK)), \
                patch.object(threshold.time, "sleep"), patch("builtins.print"), \
                patch.object(threshold, "create_detector", side_effect=record):
            with self.assertRaises(KeyboardInterrupt):
                threshold.run_serial(args, original(args, 50))
        self.assertEqual(created[0].sample_rate_hz, 10)
        np.testing.assert_allclose(created[0]._calibration[0], EXPECTED[:3])


if __name__ == "__main__":
    unittest.main()
