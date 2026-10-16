"""Extract six-axis public-data acceleration and gyroscope features."""

import argparse
from pathlib import Path

import numpy as np
import pandas as pd

from six_axis_data import (
    DEFAULT_DATASET_DIR,
    PROCESSED_DIR,
    SENSOR_PREFIXES,
    iter_recordings,
    read_sensor_vectors,
    recording_metadata,
)


DEFAULT_OUTPUT = PROCESSED_DIR / "recording_features.csv"
SENSORS = ("acg", "gyro")
STATISTICS = ("mean", "std", "min", "max", "median", "p05", "p25", "p75", "p95", "rms")


def summarize(values: np.ndarray, prefix: str) -> dict:
    features = {}
    channels = {
        "x": values[:, 0],
        "y": values[:, 1],
        "z": values[:, 2],
        "magnitude": np.linalg.norm(values, axis=1),
    }

    for channel_name, channel in channels.items():
        feature_prefix = f"{prefix}_{channel_name}"
        feature_values = {
            "mean": np.mean(channel),
            "std": np.std(channel),
            "min": np.min(channel),
            "max": np.max(channel),
            "median": np.median(channel),
            "p05": np.percentile(channel, 5),
            "p25": np.percentile(channel, 25),
            "p75": np.percentile(channel, 75),
            "p95": np.percentile(channel, 95),
            "rms": np.sqrt(np.mean(np.square(channel))),
        }
        for statistic in STATISTICS:
            features[f"{feature_prefix}_{statistic}"] = float(feature_values[statistic])

    magnitude = channels["magnitude"]
    differences = np.abs(np.diff(magnitude))
    features[f"{prefix}_magnitude_mean_abs_change"] = (
        float(np.mean(differences)) if len(differences) else 0.0
    )
    features[f"{prefix}_magnitude_max_abs_change"] = (
        float(np.max(differences)) if len(differences) else 0.0
    )
    return features


def validate_feature_columns(columns):
    """Reject stale or unrelated channels before training or prediction."""
    example = np.zeros((2, 3))
    expected = set(summarize(example, "acc")) | set(summarize(example, "gyro"))
    if len(columns) != len(expected) or set(columns) != expected:
        raise ValueError("Expected exactly the current 84 acceleration/gyro features. Re-extract six-axis features first.")


def extract_features(source: Path) -> pd.DataFrame:
    records = []
    recordings = list(iter_recordings(source))
    for index, path in enumerate(recordings, start=1):
        record = recording_metadata(path, source)
        vectors, _ = read_sensor_vectors(path)
        for sensor in SENSORS:
            if len(vectors[sensor]) == 0:
                raise ValueError(f"No usable {sensor} rows in {path}")
            record.update(summarize(vectors[sensor], SENSOR_PREFIXES[sensor]))
        records.append(record)

        if index % 100 == 0 or index == len(recordings):
            print(f"Processed {index}/{len(recordings)} recordings")

    frame = pd.DataFrame.from_records(records)
    if frame.isna().any().any():
        raise ValueError("Extracted feature table contains missing values")
    return frame


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset-dir", type=Path, default=DEFAULT_DATASET_DIR)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    features = extract_features(args.dataset_dir)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    features.to_csv(args.output, index=False)
    print(f"Saved {len(features):,} recordings with {len(features.columns) - 4} features")
    print(f"Output: {args.output}")


if __name__ == "__main__":
    main()
