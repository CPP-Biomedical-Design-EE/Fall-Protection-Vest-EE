"""Run 6-axis MPU6050 rolling-window fall detection from ESP32 serial data.

Accepts Andy's labeled MPU6050 blocks or an ESP32 CSV line:
    ax,ay,az,gx,gy,gz

The default units are acceleration in m/s^2 and gyroscope in rad/s.
"""

import argparse
import time
from collections import deque
from pathlib import Path
from typing import Optional

import joblib
import numpy as np
import pandas as pd
import serial
from serial.tools import list_ports

from extract_recording_features import summarize
from six_axis_data import DEFAULT_DATASET_DIR, read_sensor_vectors, resolve_recording
from serial_samples import SerialSampleParser, parse_csv_values
from esp32_serial import open_esp32
from stream_health import StreamHealth, positive_seconds
from calibrate_gyro import load_gyro_bias


BASE_DIR = Path(__file__).resolve().parent
DEFAULT_MODEL = BASE_DIR / "Models" / "fall_detector_svm_window.joblib"
GRAVITY = 9.80665


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
        description = (
            f"{port.device} {port.description} {port.manufacturer or ''}"
        ).lower()

        if any(keyword in description for keyword in keywords):
            return port.device

    return None


def make_feature_row(acceleration: np.ndarray, gyroscope: np.ndarray) -> dict:
    features = summarize(acceleration, "acc")
    features.update(summarize(gyroscope, "gyro"))
    return features


def predict(bundle: dict, acceleration: np.ndarray, gyroscope: np.ndarray) -> float:
    features = make_feature_row(acceleration, gyroscope)
    if set(bundle["feature_columns"]) != set(features) or len(bundle["feature_columns"]) != len(features):
        raise ValueError("Model is not compatible with the current six-axis feature schema. Use a six-axis model.")
    frame = pd.DataFrame([features], columns=bundle["feature_columns"])
    return float(bundle["pipeline"].predict_proba(frame)[0, 1])


def parse_serial_line(line: str, acceleration_unit: str, gyroscope_unit: str):
    values = parse_csv_values(line, acceleration_unit, gyroscope_unit)
    acceleration = np.asarray(values[:3], dtype="float64")
    gyroscope = np.asarray(values[3:6], dtype="float64")
    return acceleration, gyroscope


def run_serial(args: argparse.Namespace, bundle: dict) -> None:
    port = args.port or find_esp32_port()
    if port is None:
        raise SystemExit(
            "ESP32 not found. Connect the ESP-WROOM-32 with a USB data cable and try again."
        )

    window_size = int(bundle["window_samples"])
    step_size = int(bundle["step_samples"])
    accelerations: deque = deque(maxlen=window_size)
    gyroscopes: deque = deque(maxlen=window_size)
    samples_since_prediction = 0
    consecutive_fall_windows = 0

    samples = SerialSampleParser(args.input_format, args.acceleration_unit, args.gyroscope_unit)
    announced_andy = False
    previous_format = None
    bias = load_gyro_bias(getattr(args, "gyro_calibration", None))
    print("Experimental public-data baseline: NOT validated for lower-back/waist placement.")

    print(f"Connecting to {port} at {args.baud} baud...")
    with open_esp32(port, args.baud, timeout=1) as device:
        time.sleep(2)
        if hasattr(device, "reset_input_buffer"):
            device.reset_input_buffer()
        print("Live detection started. Press Control+C to stop.")
        health = StreamHealth(getattr(args, "no_data_timeout", 10.0))
        while True:
            raw_line = device.readline().decode("utf-8", errors="replace").strip()
            if getattr(args, "show_raw", False) and raw_line:
                print(f"RAW: {raw_line}")
            health.check(raw_line)
            if raw_line.startswith(("rst:", "ets ", "ERROR:")):
                accelerations.clear()
                gyroscopes.clear()
                samples_since_prediction = consecutive_fall_windows = 0
            if not raw_line:
                continue
            try:
                values = samples.feed(raw_line)
            except ValueError as error:
                if args.show_bad_lines or raw_line.startswith("ERROR:"):
                    print(f"Skipped input: {error}")
                continue
            if values is None:
                continue
            timed = samples.last_format == "timestamped"
            if timed and bundle.get("training_sample_rate_hz") != 100:
                raise RuntimeError("This saved model has no verified 100 Hz training profile. "
                                   "Use collect_data.py --preview --graph for the new firmware. "
                                   "Do not reinterpret old model windows at a new rate; a separate matched-rate model is needed.")
            if timed and len(samples.timing.intervals) >= 100 and not 90 <= samples.timing.received_rate_hz <= 110:
                raise RuntimeError("Timestamped stream is not near 100 Hz; stopping predictions.")
            if health.accept() or (timed and samples.timing.discontinuity) or previous_format not in (None, samples.last_format):
                accelerations.clear()
                gyroscopes.clear()
                samples_since_prediction = consecutive_fall_windows = 0
                print("Stream interrupted or format changed: discarded previous prediction window.")
            previous_format = samples.last_format
            if samples.last_format == "andy" and not announced_andy:
                print(
                    f"Andy format detected: SI units, roughly 10 samples/s. "
                    f"{window_size} samples take about {window_size / 10:.1f}s; "
                    f"predictions every {step_size / 10:.1f}s. "
                    "Experimental scores: model timing and accuracy are not validated on this stream."
                )
                announced_andy = True
            acceleration = np.asarray(values[:3], dtype="float64")
            gyroscope = np.asarray(values[3:], dtype="float64") - bias

            accelerations.append(acceleration)
            gyroscopes.append(gyroscope)
            samples_since_prediction += 1
            if len(accelerations) < window_size or samples_since_prediction < step_size:
                continue
            samples_since_prediction = 0

            probability = predict(
                bundle, np.asarray(accelerations), np.asarray(gyroscopes)
            )
            if probability >= args.threshold:
                consecutive_fall_windows += 1
                print(f"Possible fall: probability={probability:.1%}")
            else:
                consecutive_fall_windows = 0
                print(f"Normal: probability={probability:.1%}")

            if consecutive_fall_windows >= args.consecutive_windows:
                print("*** POSSIBLE FALL — experimental software alert only ***")


