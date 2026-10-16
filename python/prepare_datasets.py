"""Index only acceleration and gyro from the existing public dataset."""
import argparse
import json
from pathlib import Path

import pandas as pd

from six_axis_data import (DEFAULT_DATASET_DIR, PROCESSED_DIR, REQUIRED_SENSOR_TAGS,
                           iter_recordings, read_sensor_vectors, recording_metadata,
                           recording_number)


def build_six_axis_manifest(dataset_dir: Path, destination: Path) -> dict:
    paths = list(iter_recordings(dataset_dir))
    if not paths:
        raise ValueError(f"No fall or ADL recordings found in {dataset_dir}")
    records = []
    for index, path in enumerate(paths, 1):
        metadata = recording_metadata(path, dataset_dir)
        vectors, row_count = read_sensor_vectors(path)
        missing = [sensor for sensor in REQUIRED_SENSOR_TAGS if not len(vectors[sensor])]
        if missing:
            raise ValueError(f"{metadata['recording']} is missing: {', '.join(missing)}")
        records.append({**metadata, "recording_number": recording_number(path.name),
                        "row_count": row_count, "acg_samples": len(vectors["acg"]),
                        "gyro_samples": len(vectors["gyro"]), "sensor_types": "acg;gyro",
                        "placement": "unverified_public_source"})
        if index % 100 == 0 or index == len(paths):
            print(f"Verified {index}/{len(paths)} recordings")
    manifest = pd.DataFrame.from_records(records)
    destination.parent.mkdir(parents=True, exist_ok=True)
    manifest.to_csv(destination, index=False)
    return {"source": str(dataset_dir), "output": str(destination),
            "recordings": len(records), "users": int(manifest["user"].nunique()),
            "label_counts": {str(k): int(v) for k, v in manifest["label"].value_counts().items()},
            "total_sensor_rows": int(manifest["row_count"].sum()),
            "required_streams": {"acg": "acceleration including gravity (x, y, z)",
                                 "gyro": "gyroscope (x, y, z)"},
            "stream_file_counts": {sensor: len(records) for sensor in REQUIRED_SENSOR_TAGS},
            "placement": "unverified_public_source",
            "waist_validation": False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset-dir", type=Path, default=DEFAULT_DATASET_DIR)
    parser.add_argument("--output", type=Path, default=PROCESSED_DIR)
    args = parser.parse_args()
    manifest_path = args.output / "six_axis_dataset_manifest.csv"
    dataset = build_six_axis_manifest(args.dataset_dir, manifest_path)
    summary = {"six_axis_dataset": dataset, "notes": [
        "Source recordings are read only; selecting channels does not change their placement.",
        "Public-data results are not lower-back/waist or live-hardware validation.",
        "New locally labeled waist recordings are kept separate and not automatically trained.",
    ]}
    summary_path = args.output / "dataset_summary.json"
    summary_path.write_text(json.dumps(summary, indent=2), encoding="utf-8")
    print(f"Six-axis recordings: {dataset['recordings']}; users: {dataset['users']}")
    print(f"Manifest: {manifest_path}\nSummary: {summary_path}")


if __name__ == "__main__":
    main()
