"""Unit tests for the project threshold detector."""

import math
import unittest

import numpy as np

from threshold_detection import GRAVITY, ThresholdFallDetector, parse_line


class ThresholdFallDetectorTests(unittest.TestCase):
    def make_detector(self) -> ThresholdFallDetector:
        return ThresholdFallDetector(
            sample_rate_hz=10,
            calibration_samples=5,
            evidence_seconds=1,
            cooldown_seconds=1,
        )

    def calibrate(self, detector: ThresholdFallDetector) -> None:
        for _ in range(5):
            result = detector.update(np.array([0.0, 0.0, GRAVITY]), np.zeros(3))
        self.assertTrue(detector.calibrated)
        self.assertFalse(result["fall_detected"])

    def test_normal_motion_does_not_trigger(self) -> None:
        detector = self.make_detector()
        self.calibrate(detector)
        for _ in range(20):
            result = detector.update(
                np.array([0.1, 0.1, GRAVITY]), np.deg2rad([5.0, 0.0, 0.0])
            )
            self.assertFalse(result["fall_detected"])

    def test_staged_fall_evidence_triggers(self) -> None:
        detector = self.make_detector()
        self.calibrate(detector)

        detector.update(np.array([0.0, 0.0, 0.5 * GRAVITY]), np.zeros(3))
        detector.update(
            np.array([0.0, 0.0, GRAVITY]), np.deg2rad([60.0, 0.0, 0.0])
        )
        angle = math.radians(30)
        result = detector.update(
            np.array([GRAVITY * math.sin(angle), 0.0, GRAVITY * math.cos(angle)]),
            np.zeros(3),
        )
        self.assertTrue(result["fall_detected"])

    def test_evidence_expires(self) -> None:
        detector = self.make_detector()
        self.calibrate(detector)
        detector.update(np.array([0.0, 0.0, 0.5 * GRAVITY]), np.zeros(3))
        for _ in range(12):
            detector.update(np.array([0.0, 0.0, GRAVITY]), np.zeros(3))
        result = detector.update(
            np.array([0.6 * GRAVITY, 0.0, 0.8 * GRAVITY]),
            np.deg2rad([60.0, 0.0, 0.0]),
        )
        self.assertFalse(result["fall_detected"])

    def test_serial_parser_requires_and_returns_all_six_axes(self) -> None:
        acceleration, gyroscope = parse_line("1,2,3,4,5,6", "mps2", "rads")
        np.testing.assert_array_equal(acceleration, [1, 2, 3])
        np.testing.assert_array_equal(gyroscope, [4, 5, 6])
        with self.assertRaises(ValueError):
            parse_line("1,2,3,4,5", "mps2", "rads")


if __name__ == "__main__":
    unittest.main()
