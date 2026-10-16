"""Synthetic 100 Hz protocol and compatibility tests; no physical board used."""
import csv
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import numpy as np

import collect_data
import threshold_detection as threshold
import live_fall_detection as live
from device_timing import DeviceTiming
from serial_samples import SerialSampleParser
from calibrate_gyro import estimate_calibration
from stream_health import HundredHzGuard
from test_serial_samples import FakeSerial, BLOCK

HEADER = "device_time_us,sequence,ax,ay,az,gx,gy,gz"


def packets(count):
    return [f"{1000000+i*10000},{i},0,0,9.80665,0.01,0.02,-0.03" for i in range(count)]


class TimestampTests(unittest.TestCase):
    def test_hundred_hz_si_units_and_only_six_sensor_values(self):
        parser = SerialSampleParser(acceleration_unit="g", gyroscope_unit="dps")
        self.assertIsNone(parser.feed(HEADER))
        for packet in packets(101):
            values = parser.feed(packet)
        np.testing.assert_allclose(values, [0, 0, 9.80665, .01, .02, -.03])
        self.assertEqual(parser.last_format, "timestamped")
        self.assertAlmostEqual(parser.timing.received_rate_hz, 100)
        self.assertAlmostEqual(parser.timing.elapsed_s, 1)
        self.assertFalse(parser.timing.discontinuity)

    def test_missing_packet_and_long_interval_visible(self):
        timing = DeviceTiming()
        timing.observe(0, 0)
        timing.observe(30000, 3)
        self.assertEqual(timing.missing_packets, 2)
        self.assertTrue(timing.discontinuity)
        timing.observe(60000, 4)
        self.assertTrue(timing.discontinuity)

    def test_unsigned_timer_and_sequence_wrap(self):
        timing = DeviceTiming()
        timing.observe(2**32-5000, 2**32-1)
        timing.observe(5000, 0)
        self.assertAlmostEqual(timing.interval_s, .01)
        self.assertFalse(timing.discontinuity)
        self.assertEqual(timing.reset_count, 0)

    def test_reboot_starts_new_epoch_and_duplicate_rejected(self):
        parser = SerialSampleParser()
        parser.feed("3000000,900,0,0,9.8,0,0,0")
        parser.feed("10000,0,0,0,9.8,0,0,0")
        self.assertTrue(parser.timing.discontinuity)
        self.assertEqual(parser.timing.elapsed_s, 0)
        self.assertEqual(parser.timing.reset_count, 1)
        with self.assertRaisesRegex(ValueError, "Duplicate"):
            parser.feed("10000,0,0,0,9.8,0,0,0")

    def test_repeated_header_resets_timing(self):
        parser = SerialSampleParser()
        parser.feed(packets(1)[0])
        parser.feed(HEADER)
        parser.feed(packets(1)[0])
        self.assertTrue(parser.timing.discontinuity)
        self.assertEqual(parser.timing.reset_count, 1)

    def test_bad_timestamps_or_nonfinite_do_not_advance_clock(self):
        parser = SerialSampleParser()
        parser.feed(packets(1)[0])
        for packet in ("-1,1,0,0,9.8,0,0,0", "4294967296,1,0,0,9.8,0,0,0",
                       "1.5,1,0,0,9.8,0,0,0", "1010000,1,0,0,nan,0,0,0"):
            with self.assertRaises(ValueError):
                parser.feed(packet)
            self.assertEqual(parser.timing.sequence, 0)

    def test_explicit_timestamped_does_not_accept_untimed(self):
        with self.assertRaises(ValueError):
            SerialSampleParser("timestamped").feed("0,0,9.8,0,0,0")


