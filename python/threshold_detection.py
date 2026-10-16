"""Project-aligned Signal Vector Magnitude threshold fall detector.

The starting thresholds come from the supplied project brief. They must be
calibrated with the final vest placement and physically tested before use.

Accepts Andy's labeled MPU6050 blocks or a serial CSV line:
    ax,ay,az,gx,gy,gz

Default units match an MPU6050 output: acceleration in m/s^2 and gyroscope in
rad/s. The threshold rule uses acceleration, rotation, and tilt.
"""

import argparse
import math
import time
from collections import deque
from dataclasses import dataclass
from pathlib import Path
from typing import Deque, Dict, List, Optional, Tuple

import numpy as np
import serial
from serial.tools import list_ports

from six_axis_data import DEFAULT_DATASET_DIR, read_sensor_vectors, resolve_recording
from serial_samples import SerialSampleParser, parse_csv_values
from esp32_serial import open_esp32
from stream_health import StreamHealth, positive_seconds
from calibrate_gyro import load_gyro_bias


GRAVITY = 9.80665


@dataclass(frozen=True)
class Thresholds:
    low_acceleration_g: float = 0.9
    high_rotation_dps: float = 47.3
    tilt_degrees: float = 24.7


class ThresholdFallDetector:
    """Collect fall evidence over a short time window.

    The three conditions do not need to occur in one sensor sample. A possible
    fall normally develops as a sequence, so evidence remains active for the
    configured interval.
    """

    def __init__(
        self,
        sample_rate_hz: float = 50.0,
        calibration_samples: int = 50,
        evidence_seconds: float = 1.0,
        cooldown_seconds: float = 2.0,
        thresholds: Thresholds = Thresholds(),
    ) -> None:
        if sample_rate_hz <= 0:
            raise ValueError("sample_rate_hz must be positive")
        if calibration_samples < 1:
            raise ValueError("calibration_samples must be at least 1")

        self.sample_rate_hz = sample_rate_hz
        self.calibration_samples = calibration_samples
        self.evidence_samples = max(1, round(evidence_seconds * sample_rate_hz))
        self.cooldown_samples = max(0, round(cooldown_seconds * sample_rate_hz))
        self.thresholds = thresholds

        self._calibration: List[np.ndarray] = []
        self._reference_direction: Optional[np.ndarray] = None
        self._sample_index = 0
        self._cooldown_until = -1
        self._low_acceleration_events: Deque[int] = deque()
        self._rotation_events: Deque[int] = deque()
        self._tilt_events: Deque[int] = deque()

    @property
    def calibrated(self) -> bool:
        return self._reference_direction is not None

    def _finish_calibration(self) -> None:
        reference = np.mean(np.asarray(self._calibration), axis=0)
        magnitude = float(np.linalg.norm(reference))
        if magnitude == 0:
            raise ValueError("Calibration failed because acceleration magnitude is zero")
        self._reference_direction = reference / magnitude

    def _remove_old_events(self) -> None:
        oldest_allowed = self._sample_index - self.evidence_samples
        for events in (
            self._low_acceleration_events,
            self._rotation_events,
            self._tilt_events,
        ):
            while events and events[0] < oldest_allowed:
                events.popleft()

    def update(
        self,
        acceleration_mps2: np.ndarray,
        gyroscope_rads: np.ndarray,
    ) -> Dict:
        acceleration = np.asarray(acceleration_mps2, dtype="float64")
        gyroscope = np.asarray(gyroscope_rads, dtype="float64")
        if acceleration.shape != (3,) or gyroscope.shape != (3,):
            raise ValueError("acceleration and gyroscope must each contain x, y, z")
        if not np.isfinite(acceleration).all() or not np.isfinite(gyroscope).all():
            raise ValueError("sensor values must be finite")

        self._sample_index += 1
        acceleration_magnitude = float(np.linalg.norm(acceleration))
        acceleration_g = acceleration_magnitude / GRAVITY
        rotation_dps = math.degrees(float(np.linalg.norm(gyroscope)))

        if not self.calibrated:
            self._calibration.append(acceleration.copy())
            if len(self._calibration) >= self.calibration_samples:
                self._finish_calibration()
            return {
                "status": "calibrating",
                "calibration_progress": len(self._calibration) / self.calibration_samples,
                "acceleration_g": acceleration_g,
                "rotation_dps": rotation_dps,
                "tilt_degrees": None,
                "fall_detected": False,
            }

        assert self._reference_direction is not None
        if acceleration_magnitude == 0:
            tilt_degrees = 0.0
        else:
            current_direction = acceleration / acceleration_magnitude
            cosine = float(np.clip(np.dot(current_direction, self._reference_direction), -1, 1))
            tilt_degrees = math.degrees(math.acos(cosine))

        low_acceleration = acceleration_g < self.thresholds.low_acceleration_g
        high_rotation = rotation_dps > self.thresholds.high_rotation_dps
        high_tilt = tilt_degrees > self.thresholds.tilt_degrees

        if low_acceleration:
            self._low_acceleration_events.append(self._sample_index)
        if high_rotation:
            self._rotation_events.append(self._sample_index)
        if high_tilt:
            self._tilt_events.append(self._sample_index)
        self._remove_old_events()

        has_all_evidence = bool(
            self._low_acceleration_events
            and self._rotation_events
            and self._tilt_events
        )
        fall_detected = has_all_evidence and self._sample_index > self._cooldown_until
        if fall_detected:
            self._cooldown_until = self._sample_index + self.cooldown_samples
            self._low_acceleration_events.clear()
            self._rotation_events.clear()
            self._tilt_events.clear()

        return {
            "status": "monitoring",
            "acceleration_g": acceleration_g,
            "rotation_dps": rotation_dps,
            "tilt_degrees": tilt_degrees,
            "low_acceleration": low_acceleration,
            "high_rotation": high_rotation,
            "high_tilt": high_tilt,
            "fall_detected": fall_detected,
        }