def replay_member(args: argparse.Namespace, bundle: dict) -> None:
    path = resolve_recording(args.dataset_dir, args.replay_member)
    vectors, _ = read_sensor_vectors(path)
    count = min(len(vectors["acg"]), len(vectors["gyro"]))
    window_size = int(bundle["window_samples"])
    step_size = int(bundle["step_samples"])
    if count < window_size:
        raise SystemExit(f"Replay recording has only {count} paired samples")

    acceleration = vectors["acg"][:count]
    gyroscope = vectors["gyro"][:count]
    probabilities = []
    consecutive_fall_windows = 0
    detection_window = None
    for end in range(window_size, count + 1, step_size):
        probability = predict(
            bundle,
            acceleration[end - window_size : end],
            gyroscope[end - window_size : end],
        )
        probabilities.append(probability)
        print(f"samples {end-window_size:4d}-{end:4d}: fall probability={probability:.1%}")
        if probability >= args.threshold:
            consecutive_fall_windows += 1
        else:
            consecutive_fall_windows = 0
        if (
            detection_window is None
            and consecutive_fall_windows >= args.consecutive_windows
        ):
            detection_window = (end - window_size, end)
    print(f"Replay maximum fall probability: {max(probabilities):.1%}")
    if detection_window:
        print(
            "Replay result: FALL DETECTED "
            f"at samples {detection_window[0]}-{detection_window[1]}"
        )
    else:
        print("Replay result: no fall trigger")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", type=Path, default=DEFAULT_MODEL)
    parser.add_argument("--port")
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--input-format", choices=("auto", "andy", "csv", "timestamped"), default="auto")
    parser.add_argument("--acceleration-unit", choices=("g", "mps2"), default="mps2")
    parser.add_argument("--gyroscope-unit", choices=("dps", "rads"), default="rads")
    parser.add_argument("--threshold", type=float, default=0.70)
    parser.add_argument("--consecutive-windows", type=int, default=2)
    parser.add_argument("--show-bad-lines", action="store_true")
    parser.add_argument("--show-raw", action="store_true")
    parser.add_argument("--no-data-timeout", type=positive_seconds, default=10.0)
    parser.add_argument("--gyro-calibration", type=Path, help="Optional bias JSON for the same physical sensor; serial only.")
    parser.add_argument("--replay-member")
    parser.add_argument("--dataset-dir", type=Path, default=DEFAULT_DATASET_DIR)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if not 0 <= args.threshold <= 1 or args.consecutive_windows < 1:
        raise SystemExit("Threshold must be between 0 and 1; consecutive windows must be at least 1.")
    if args.replay_member and args.gyro_calibration:
        raise SystemExit("Do not apply your hardware calibration to public-dataset replay.")
    bundle = joblib.load(args.model)
    try:
        if args.replay_member:
            replay_member(args, bundle)
        else:
            run_serial(args, bundle)
    except KeyboardInterrupt:
        print("\nDetection stopped.")
    except (RuntimeError, ValueError, OSError, serial.SerialException) as error:
        raise SystemExit(str(error)) from error


if __name__ == "__main__":
    main()
