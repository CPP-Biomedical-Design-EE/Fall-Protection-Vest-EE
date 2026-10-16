"""Plot raw six-axis recordings for exploratory fall-signal review.

This tool reports acceleration magnitude, gyroscope magnitude, and acceleration
direction change relative to the recording's initial reference. It does not
apply thresholds or decide whether a fall occurred. Accelerometer direction
change is only a rough orientation proxy while acceleration is near gravity.
"""

import argparse
import csv
from pathlib import Path
from typing import Dict, Tuple

import matplotlib.pyplot as plt
import numpy as np


GRAVITY = 9.80665
AXES = ("ax", "ay", "az")
GYRO_AXES = ("gx", "gy", "gz")
DEFAULT_OUTPUT_DIR = Path(__file__).resolve().parent / "Data" / "processed" / "recording_analysis"


def analyze_recording(path: Path, reference_seconds: float = 1.0) -> Tuple[Dict, Dict, Dict]:
    """Load a collector CSV and calculate per-sample exploratory signals."""
    if reference_seconds <= 0:
        raise ValueError("reference_seconds must be positive")

    required = {"elapsed_s", "label", "subject_id", "acceleration_unit", "gyroscope_unit",
                *AXES, *GYRO_AXES}
    with path.open(newline="", encoding="utf-8") as source:
        reader = csv.DictReader(source)
        missing = required - set(reader.fieldnames or ())
        if missing:
            raise ValueError(f"Missing required recording columns: {', '.join(sorted(missing))}")
        rows = list(reader)

    if not rows:
        raise ValueError("Recording contains no samples")
    if any(row["acceleration_unit"] != "m/s^2" or row["gyroscope_unit"] != "rad/s" for row in rows):
        raise ValueError("Expected collector data in m/s^2 and rad/s")

    try:
        elapsed = np.asarray([float(row["elapsed_s"]) for row in rows], dtype="float64")
        acceleration = np.asarray(
            [[float(row[axis]) for axis in AXES] for row in rows], dtype="float64"
        )
        gyroscope = np.asarray(
            [[float(row[axis]) for axis in GYRO_AXES] for row in rows], dtype="float64"
        )
    except (TypeError, ValueError) as error:
        raise ValueError("Recording contains a missing or invalid numeric sample") from error

    if not np.isfinite(elapsed).all() or not np.isfinite(acceleration).all() or not np.isfinite(gyroscope).all():
        raise ValueError("Recording contains non-finite samples")
    if np.any(np.diff(elapsed) < 0):
        raise ValueError("elapsed_s must be nondecreasing")

    acceleration_magnitude = np.linalg.norm(acceleration, axis=1)
    acceleration_g = acceleration_magnitude / GRAVITY
    gyroscope_dps = np.rad2deg(np.linalg.norm(gyroscope, axis=1))

    reference_end = elapsed[0] + reference_seconds
    reference_count = max(1, int(np.searchsorted(elapsed, reference_end, side="right")))
    reference = np.mean(acceleration[:reference_count], axis=0)
    reference_magnitude = float(np.linalg.norm(reference))
    if reference_magnitude == 0:
        raise ValueError("Initial reference acceleration has zero magnitude")
    reference_direction = reference / reference_magnitude

    safe_magnitudes = np.where(acceleration_magnitude == 0, 1.0, acceleration_magnitude)
    directions = acceleration / safe_magnitudes[:, None]
    cosines = np.clip(directions @ reference_direction, -1.0, 1.0)
    direction_change = np.rad2deg(np.arccos(cosines))
    direction_change[acceleration_magnitude == 0] = np.nan

    device_intervals = np.asarray(
        [float(row["sample_interval_s"]) for row in rows
         if row.get("sample_interval_s") not in (None, "")], dtype="float64"
    )
    device_intervals = device_intervals[np.isfinite(device_intervals) & (device_intervals > 0)]
    if len(device_intervals):
        sample_rate_hz = float(1.0 / np.median(device_intervals))
        sample_rate_source = "device sample intervals"
    else:
        intervals = np.diff(elapsed)
        positive_intervals = intervals[intervals > 0]
        sample_rate_hz = float(1.0 / np.median(positive_intervals)) if len(positive_intervals) else None
        sample_rate_source = "host receipt intervals" if sample_rate_hz is not None else "unknown"
    gaps = sum(row.get("stream_discontinuity", "0") == "1" for row in rows)
    metadata = {"label": rows[0]["label"], "subject_id": rows[0]["subject_id"]}
    signals = {
        "elapsed_s": elapsed,
        "acceleration_g": acceleration_g,
        "gyroscope_dps": gyroscope_dps,
        "acceleration_direction_change_deg": direction_change,
        "reference_samples": reference_count,
    }
    summary = {
        "samples": len(rows),
        "estimated_sample_rate_hz": sample_rate_hz,
        "sample_rate_source": sample_rate_source,
        "acceleration_min_g": float(np.min(acceleration_g)),
        "acceleration_max_g": float(np.max(acceleration_g)),
        "gyroscope_peak_dps": float(np.max(gyroscope_dps)),
        "acceleration_direction_change_peak_deg": float(np.nanmax(direction_change)),
        "stream_discontinuities": gaps,
    }
    return metadata, signals, summary