def find_esp32_port() -> Optional[str]:
    keywords = (
        "esp32",
        "cp210",
        "silicon labs",
        "ch340",
        "wch",
        "usbserial",
        "usbmodem",
    )
    for port in list_ports.comports():
        details = f"{port.device} {port.description} {port.manufacturer or ''}".lower()
        if any(keyword in details for keyword in keywords):
            return port.device
    return None


def parse_line(
    line: str, acceleration_unit: str, gyroscope_unit: str
) -> Tuple[np.ndarray, np.ndarray]:
    values = parse_csv_values(line, acceleration_unit, gyroscope_unit)
    acceleration = np.asarray(values[:3], dtype="float64")
    gyroscope = np.asarray(values[3:6], dtype="float64")
    return acceleration, gyroscope


def report_detection(result: Dict) -> None:
    print(
        "*** FALL THRESHOLD DETECTED — activate LED/buzzer only ***\n"
        f"Acceleration: {result['acceleration_g']:.2f} g\n"
        f"Rotation: {result['rotation_dps']:.1f} deg/s\n"
        f"Tilt: {result['tilt_degrees']:.1f} degrees"
    )


def run_serial(args: argparse.Namespace, detector: ThresholdFallDetector) -> None:
    port = args.port or find_esp32_port()
    if port is None:
        raise SystemExit(
            "ESP32 not found. Connect the ESP-WROOM-32 with a USB data cable and try again."
        )

    print(f"Connecting to {port} at {args.baud} baud...")
    print("Keep the vest sensor still during the initial calibration.")
    samples = SerialSampleParser(args.input_format, args.acceleration_unit, args.gyroscope_unit)
    selected_format = None
    bias = load_gyro_bias(getattr(args, "gyro_calibration", None))
    with open_esp32(port, args.baud, timeout=1) as device:
        time.sleep(2)
        if hasattr(device, "reset_input_buffer"):
            device.reset_input_buffer()
        announced_calibration = False
        health = StreamHealth(getattr(args, "no_data_timeout", 10.0))
        while True:
            line = device.readline().decode("utf-8", errors="replace").strip()
            if getattr(args, "show_raw", False) and line:
                print(f"RAW: {line}")
            health.check(line)
            if line.startswith(("rst:", "ets ", "ERROR:")):
                selected_format = None
            if not line:
                continue
            try:
                values = samples.feed(line)
                if values is None:
                    continue
                timed = samples.last_format == "timestamped"
                if health.accept() or (timed and samples.timing.discontinuity):
                    selected_format = None
                    print("Stream discontinuity: discarding old evidence and recalibrating.")
                if timed and len(samples.timing.intervals) >= 100:
                    if not 90 <= samples.timing.received_rate_hz <= 110:
                        raise RuntimeError("Timestamped stream is not near 100 Hz. Check acquisition before detection.")
                if selected_format != samples.last_format:
                    selected_format = samples.last_format
                    expected_rate = 100.0 if timed else (10.0 if selected_format == "andy" else 50.0)
                    if timed and args.sample_rate is not None and args.sample_rate != 100:
                        raise RuntimeError("This timestamped protocol targets 100 Hz; do not override it with another rate.")
                    sample_rate = args.sample_rate or expected_rate
                    detector = create_detector(args, sample_rate)
                    if timed:
                        # Retain at least one second of reference posture at
                        # the new rate; legacy streams/replay remain unchanged.
                        detector.calibration_samples = max(100, detector.calibration_samples)
                    announced_calibration = False
                    print(f"Input: {selected_format}; assumed sample rate: {sample_rate:g} Hz. Calibrating.")
                acceleration = np.asarray(values[:3], dtype="float64")
                gyroscope = np.asarray(values[3:], dtype="float64") - bias
                result = detector.update(acceleration, gyroscope)
            except ValueError as error:
                if args.show_bad_lines or line.startswith("ERROR:"):
                    print(f"Skipped input: {error}")
                continue

            if detector.calibrated and not announced_calibration:
                print("Calibration complete. Monitoring started. Press Control+C to stop.")
                announced_calibration = True
            if result["fall_detected"]:
                report_detection(result)


