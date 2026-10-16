"""Synthetic GUI/data-path checks, not a hardware validation."""
import tempfile
from datetime import datetime, timezone
import unittest
from pathlib import Path
from unittest.mock import patch, MagicMock

import matplotlib
matplotlib.use("Agg")
import numpy as np

import collect_data
from live_sensor_graph import BufferedSerialLines, LiveSensorGraph, accelerometer_tilt, euler_angles
from test_serial_samples import FakeSerial, BLOCK, EXPECTED


class ByteDevice(FakeSerial):
    def __init__(self, payload):
        super().__init__([])
        self.payload = bytearray(payload)

    @property
    def in_waiting(self):
        return len(self.payload)

    def read(self, count):
        result = bytes(self.payload[:count])
        del self.payload[:count]
        return result


class GraphTests(unittest.TestCase):
    def test_graph_time_keeps_start_and_converts_utc(self):
        graph = LiveSensorGraph("bench", "test", True, show=False)
        try:
            graph.set_recording_time(datetime(2026, 10, 13, 20, 0, tzinfo=timezone.utc))
            graph.set_recording_time(datetime(2026, 10, 13, 20, 0, 30, tzinfo=timezone.utc))
            self.assertIn("Started: 2026-10-13 13:00:00 PDT", graph.time_label.get_text())
            self.assertIn("Latest sample: 13:00:30 PDT", graph.time_label.get_text())
        finally:
            graph.finish()

    def test_tilt_known_positions_and_dynamic_mask(self):
        g = 9.80665
        np.testing.assert_allclose(accelerometer_tilt([0, 0, g]), [0, 0])
        np.testing.assert_allclose(accelerometer_tilt([0, g, 0]), [90, 0])
        roll, pitch = accelerometer_tilt([g, 0, 0])
        self.assertTrue(np.isnan(roll))
        self.assertAlmostEqual(pitch, -90)
        self.assertTrue(all(np.isnan(accelerometer_tilt([0, 0, 0]))))
        self.assertTrue(all(np.isnan(accelerometer_tilt([0, 0, 2*g]))))

    def test_euler_display_has_relative_yaw(self):
        roll, pitch, yaw = euler_angles([0, 0, 9.80665, 0, 0, np.pi], 10, 0.1)
        self.assertAlmostEqual(roll, 0)
        self.assertAlmostEqual(pitch, 0)
        self.assertAlmostEqual(yaw, 28)

    def test_tilt_graph_breaks_wrap_and_stream_gaps(self):
        graph = LiveSensorGraph("bench", "test", True, show=False)
        try:
            for i, angle in enumerate([179, -179]):
                rad = np.radians(angle)
                graph.add_sample(i, [0, 9.80665*np.sin(rad), 9.80665*np.cos(rad), 0, 0, 0])
            graph.add_sample(2, [0, 0, 9.80665, 0, 0, 0], gap=True)
            graph.redraw()
            roll = graph.angle_lines[0].get_ydata()
            self.assertTrue(np.isnan(roll[1]))
            self.assertTrue(np.isnan(roll[3]))
            self.assertEqual(len(graph.axes), 4)
            self.assertEqual(len(graph.angle_lines), 3)
        finally:
            graph.finish()

    def test_graph_distinguishes_legacy_host_rate_and_device_rate(self):
        graph = LiveSensorGraph("bench", "test", True, show=False)
        try:
            graph.add_sample(0, EXPECTED)
            graph.source_format = "andy"
            graph.host_rate_hz = 8.6
            graph.redraw()
            self.assertIn("8.6 Hz (host received)", graph.status.get_text())
            self.assertIn("100 Hz NOT verified", graph.status.get_text())
            graph.source_format = "timestamped"
            graph.device_rate_hz = 99.9
            graph.redraw()
            self.assertIn("99.9 Hz (device)", graph.status.get_text())
            self.assertNotIn("100 Hz NOT verified", graph.status.get_text())
        finally:
            graph.finish()

    def test_fragmented_lines_preserved_and_multiple_lines_drained(self):
        device = ByteDevice(b"1,2,3")
        reader = BufferedSerialLines(device)
        self.assertEqual(reader.readline(), b"")
        device.payload.extend(b",4,5,6\r\nsecond\n")
        self.assertEqual(reader.readline(), b"1,2,3,4,5,6\r\n")
        self.assertEqual(reader.readline(), b"second\n")
        self.assertEqual(reader.readline(), b"")

    def test_zero_pending_count_still_probes_nonblocking_read(self):
        class LazyUsbDevice(ByteDevice):
            @property
            def in_waiting(self):
                return 0

        payload = b"123,4,0,0,9.8,0,0,0\n"
        reader = BufferedSerialLines(LazyUsbDevice(payload))
        results = [reader.readline() for _ in payload]
        self.assertEqual([line for line in results if line], [payload])
        self.assertEqual(reader.readline(), b"")

    def test_graph_discards_valid_looking_partial_first_timestamp(self):
        prefix = b"34506,10,0,0,9.8,0,0,0\n"
        packet = b"1544506,11,0,0,9.8,0,0,0\n"
        device = ByteDevice(prefix + packet)
        device.reset_input_buffer = MagicMock()
        graph = MagicMock()
        graph.poll.side_effect = [True, True, False]
        with patch("sys.argv", ["collect_data.py", "--graph", "--preview", "--port", "FAKE"]), \
                patch("live_sensor_graph.LiveSensorGraph", return_value=graph), \
                patch.object(collect_data.serial, "Serial", return_value=device), \
                patch.object(collect_data.time, "sleep"), patch("builtins.print"):
            self.assertEqual(collect_data.main(), 0)
        graph.add_sample.assert_called_once()
        self.assertFalse(graph.add_sample.call_args.kwargs["gap"])
        device.reset_input_buffer.assert_called_once()

    def test_corrupt_unterminated_line_is_bounded(self):
        reader = BufferedSerialLines(ByteDevice(b"x" * 80000))
        with self.assertRaisesRegex(RuntimeError, "line endings"):
            for _ in range(12):
                reader.readline()

    def test_six_axis_units_window_magnitude_and_snapshot(self):
        graph = LiveSensorGraph("bench", "test", True, window_seconds=5, show=False)
        try:
            for second in range(11):
                graph.add_sample(second, [0, 0, 9.80665, np.pi, 0, 0])
            graph.redraw()
            self.assertEqual(len(graph.history), 6)
            np.testing.assert_allclose(graph.norm_line.get_ydata(), 1)
            np.testing.assert_allclose(graph.gyro_lines[0].get_ydata(), 180)
            self.assertEqual(graph.axes[2].get_xlim(), (5, 10))
            self.assertGreater(graph.axes[1].get_ylim()[1], 180)
            self.assertIn("PREVIEW", graph.status.get_text())
            with tempfile.TemporaryDirectory() as folder:
                target = Path(folder) / "snapshot.png"
                graph.finish(target)
                self.assertTrue(target.read_bytes().startswith(b"\x89PNG"))
        finally:
            graph.finish()

    def test_gap_is_not_joined_as_continuous_data(self):
        graph = LiveSensorGraph("bench", "test", True, show=False)
        try:
            graph.add_sample(0, EXPECTED)
            graph.add_sample(3, EXPECTED, gap=True)
            graph.redraw()
            self.assertTrue(np.isnan(graph.acc_lines[0].get_ydata()[1]))
            self.assertEqual(graph.total_samples, 2)
            graph._on_close(None)
            self.assertFalse(graph.poll())
        finally:
            graph.finish()

    def test_preview_graph_uses_one_port_and_saves_nothing(self):
        device = ByteDevice(("\n".join(BLOCK) + "\n").encode())
        graph = MagicMock()
        graph.poll.side_effect = [True] * len(BLOCK) + [False]
        with tempfile.TemporaryDirectory() as folder:
            with patch("sys.argv", ["collect_data.py", "--graph", "--preview", "--port", "FAKE", "--output-dir", folder]), \
                    patch("live_sensor_graph.LiveSensorGraph", return_value=graph), \
                    patch.object(collect_data.serial, "Serial", return_value=device) as factory, \
                    patch.object(collect_data.time, "sleep"), patch("builtins.print"):
                collect_data.main()
            self.assertEqual(list(Path(folder).iterdir()), [])
            factory.assert_called_once()
            self.assertEqual(factory.call_args.kwargs["timeout"], 0)
            self.assertFalse(device.is_open)
            graph.add_sample.assert_called_once()
            np.testing.assert_allclose(graph.add_sample.call_args.args[1], EXPECTED)
            graph.finish.assert_called_once_with(None)

    def test_graph_recording_preserves_csv_and_snapshot_path(self):
        device = ByteDevice(("\n".join(BLOCK) + "\n").encode())
        graph = MagicMock()
        graph.poll.side_effect = [True] * len(BLOCK) + [False]
        with tempfile.TemporaryDirectory() as folder:
            with patch("sys.argv", ["collect_data.py", "--graph", "--port", "FAKE", "--output-dir", folder]), \
                    patch("live_sensor_graph.LiveSensorGraph", return_value=graph), \
                    patch.object(collect_data.serial, "Serial", return_value=device), \
                    patch.object(collect_data.time, "sleep"), patch("builtins.print"):
                collect_data.main()
            files = list(Path(folder).rglob("*.csv"))
            self.assertEqual(len(files), 1)
            graph.finish.assert_called_once_with(files[0].resolve().with_suffix(".png"))
            self.assertFalse(device.is_open)


if __name__ == "__main__":
    unittest.main()
