"""Create fixed-size 6-axis MPU6050 windows for live fall detection."""

import argparse
from pathlib import Path

import numpy as np
import pandas as pd

from extract_recording_features import summarize
from six_axis_data import (
    DEFAULT_DATASET_DIR,
    PROCESSED_DIR,
    iter_recordings,
    read_sensor_vectors,
    recording_metadata,
)


DEFAULT_OUTPUT = PROCESSED_DIR / "window_features.csv"
WINDOW_SIZE = 40
WINDOW_STEP = 20
MAX_WINDOWS_PER_RECORDING = 3
MINIMUM_SAMPLES = 20


def candidate_windows(sample_count: int) -> list[tuple[int, int]]:
    if sample_count < MINIMUM_SAMPLES:
        return []
    if sample_count <= WINDOW_SIZE:
        return [(0, sample_count)]

    starts = list(range(0, sample_count - WINDOW_SIZE + 1, WINDOW_STEP))
    final_start = sample_count - WINDOW_SIZE
    if starts[-1] != final_start:
        starts.append(final_start)
    return [(start, start + WINDOW_SIZE) for start in starts]


def select_windows(
    windows: list[tuple[int, int]], acceleration: np.ndarray, is_fall: bool
) -> list[tuple[int, int]]:
    if len(windows) <= MAX_WINDOWS_PER_RECORDING:
        return windows

    if is_fall:
        # Keep the windows containing the strongest possible impacts.
        scored = [
            (float(np.linalg.norm(acceleration[start:end], axis=1).max()), start, end)
            for start, end in windows
        ]
        selected = sorted(scored, reverse=True)[:MAX_WINDOWS_PER_RECORDING]
        return sorted((start, end) for _, start, end in selected)

    # Spread normal-activity windows over the complete recording.
    positions = np.linspace(0, len(windows) - 1, MAX_WINDOWS_PER_RECORDING, dtype=int)
    return [windows[position] for position in sorted(set(positions))]


def extract(source: Path) -> pd.DataFrame:
    output = []
    skipped = 0
    recordings = list(iter_recordings(source))
    for index, path in enumerate(recordings, start=1):
        metadata = recording_metadata(path, source)
        is_fall = bool(metadata["is_fall"])
        vectors, _ = read_sensor_vectors(path)
        acceleration = vectors["acg"]
        gyroscope = vectors["gyro"]
        usable_samples = min(len(acceleration), len(gyroscope))
        windows = candidate_windows(usable_samples)
        if not windows:
            skipped += 1
            continue

        for window_number, (start, end) in enumerate(
            select_windows(windows, acceleration, is_fall), start=1
        ):
            record = {
                **metadata,
                "window_number": window_number,
                "window_start": start,
                "window_end": end,
                "window_samples": end - start,
            }
            record.update(summarize(acceleration[start:end], "acc"))
            record.update(summarize(gyroscope[start:end], "gyro"))
            output.append(record)

        if index % 100 == 0 or index == len(recordings):
            print(f"Processed {index}/{len(recordings)} recordings")

    frame = pd.DataFrame.from_records(output)
    if frame.empty or frame.isna().any().any():
        raise ValueError("Window feature extraction produced empty or missing data")
    print(f"Skipped recordings with fewer than {MINIMUM_SAMPLES} paired samples: {skipped}")
    return frame


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset-dir", type=Path, default=DEFAULT_DATASET_DIR)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    frame = extract(args.dataset_dir)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    frame.to_csv(args.output, index=False)
    print(f"Saved {len(frame):,} windows from {frame['recording'].nunique():,} recordings")
    print(f"Class counts: {frame['label'].value_counts().to_dict()}")
    print(f"Output: {args.output}")


if __name__ == "__main__":
    main()
