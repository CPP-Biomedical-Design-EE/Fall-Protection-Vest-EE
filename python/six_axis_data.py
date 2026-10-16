"""Read acceleration and gyro only. Filtering channels does not change placement."""
import csv
import re
from pathlib import Path

import numpy as np

PYTHON_DIR = Path(__file__).resolve().parent
PROJECT_DIR = PYTHON_DIR.parent
DATA_COLLECTION_DIR = PROJECT_DIR.parent / "Data Collection"
DEFAULT_DATASET_DIR = DATA_COLLECTION_DIR / "Dataset"
PROCESSED_DIR = PYTHON_DIR / "Data" / "processed"
REQUIRED_SENSOR_TAGS = ("acg", "gyro")
SENSOR_PREFIXES = {"acg": "acc", "gyro": "gyro"}


def recording_number(filename):
    match = re.search(r"(?:adl|fall)(\d+)\.csv$", filename, flags=re.IGNORECASE)
    return int(match.group(1)) if match else -1


def iter_recordings(dataset_dir):
    for label in ("adl", "fall"):
        yield from sorted((Path(dataset_dir) / label).glob("user*/*.csv"))


def recording_metadata(path, dataset_dir):
    relative = path.relative_to(dataset_dir)
    if len(relative.parts) != 3 or relative.parts[0].lower() not in {"adl", "fall"}:
        raise ValueError(f"Unexpected dataset path: {path}")
    label = relative.parts[0].lower()
    return {"recording": relative.as_posix(), "user": relative.parts[1],
            "label": label, "is_fall": int(label == "fall")}


def resolve_recording(dataset_dir, name):
    relative = Path(name)
    if relative.parts and relative.parts[0].lower() == "dataset":
        relative = Path(*relative.parts[1:])
    root = Path(dataset_dir).resolve()
    path = (root / relative).resolve()
    try:
        path.relative_to(root)
    except ValueError:
        raise ValueError("Recording must be inside the selected dataset folder") from None
    if not path.is_file():
        raise FileNotFoundError(f"Recording not found: {path}")
    return path


def read_sensor_vectors(path):
    """Return finite ACG/gyro vectors and original total data-row count.

    Existing replay pairs channels by source row order, not timestamp.
    This does not establish synchronized live data or waist provenance.
    """
    rows = {sensor: [] for sensor in REQUIRED_SENSOR_TAGS}
    row_count = 0
    with Path(path).open(encoding="utf-8-sig", newline="") as source:
        reader = csv.reader(source)
        next(reader, None)
        for row in reader:
            if not row:
                continue
            row_count += 1
            if len(row) < 6 or row[-1].strip().lower() not in rows:
                continue
            try:
                values = [float(value) for value in row[1:4]]
            except ValueError:
                continue
            if not np.isfinite(values).all():
                raise ValueError(f"Nonfinite sensor data in {path}, data row {row_count}")
            rows[row[-1].strip().lower()].append(values)
    return {sensor: np.asarray(values, dtype="float64").reshape(-1, 3)
            for sensor, values in rows.items()}, row_count