class IntegrationTests(unittest.TestCase):
    def test_flush_discards_timestamp_tail_before_strict_timing_check(self):
        device = FakeSerial(["34506,10,0,0,9.8,0,0,0"] + packets(101))
        device.reset_input_buffer = lambda: None
        with tempfile.TemporaryDirectory() as folder:
            with patch("sys.argv", ["collect_data.py", "--port", "FAKE", "--require-100hz", "--output-dir", folder]), \
                    patch.object(collect_data.serial, "Serial", return_value=device), \
                    patch.object(collect_data.time, "sleep"), patch("builtins.print"):
                self.assertEqual(collect_data.main(), 0)
            with next(Path(folder).rglob("*.csv")).open() as source:
                rows = list(csv.DictReader(source))
            self.assertEqual(len(rows), 101)
            self.assertEqual(rows[0]["device_time_us"], "1000000")
            self.assertTrue(all(row["stream_discontinuity"] == "0" for row in rows))

    def collect_strict(self, lines, folder):
        device = FakeSerial(lines)
        with patch("sys.argv", ["collect_data.py", "--port", "FAKE", "--require-100hz", "--output-dir", folder]), \
                patch.object(collect_data.serial, "Serial", return_value=device), \
                patch.object(collect_data.time, "sleep"), patch("builtins.print"):
            result = collect_data.main()
        self.assertFalse(device.is_open)
        return result

    def test_strict_rejects_legacy_before_creating_csv(self):
        for lines in (BLOCK, ["0,0,9.8,0,0,0"]):
            with self.subTest(lines=lines), tempfile.TemporaryDirectory() as folder:
                self.assertEqual(self.collect_strict(lines, folder), 1)
                self.assertEqual(list(Path(folder).iterdir()), [])

    def test_strict_accepts_timestamped_stream_and_preserves_samples(self):
        with tempfile.TemporaryDirectory() as folder:
            self.assertEqual(self.collect_strict([HEADER] + packets(601), folder), 0)
            with next(Path(folder).rglob("*.csv")).open() as source:
                rows = list(csv.DictReader(source))
            self.assertEqual(len(rows), 601)
            self.assertEqual(rows[-1]["sequence"], "600")

    def test_strict_short_recording_is_not_verified(self):
        with tempfile.TemporaryDirectory() as folder:
            self.assertEqual(self.collect_strict(packets(50), folder), 1)

    def test_strict_stops_on_later_packet_gap(self):
        with tempfile.TemporaryDirectory() as folder:
            self.assertEqual(self.collect_strict(packets(101) + [packets(103)[102]], folder), 1)
            with next(Path(folder).rglob("*.csv")).open() as source:
                rows = list(csv.DictReader(source))
            self.assertEqual(len(rows), 101)

    def test_recorded_device_time_and_calibration_ignore_host_burst(self):
        with tempfile.TemporaryDirectory() as folder:
            with patch("sys.argv", ["collect_data.py", "--port", "FAKE", "--label", "stationary_calibration",
                                    "--output-dir", folder]), \
                    patch.object(collect_data.serial, "Serial", return_value=FakeSerial([HEADER] + packets(601))), \
                    patch.object(collect_data.time, "sleep"), patch("builtins.print"):
                collect_data.main()
            with next(Path(folder).rglob("*.csv")).open() as source:
                rows = list(csv.DictReader(source))
        self.assertEqual(len(rows), 601)
        self.assertEqual(rows[-1]["sequence"], "600")
        self.assertEqual(rows[-1]["device_elapsed_s"], "6.000000")
        self.assertEqual(rows[-1]["sample_interval_s"], "0.010000")
        self.assertEqual(rows[-1]["stream_discontinuity"], "0")
        result = estimate_calibration(rows)
        self.assertEqual(result["time_source"], "device_elapsed_s")
        rows[-1]["stream_discontinuity"] = "1"
        with self.assertRaisesRegex(ValueError, "discontinuity"):
            estimate_calibration(rows)

    def test_threshold_uses_100hz_and_resets_after_packet_loss(self):
        with patch("sys.argv", ["threshold_detection.py", "--port", "FAKE"]):
            args = threshold.parse_args()
        original = threshold.create_detector
        created = []

        def create(args, rate):
            detector = original(args, rate)
            created.append(detector)
            return detector

        lines = [packets(3)[0], packets(3)[2]]
        with patch.object(threshold.serial, "Serial", return_value=FakeSerial(lines)), \
                patch.object(threshold.time, "sleep"), patch("builtins.print"), \
                patch.object(threshold, "create_detector", side_effect=create):
            with self.assertRaises(KeyboardInterrupt):
                threshold.run_serial(args, original(args, 50))
        self.assertEqual(len(created), 2)
        self.assertTrue(all(detector.sample_rate_hz == 100 for detector in created))
        self.assertTrue(all(detector.calibration_samples >= 100 for detector in created))

    def test_old_model_blocked_on_new_rate_and_serial_is_closed(self):
        args = SimpleNamespace(port="FAKE", baud=115200, input_format="auto",
                               acceleration_unit="mps2", gyroscope_unit="rads", show_bad_lines=True,
                               threshold=.7, consecutive_windows=2)
        device = FakeSerial(packets(2))
        with patch.object(live.serial, "Serial", return_value=device), \
                patch.object(live.time, "sleep"), patch("builtins.print"), \
                patch.object(live, "predict") as predict:
            with self.assertRaisesRegex(RuntimeError, "100 Hz training"):
                live.run_serial(args, {"window_samples": 40, "step_samples": 20})
        predict.assert_not_called()
        self.assertFalse(device.is_open)


class HundredHzGuardTests(unittest.TestCase):
    def test_requires_timestamps(self):
        for kind in ("andy", "csv"):
            with self.subTest(kind=kind), self.assertRaisesRegex(RuntimeError, "Upload"):
                HundredHzGuard().check(kind, DeviceTiming())

    def test_warms_up_then_passes(self):
        timing, guard = DeviceTiming(), HundredHzGuard()
        for i in range(101):
            timing.observe(1000000 + i * 10000, i)
            guard.check("timestamped", timing)
            self.assertEqual(guard.verified, i == 100)

    def test_wrong_rate_fails_even_with_contiguous_sequence(self):
        for interval in (9000, 12000):
            timing, guard = DeviceTiming(), HundredHzGuard()
            with self.subTest(interval=interval), self.assertRaisesRegex(RuntimeError, "expected 95"):
                for i in range(101):
                    timing.observe(1000000 + i * interval, i)
                    guard.check("timestamped", timing)

    def test_checks_later_slowdown(self):
        timing, guard = DeviceTiming(), HundredHzGuard()
        for i in range(101):
            timing.observe(i * 10000, i)
            guard.check("timestamped", timing)
        self.assertTrue(guard.verified)
        with self.assertRaisesRegex(RuntimeError, "expected 95"):
            for i in range(101, 601):
                timing.observe(1000000 + (i - 100) * 12000, i)
                guard.check("timestamped", timing)

    def test_gap_and_reset_fail(self):
        for timestamp, sequence in ((1030000, 3), (1000, 0)):
            timing, guard = DeviceTiming(), HundredHzGuard()
            timing.observe(1000000, 1)
            guard.check("timestamped", timing)
            timing.observe(timestamp, sequence)
            with self.subTest(timestamp=timestamp), self.assertRaisesRegex(RuntimeError, "gap or device reset"):
                guard.check("timestamped", timing)


if __name__ == "__main__":
    unittest.main()
