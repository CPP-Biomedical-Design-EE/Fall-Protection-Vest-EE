"""Unit tests for the jump-versus-fall exploratory metrics."""

import csv
import math
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from analyze_falls import (
    GRAVITY,
    StreamingFallDetector,
    analyze_file,
    angle_between,
    _causal_event_timeline,
    create_comparison_plots,
    create_jump1_fall3_timeline,
    _exploratory_rotation_reference,
    format_table,
)


class AnalyzeFallsTests(unittest.TestCase):
    def test_integrates_gyro_path_and_measures_joint_condition_duration(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "fall.csv"
            columns = [
                "label", "subject_id", "device_elapsed_s", "sample_interval_s",
                "stream_discontinuity", "acceleration_unit", "gyroscope_unit",
                "ax", "ay", "az", "gx", "gy", "gz",
            ]
            with path.open("w", newline="", encoding="utf-8") as target:
                writer = csv.DictWriter(target, fieldnames=columns)
                writer.writeheader()
                for index in range(51):
                    writer.writerow({
                        "label": "fall_T34_walking_slip_backward",
                        "subject_id": "P01",
                        "device_elapsed_s": f"{index / 100:.2f}",
                        "sample_interval_s": "0.010000" if index else "",
                        "stream_discontinuity": "0",
                        "acceleration_unit": "m/s^2",
                        "gyroscope_unit": "rad/s",
                        "ax": "0", "ay": "0", "az": "1",
                        "gx": "1", "gy": "0", "gz": "0",
                    })
            result = analyze_file(path)

        self.assertAlmostEqual(result["peak_gyro_dps"], math.degrees(1), places=5)
        self.assertAlmostEqual(result["low_g_and_rotation_total_s"], 0.5, places=5)
        self.assertAlmostEqual(result["low_g_and_rotation_longest_s"], 0.5, places=5)
        self.assertAlmostEqual(result["peak_gyro_path_300ms_deg"], math.degrees(1) * 0.3, places=4)
        result.update({
            "actual_class": "FALL",
            "predicted_class": "NO FALL",
            "detector_trigger_time_s": float("nan"),
            "detector_lead_to_impact_s": float("nan"),
        })
        self.assertIn("Gyro path 300ms", format_table([result]))

    def test_event_proxy_reports_lead_time_gyro_path_and_orientation_change(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "event.csv"
            columns = [
                "label", "subject_id", "device_elapsed_s", "sample_interval_s",
                "stream_discontinuity", "acceleration_unit", "gyroscope_unit",
                "ax", "ay", "az", "gx", "gy", "gz",
            ]
            with path.open("w", newline="", encoding="utf-8") as target:
                writer = csv.DictWriter(target, fieldnames=columns)
                writer.writeheader()
                for index in range(201):
                    seconds = index / 100
                    if 70 <= index <= 79:
                        acceleration = (0.0, 0.0, 0.1)
                    elif index == 80:
                        acceleration = (2 * GRAVITY, 0.0, 0.0)
                    elif index >= 90:
                        acceleration = (GRAVITY, 0.0, 0.0)
                    else:
                        acceleration = (0.0, 0.0, GRAVITY)
                    gyro = (0.3, 0.0, 0.0) if 70 <= index <= 80 else (0.0, 0.0, 0.0)
                    writer.writerow({
                        "label": "fall_T34_walking_slip_backward",
                        "subject_id": "P01",
                        "device_elapsed_s": f"{seconds:.2f}",
                        "sample_interval_s": "0.010000" if index else "",
                        "stream_discontinuity": "0",
                        "acceleration_unit": "m/s^2",
                        "gyroscope_unit": "rad/s",
                        "ax": acceleration[0], "ay": acceleration[1], "az": acceleration[2],
                        "gx": gyro[0], "gy": gyro[1], "gz": gyro[2],
                    })
            result = analyze_file(path)

        self.assertAlmostEqual(result["event_time_s"], 0.70)
        self.assertAlmostEqual(result["impact_time_s"], 0.80)
        self.assertAlmostEqual(result["lead_time_s"], 0.10)
        self.assertAlmostEqual(result["gyro_path_preimpact_deg"], math.degrees(0.3) * 0.1, places=3)
        self.assertAlmostEqual(result["orientation_change_deg"], 90.0, places=5)
        self.assertGreaterEqual(result["orientation_before_samples"], 5)
        self.assertGreaterEqual(result["orientation_after_samples"], 5)

    def test_angle_between_handles_zero_vector_and_clips_cosine(self):
        self.assertTrue(math.isnan(angle_between([0, 0, 0], [1, 0, 0])))
        self.assertAlmostEqual(angle_between([1, 0, 0], [0, 1, 0]), 90.0)

    def test_complementary_filter_blends_across_angle_wrap(self):
        detector = StreamingFallDetector()
        detector._reference_roll = 179.0
        detector._reference_pitch = 0.0
        detector._roll = 179.0
        detector._pitch = 0.0
        detector.state = "NORMAL"

        result = detector.update(
            0.01,
            [0.0, math.sin(math.radians(-179.0)) * GRAVITY,
             math.cos(math.radians(-179.0)) * GRAVITY],
            [0.0, 0.0, 0.0],
            0.01,
        )

        self.assertLess(result["orientation_change_deg"], 1.0)

    def test_replay_reports_open_candidate_at_recording_end(self):
        detector = StreamingFallDetector()
        for index in range(81):
            detector.update(index / 100, [0.0, 0.0, GRAVITY], [0.0, 0.0, 0.0], 0.01)
        detector.update(0.81, [0.0, 0.0, 0.1], [0.0, 0.0, 0.0], 0.01)

        incomplete = detector.finalize(0.81)

        self.assertIsNotNone(incomplete)
        self.assertTrue(incomplete["incomplete"])
        self.assertEqual(incomplete["reason"], "recording_end_incomplete")

    def test_jump1_fall3_timeline_is_optional(self):
        with tempfile.TemporaryDirectory() as folder:
            result = create_jump1_fall3_timeline([], Path(folder), Path(folder))
        self.assertEqual(result, {})

    def test_streaming_detector_waits_for_current_sample_evidence(self):
        detector = StreamingFallDetector()
        reference = [0.0, 0.0, GRAVITY]
        for index in range(81):
            result = detector.update(index / 100, reference, [0.0, 0.0, 0.0], 0.01)
        self.assertEqual(result["state"], "NORMAL")

        result = detector.update(0.81, [0.0, 0.0, 0.1], [2.0, 0.0, 0.0], 0.01)
        self.assertEqual(result["state"], "POSSIBLE_FALL")
        self.assertFalse(result["fall_detected_now"])

        trigger = None
        for index in range(82, 170):
            result = detector.update(index / 100, [GRAVITY, 0.0, 0.0], [2.0, 0.0, 0.0], 0.01)
            if result["fall_detected_now"]:
                trigger = result
                break
        self.assertIsNotNone(trigger)
        self.assertEqual(trigger["state"], "FALL_DETECTED")
        self.assertGreaterEqual(trigger["gyro_path_deg"], 75.0)
        self.assertGreaterEqual(trigger["orientation_change_deg"], 70.0)
        self.assertGreaterEqual(trigger["net_rotation_deg"], 70.0)
        self.assertGreaterEqual(trigger["rotation_consistency"], 0.0)
        self.assertLessEqual(trigger["rotation_consistency"], 1.0)
        self.assertAlmostEqual(trigger["trigger_time_s"], (index / 100))

    def test_does_not_trigger_on_low_g_and_gyro_without_causal_tilt(self):
        detector = StreamingFallDetector()
        for index in range(81):
            result = detector.update(
                index / 100, [0.0, 0.0, GRAVITY], [0.0, 0.0, 0.0], 0.01
            )
        self.assertEqual(result["state"], "NORMAL")

        result = detector.update(0.81, [0.0, 0.0, 0.1], [0.0, 0.0, 2.0], 0.01)
        self.assertEqual(result["state"], "POSSIBLE_FALL")
        rejected = None
        for index in range(82, 171):
            result = detector.update(
                index / 100, [0.0, 0.0, GRAVITY], [0.0, 0.0, 2.0], 0.01
            )
            self.assertFalse(result["fall_detected_now"])
            if result["rejection"] is not None:
                rejected = result
                break
        self.assertIsNotNone(rejected)
        self.assertEqual(rejected["state"], "RECOVERY")
        self.assertEqual(rejected["rejection"]["reason"], "causal_tilt")
        self.assertGreater(rejected["rejection"]["max_gyro_path_deg"], 75.0)
        self.assertLess(rejected["rejection"]["max_tilt_change_deg"], 70.0)

    def test_directional_rotation_keeps_signed_axes_and_detects_reversal(self):
        detector = StreamingFallDetector()
        for index in range(81):
            detector.update(index / 100, [0.0, 0.0, GRAVITY], [0.0, 0.0, 0.0], 0.01)
        detector.update(0.81, [0.0, 0.0, 0.1], [0.0, 0.0, 0.0], 0.01)

        result = None
        for index in range(82, 102):
            result = detector.update(index / 100, [0.0, 0.0, 0.1], [1.0, 0.5, 0.0], 0.01)
        self.assertGreater(result["net_rot_x_deg"], 10.0)
        self.assertGreater(result["net_rot_y_deg"], 5.0)
        self.assertAlmostEqual(result["net_rot_z_deg"], 0.0, places=7)
        forward_consistency = result["rotation_consistency"]

        for index in range(102, 122):
            result = detector.update(index / 100, [0.0, 0.0, 0.1], [-1.0, -0.5, 0.0], 0.01)
        self.assertLess(result["rotation_consistency"], forward_consistency)
        self.assertLessEqual(result["rotation_consistency"], 1.0)
        self.assertGreater(result["max_abs_roll_change_deg"], 5.0)
        self.assertGreater(result["max_abs_pitch_change_deg"], 0.0)

    def test_creates_five_comparison_plots_and_exploratory_reference(self):
        rows = []
        for index in range(5):
            rows.append({
                "activity": "adl_T04_jump", "actual_class": "JUMP", "trial": f"Jump {index + 1}",
                "candidate_gyro_path_deg": 30.0 + index,
                "candidate_net_rotation_deg": 10.0 + index,
                "candidate_net_rot_y_deg": -10.0 + index,
                "candidate_rotation_consistency": 0.2 + index * 0.01,
                "candidate_max_abs_pitch_change_deg": 15.0 + index,
            })
            rows.append({
                "activity": "fall_T34_walking_slip_backward", "actual_class": "FALL",
                "trial": f"Fall {index + 1}",
                "candidate_gyro_path_deg": 70.0 + index,
                "candidate_net_rotation_deg": 40.0 + index,
                "candidate_net_rot_y_deg": 30.0 + index,
                "candidate_rotation_consistency": 0.7 + index * 0.01,
                "candidate_max_abs_pitch_change_deg": 80.0 + index,
            })

        self.assertAlmostEqual(_exploratory_rotation_reference(rows), 27.0)
        with tempfile.TemporaryDirectory() as folder, patch("matplotlib.pyplot.show") as show:
            outputs = create_comparison_plots(rows, Path(folder))
            self.assertEqual(len(outputs), 6)
            self.assertEqual({path.name for path in outputs}, {
                "net_rotation.png", "net_y_rotation.png", "rotation_consistency.png", "pitch_change.png",
                "rotation_scatter.png", "feature_comparison.png",
            })
            self.assertTrue(all(path.is_file() and path.stat().st_size > 0 for path in outputs))
            show.assert_called_once()

    def _write_timeline_recording(self, path, label, gyro_y_rads):
        columns = [
            "label", "subject_id", "device_elapsed_s", "sample_interval_s",
            "stream_discontinuity", "acceleration_unit", "gyroscope_unit",
            "ax", "ay", "az", "gx", "gy", "gz",
        ]
        with path.open("w", newline="", encoding="utf-8") as target:
            writer = csv.DictWriter(target, fieldnames=columns)
            writer.writeheader()
            for index in range(251):
                timestamp = index / 100
                low_g = 1.0 <= timestamp <= 1.05
                writer.writerow({
                    "label": label,
                    "subject_id": "P01",
                    "device_elapsed_s": f"{timestamp:.2f}",
                    "sample_interval_s": "" if index == 0 else "0.010000",
                    "stream_discontinuity": "0",
                    "acceleration_unit": "m/s^2",
                    "gyroscope_unit": "rad/s",
                    "ax": "0", "ay": "0", "az": "0.1" if low_g else str(GRAVITY),
                    "gx": "0", "gy": str(gyro_y_rads if timestamp >= 1.0 else 0.0), "gz": "0",
                })

    def test_event_timeline_threshold_crossings_stop_at_impact_proxy(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "fall.csv"
            self._write_timeline_recording(path, "fall_T34_walking_slip_backward", 1.0)
            series = _causal_event_timeline(path, event_time_s=1.0, impact_time_s=1.5)

        crossings = series["crossings"]
        self.assertIn(10.0, crossings)
        self.assertIn(20.0, crossings)
        self.assertIn(24.0, crossings)
        self.assertNotIn(30.0, crossings)
        self.assertGreater(series["impact_time_s"] - crossings[24.0], 0.0)
        self.assertAlmostEqual(series["impact_relative_time_s"], 0.5)
        self.assertAlmostEqual(series["signed_y_rotation_at_impact_deg"], math.degrees(1.0) * 0.5, places=3)

    def test_event_timeline_pitch_at_impact_excludes_post_impact_samples(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "fall.csv"
            columns = [
                "label", "subject_id", "device_elapsed_s", "sample_interval_s",
                "stream_discontinuity", "acceleration_unit", "gyroscope_unit",
                "ax", "ay", "az", "gx", "gy", "gz",
            ]
            with path.open("w", newline="", encoding="utf-8") as target:
                writer = csv.DictWriter(target, fieldnames=columns)
                writer.writeheader()
                for index in range(251):
                    timestamp = index / 100
                    low_g = 1.0 <= timestamp <= 1.05
                    post_impact_rotation = timestamp >= 1.60
                    writer.writerow({
                        "label": "fall_T34_walking_slip_backward",
                        "subject_id": "P01",
                        "device_elapsed_s": f"{timestamp:.2f}",
                        "sample_interval_s": "" if index == 0 else "0.010000",
                        "stream_discontinuity": "0",
                        "acceleration_unit": "m/s^2",
                        "gyroscope_unit": "rad/s",
                        "ax": "0", "ay": "0", "az": "0.1" if low_g else str(GRAVITY),
                        "gx": "0", "gy": "1.0" if post_impact_rotation else "0", "gz": "0",
                    })
            series = _causal_event_timeline(path, event_time_s=1.0, impact_time_s=1.5)

        self.assertLess(abs(series["pitch_change_at_impact_deg"]), 1.0)
        self.assertGreater(abs(series["trace"][-1]["pitch_change_deg"]), 1.0)

    def test_jump1_fall3_timeline_saves_focused_figure(self):
        with tempfile.TemporaryDirectory() as folder:
            recordings = Path(folder) / "recordings"
            jump_path = recordings / "P01" / "adl_T04_jump" / "jump.csv"
            fall_path = recordings / "P01" / "fall_T34_walking_slip_backward" / "fall.csv"
            jump_path.parent.mkdir(parents=True)
            fall_path.parent.mkdir(parents=True)
            self._write_timeline_recording(jump_path, "adl_T04_jump", 0.2)
            self._write_timeline_recording(fall_path, "fall_T34_walking_slip_backward", 1.0)
            rows = [
                {"trial": "Jump 1", "activity": "adl_T04_jump", "subject_id": "P01", "file": "jump.csv",
                 "detector_event_time_s": 1.0, "detector_impact_proxy_time_s": 1.5,
                 "event_time_s": 1.0, "impact_time_s": 1.5},
                {"trial": "Fall 3", "activity": "fall_T34_walking_slip_backward", "subject_id": "P01", "file": "fall.csv",
                 "detector_event_time_s": 1.0, "detector_impact_proxy_time_s": 1.5,
                 "event_time_s": 1.0, "impact_time_s": 1.5},
            ]
            output_dir = Path(folder) / "plots"
            series = create_jump1_fall3_timeline(rows, output_dir, recordings)
            self.assertTrue((output_dir / "jump1_fall3_timeline.png").is_file())
            self.assertIn(24.0, series["Fall 3"]["crossings"])


if __name__ == "__main__":
    unittest.main()