def save_plot(metadata: Dict, signals: Dict, output: Path, show: bool = False) -> None:
    """Save a plot of the three exploratory signals; optionally display it."""
    figure, axes = plt.subplots(3, 1, figsize=(12, 8), sharex=True)
    figure.suptitle(f"Exploratory sensor signals — {metadata['subject_id']} / {metadata['label']}")
    axes[0].plot(signals["elapsed_s"], signals["acceleration_g"], color="#2563eb")
    axes[0].set_ylabel("Acceleration (g)")
    axes[1].plot(signals["elapsed_s"], signals["gyroscope_dps"], color="#ea580c")
    axes[1].set_ylabel("Gyroscope magnitude (°/s)")
    axes[2].plot(signals["elapsed_s"], signals["acceleration_direction_change_deg"], color="#059669")
    axes[2].set_ylabel("Accel direction change (°)")
    axes[2].set_xlabel("Elapsed time (s)")
    for axis in axes:
        axis.grid(True, alpha=0.25)
    figure.text(
        0.5, 0.01,
        "Exploratory only: no thresholds or fall decision. Acceleration direction is not fused orientation.",
        ha="center", fontsize=9,
    )
    figure.tight_layout(rect=(0, 0.04, 1, 0.95))
    output.parent.mkdir(parents=True, exist_ok=True)
    figure.savefig(output, dpi=150)
    if show:
        plt.show()
    plt.close(figure)
    print(f"Plot saved to: {output}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, type=Path, help="Collector CSV to inspect")
    parser.add_argument("--reference-seconds", type=float, default=1.0,
                        help="Initial reference interval for acceleration direction (default: 1 second)")
    parser.add_argument("--output", type=Path, help="Plot destination; defaults under Data/processed/recording_analysis")
    parser.add_argument("--show", action="store_true", help="Display the plot after saving it")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    metadata, signals, summary = analyze_recording(args.input, args.reference_seconds)
    output = args.output or DEFAULT_OUTPUT_DIR / f"{args.input.stem}_analysis.png"
    print(f"Recording: subject {metadata['subject_id']}, label {metadata['label']}")
    rate = summary["estimated_sample_rate_hz"]
    if rate is not None:
        print(f"Samples: {summary['samples']}; estimated rate from {summary['sample_rate_source']}: {rate:.2f} Hz")
    else:
        print(f"Samples: {summary['samples']}; sampling rate unavailable")
    print(f"Acceleration magnitude: {summary['acceleration_min_g']:.3f}–{summary['acceleration_max_g']:.3f} g")
    print(f"Peak gyroscope magnitude: {summary['gyroscope_peak_dps']:.1f} deg/s")
    print(f"Peak acceleration direction change: {summary['acceleration_direction_change_peak_deg']:.1f} deg")
    print(f"Recorded stream discontinuities: {summary['stream_discontinuities']}")
    print("No threshold was applied; this tool does not decide whether a fall occurred.")
    save_plot(metadata, signals, output, args.show)


if __name__ == "__main__":
    main()