def replay_member(args: argparse.Namespace, detector: ThresholdFallDetector) -> None:
    path = resolve_recording(args.dataset_dir, args.replay_member)
    vectors, _ = read_sensor_vectors(path)
    count = min(len(vectors["acg"]), len(vectors["gyro"]))
    detections = []
    peak_rotation = 0.0
    minimum_acceleration = float("inf")
    maximum_tilt = 0.0
    for index in range(count):
        result = detector.update(vectors["acg"][index], vectors["gyro"][index])
        minimum_acceleration = min(minimum_acceleration, result["acceleration_g"])
        peak_rotation = max(peak_rotation, result["rotation_dps"])
        if result["tilt_degrees"] is not None:
            maximum_tilt = max(maximum_tilt, result["tilt_degrees"])
        if result["fall_detected"]:
            detections.append(index)

    print(f"Replay paired samples: {count}")
    print(f"Minimum acceleration: {minimum_acceleration:.2f} g")
    print(f"Peak rotation: {peak_rotation:.1f} deg/s")
    print(f"Maximum tilt from initial reference: {maximum_tilt:.1f} degrees")
    print(f"Threshold detections: {len(detections)}")
    if detections:
        print(f"First detection sample: {detections[0]}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port")
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--input-format", choices=("auto", "andy", "csv", "timestamped"), default="auto")
    parser.add_argument("--sample-rate", type=positive_seconds, default=None,
                        help="Legacy override: Andy 10, untimed CSV/replay 50. Timestamped firmware is 100 Hz.")
    parser.add_argument("--calibration-samples", type=int, default=50)
    parser.add_argument("--evidence-seconds", type=float, default=1.0)
    parser.add_argument("--cooldown-seconds", type=float, default=2.0)
    parser.add_argument("--low-acceleration-g", type=float, default=0.9)
    parser.add_argument("--high-rotation-dps", type=float, default=47.3)
    parser.add_argument("--tilt-degrees", type=float, default=24.7)
    parser.add_argument("--acceleration-unit", choices=("g", "mps2"), default="mps2")
    parser.add_argument("--gyroscope-unit", choices=("dps", "rads"), default="rads")
    parser.add_argument("--show-bad-lines", action="store_true")
    parser.add_argument("--show-raw", action="store_true")
    parser.add_argument("--no-data-timeout", type=positive_seconds, default=10.0)
    parser.add_argument("--gyro-calibration", type=Path, help="Optional same-sensor bias JSON; serial only.")
    parser.add_argument("--replay-member")
    parser.add_argument("--dataset-dir", type=Path, default=DEFAULT_DATASET_DIR)
    return parser.parse_args()


def create_detector(args, sample_rate):
    return ThresholdFallDetector(
        sample_rate_hz=sample_rate,
        calibration_samples=args.calibration_samples,
        evidence_seconds=args.evidence_seconds,
        cooldown_seconds=args.cooldown_seconds,
        thresholds=Thresholds(
            low_acceleration_g=args.low_acceleration_g,
            high_rotation_dps=args.high_rotation_dps,
            tilt_degrees=args.tilt_degrees,
        ),
    )


def main() -> None:
    args = parse_args()
    if args.replay_member and args.gyro_calibration:
        raise SystemExit("Do not apply your hardware calibration to public-dataset replay.")
    if args.sample_rate is not None and args.sample_rate <= 0:
        raise SystemExit("--sample-rate must be positive")
    detector = create_detector(args, args.sample_rate or 50.0)
    try:
        if args.replay_member:
            replay_member(args, detector)
        else:
            run_serial(args, detector)
    except KeyboardInterrupt:
        print("\nDetection stopped.")
    except (RuntimeError, ValueError, OSError, serial.SerialException) as error:
        raise SystemExit(str(error)) from error


if __name__ == "__main__":
    main()
