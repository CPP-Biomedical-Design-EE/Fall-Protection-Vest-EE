"""Estimate gyro zero-rate bias from one stationary, uncorrected collector CSV.

Method: https://learn.adafruit.com/adafruit-sensorlab-gyroscope-calibration
Quality thresholds below are provisional screening limits, not validated
fall-detection thresholds. Constant slow rotation cannot be distinguished from
bias: the user must physically hold the sensor still throughout acquisition.
"""
import argparse
import csv
import json
from datetime import datetime, timezone
from pathlib import Path

import numpy as np

GRAVITY = 9.80665


def estimate_calibration(rows):
    if len(rows) < 50:
        raise ValueError("Need at least 50 stationary samples; record for 10 seconds.")
    if {row["label"] for row in rows} != {"stationary_calibration"}:
        raise ValueError("Use a dedicated --label stationary_calibration recording.")
    for key, expected in (("acceleration_unit", "m/s^2"), ("gyroscope_unit", "rad/s")):
        if {row[key] for row in rows} != {expected}:
            raise ValueError(f"Calibration requires {expected} units.")
    if len({row["placement"] for row in rows}) != 1:
        raise ValueError("Mixed sensor placements are not allowed.")
    has_device_time = [bool(row.get("device_elapsed_s", "")) for row in rows]
    if any(has_device_time) and not all(has_device_time):
        raise ValueError("Mixed timestamped and untimed samples; make a separate calibration recording.")
    time_field = "device_elapsed_s" if all(has_device_time) else "elapsed_s"
    if any(row.get("stream_discontinuity", "0") == "1" for row in rows):
        raise ValueError("Recording has a stream discontinuity; repeat stationary calibration.")
    data = np.asarray([[float(row[key]) for key in (time_field, "ax", "ay", "az", "gx", "gy", "gz")]
                       for row in rows])
    if not np.isfinite(data).all():
        raise ValueError("Calibration contains nonfinite values.")
    intervals = np.diff(data[:, 0])
    duration = float(data[-1, 0] - data[0, 0])
    if duration < 5 or np.any(intervals <= 0) or np.any(intervals > 1):
        raise ValueError("Need at least 5 seconds of ordered samples with no gaps over 1 second.")
    acceleration, gyro = data[:, 1:4], data[:, 4:7]
    norm_g = float(np.linalg.norm(acceleration, axis=1).mean() / GRAVITY)
    if not 0.95 <= norm_g <= 1.05:
        raise ValueError(f"Stationary acceleration is {norm_g:.3f} g, outside provisional 0.95-1.05 g check. Check sensor/units; gyro calibration cannot fix acceleration.")
    if np.max(np.ptp(acceleration, axis=0)) > 0.5 or np.max(np.ptp(gyro, axis=0)) > 0.05:
        raise ValueError("Readings are not stable enough. Hold the sensor still and record again.")
    bias = gyro.mean(axis=0)
    if np.max(np.abs(bias)) > 0.2:
        raise ValueError("Gyro offset is unusually large (>0.2 rad/s). Check sensor before calibration.")
    return {"schema_version": 1, "sensor": "MPU6050", "gyroscope_unit": "rad/s",
            "bias_rads": bias.tolist(), "samples": len(rows), "duration_s": duration,
            "placement": rows[0]["placement"], "time_source": time_field, "mean_acceleration_g": norm_g,
            "gyro_peak_to_peak_rads": np.ptp(gyro, axis=0).tolist(),
            "created_utc": datetime.now(timezone.utc).isoformat(),
            "validation": "Stationarity screening only; not a fall-performance validation."}


def load_gyro_bias(path):
    if path is None:
        return np.zeros(3)
    with Path(path).open(encoding="utf-8") as source:
        calibration = json.load(source)
    if (calibration.get("schema_version") != 1 or calibration.get("sensor") != "MPU6050"
            or calibration.get("gyroscope_unit") != "rad/s"):
        raise ValueError("Unsupported calibration schema, sensor, or units.")
    bias = np.asarray(calibration.get("bias_rads"), dtype=float)
    if bias.shape != (3,) or not np.isfinite(bias).all() or np.max(np.abs(bias)) > 0.2:
        raise ValueError("Invalid gyro bias: need three finite offsets within +/-0.2 rad/s.")
    return bias


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True,
                        help="New JSON path; existing calibration files are never overwritten.")
    args = parser.parse_args()
    try:
        with args.input.open(encoding="utf-8-sig", newline="") as source:
            calibration = estimate_calibration(list(csv.DictReader(source)))
        calibration["source_csv"] = str(args.input.resolve())
        args.output.parent.mkdir(parents=True, exist_ok=True)
        with args.output.open("x", encoding="utf-8") as target:
            json.dump(calibration, target, indent=2)
    except (OSError, ValueError, KeyError) as error:
        raise SystemExit(f"Calibration not saved: {error}") from error
    print(f"Saved gyro bias (rad/s): {calibration['bias_rads']}\nFile: {args.output.resolve()}")
    print("Use only with the same physical sensor. Raw collection stays unchanged.")


if __name__ == "__main__":
    main()
