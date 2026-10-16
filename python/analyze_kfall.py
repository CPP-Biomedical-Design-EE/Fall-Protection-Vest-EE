"""Audit and graph the KFall dataset without changing existing models.

The script accepts an extracted UniVrFall_Dataset directory. It reads one CSV
at a time, writes a recording-level audit CSV/JSON, and can save one six-axis
graph. It intentionally keeps Euler angles out of the model-facing data.
"""
from __future__ import annotations

import argparse
import json
import re
import zipfile
import xml.etree.ElementTree as ET
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np
import pandas as pd

SAMPLE_RATE_HZ = 100.0
GRAVITY = 9.80665
TASK_LABELS = {
    **{task: "adl" for task in range(1, 20)},
    **{task: "fall" for task in range(20, 35)},
    **{task: "fall" for task in range(37, 43)},
    35: "adl", 36: "adl", 43: "adl", 44: "adl", 88: "adl",
}
LAB_FILE_RE = re.compile(r"S(?P<subject>\d+)T(?P<task>\d+)R(?P<trial>\d+)", re.I)


def classify_task(task):
    return TASK_LABELS.get(int(task), "unknown")


def _find_column(columns, *names):
    normalized = {str(column).strip().lower(): column for column in columns}
    for name in names:
        if name.lower() in normalized:
            return normalized[name.lower()]
    return None


def read_sensor_csv(path, dataset_kind="kfall"):
    frame = pd.read_csv(path)
    timestamp = _find_column(frame.columns, "TimeStamp(s)", "timestamp", "time", "Unnamed: 0")
    frame_counter = _find_column(frame.columns, "FrameCounter", "framecounter", "frame", "id")
    acc = [_find_column(frame.columns, f"Acc{axis}", f"acc{axis}") for axis in "XYZ"]
    gyro = [_find_column(frame.columns, f"Gyr{axis}", f"gyr{axis}") for axis in "XYZ"]
    if any(column is None for column in acc + gyro):
        raise ValueError(f"missing six-axis columns in {path}")
    if _find_column(frame.columns, "type") is not None:
        type_column = _find_column(frame.columns, "type")
        frame = frame[frame[type_column] == 1].copy()
    values = frame[[timestamp, frame_counter, *acc, *gyro]].copy()
    values.columns = ["timestamp_s", "frame", "ax", "ay", "az", "gx", "gy", "gz"]
    values = values.apply(pd.to_numeric, errors="coerce").dropna()
    if dataset_kind == "univrfall":
        # UNIVRFall files contain integer milli-g and milli-deg/s values, with
        # timestamps in milliseconds despite the column name.
        values["timestamp_s"] /= 1_000.0
        values[["ax", "ay", "az"]] /= 1_000.0
        values[["gx", "gy", "gz"]] /= 1_000.0
    return values


def recording_metadata(path):
    match = LAB_FILE_RE.search(path.stem)
    task = int(match.group("task")) if match else None
    return {
        "file": str(path),
        "source": "laboratory" if match else "onfield",
        "subject": match.group("subject") if match else "unknown",
        "task": task if task is not None else "onfield",
        "trial": int(match.group("trial")) if match else "unknown",
        "label": classify_task(task) if task is not None else "adl",
    }


def summarize(path, dataset_kind="kfall"):
    values = read_sensor_csv(path, dataset_kind)
    result = recording_metadata(path)
    result["samples"] = int(len(values))
    result["duration_s"] = float(values.timestamp_s.iloc[-1] - values.timestamp_s.iloc[0]) if len(values) > 1 else 0.0
    intervals = np.diff(values.timestamp_s.to_numpy())
    intervals = intervals[np.isfinite(intervals) & (intervals > 0)]
    result["median_rate_hz"] = float(1.0 / np.median(intervals)) if len(intervals) else None
    acceleration = values[["ax", "ay", "az"]].to_numpy()
    rotation = values[["gx", "gy", "gz"]].to_numpy()
    result["max_acceleration_g"] = float(np.linalg.norm(acceleration, axis=1).max()) if len(values) else None
    result["max_rotation_dps"] = float(np.linalg.norm(rotation, axis=1).max()) if len(values) else None
    result["rate_error_hz"] = (result["median_rate_hz"] - SAMPLE_RATE_HZ
                                if result["median_rate_hz"] is not None else None)
    return result


def read_annotations(label_root):
    rows = []
    namespace = {"x": "http://schemas.openxmlformats.org/spreadsheetml/2006/main"}
    for workbook in sorted(Path(label_root).glob("*.xlsx")):
        subject_match = re.search(r"SA(\d+)", workbook.stem, re.I)
        subject = subject_match.group(1) if subject_match else "unknown"
        with zipfile.ZipFile(workbook) as archive:
            xml = ET.fromstring(archive.read("xl/worksheets/sheet1.xml"))
            shared = []
            if "xl/sharedStrings.xml" in archive.namelist():
                shared_xml = ET.fromstring(archive.read("xl/sharedStrings.xml"))
                shared = ["".join(node.itertext()) for node in shared_xml.findall(".//x:si", namespace)]
        current_task, current_description = None, None
        for row in xml.findall(".//x:row", namespace):
            cells = {}
            for cell in row.findall("x:c", namespace):
                ref = cell.attrib.get("r", "")
                column = re.match(r"[A-Z]+", ref)
                if not column:
                    continue
                text = cell.find("x:is/x:t", namespace)
                value = text.text if text is not None else (cell.findtext("x:v", default="", namespaces=namespace))
                if cell.attrib.get("t") == "s" and value != "":
                    value = shared[int(value)]
                cells[column.group(0)] = value
            if cells.get("A"):
                current_task = cells["A"]
                current_description = cells.get("B", "")
            if cells.get("C") and cells.get("D") and cells.get("E") and current_task:
                task_match = re.search(r"\((\d+)\)", current_task)
                if task_match:
                    rows.append({
                        "subject": subject,
                        "task": int(task_match.group(1)),
                        "task_code": current_task.split()[0],
                        "description": current_description,
                        "trial": int(float(cells["C"])),
                        "fall_onset_frame": int(float(cells["D"])),
                        "fall_impact_frame": int(float(cells["E"])),
                    })
    return pd.DataFrame(rows)


def plot_recording(path, output_path, annotations=None, dataset_kind="kfall"):
    values = read_sensor_csv(path, dataset_kind)
    elapsed = values.timestamp_s - values.timestamp_s.iloc[0]
    figure, axes = plt.subplots(2, 1, figsize=(13, 7), sharex=True)
    axes[0].plot(elapsed, values[["ax", "ay", "az"]])
    axes[0].set_ylabel("Acceleration (g)")
    axes[0].legend(["Ax", "Ay", "Az"], loc="upper right")
    axes[0].grid(alpha=0.25)
    axes[1].plot(elapsed, values[["gx", "gy", "gz"]])
    axes[1].set_ylabel("Rotation (deg/s)")
    axes[1].set_xlabel("Elapsed time (s)")
    axes[1].legend(["Gx", "Gy", "Gz"], loc="upper right")
    axes[1].grid(alpha=0.25)
    if annotations is not None and not annotations.empty:
        metadata = recording_metadata(path)
        matches = annotations[(annotations.subject.astype(str) == str(metadata["subject"])) &
                             (annotations.task == metadata["task"]) &
                             (annotations.trial == metadata["trial"])]
        if not matches.empty:
            row = matches.iloc[0]
            for frame, color, label in ((row.fall_onset_frame, "#d97706", "fall onset"),
                                        (row.fall_impact_frame, "#b91c1c", "impact")):
                index = min(max(int(frame) - 1, 0), len(values) - 1)
                event_time = float(elapsed.iloc[index])
                for axis in axes:
                    axis.axvline(event_time, color=color, linestyle="--", alpha=.8, label=label)
            axes[0].legend(loc="upper right")
            axes[1].legend(loc="upper right")
    figure.suptitle(f"{dataset_kind.upper()} six-axis recording: {path.name}")
    figure.tight_layout()
    figure.savefig(output_path, dpi=150)
    plt.close(figure)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dataset-root", required=True, type=Path)
    parser.add_argument("--dataset-kind", choices=("kfall", "univrfall"), default="kfall")
    parser.add_argument("--output-dir", default=Path("Python/Data/processed/kfall"), type=Path)
    parser.add_argument("--label-root", type=Path, help="Directory containing SAxx_label.xlsx files")
    parser.add_argument("--plot-member", type=Path, help="CSV path, absolute or relative to dataset root")
    args = parser.parse_args()
    csv_files = sorted(args.dataset_root.rglob("*.csv"))
    if not csv_files:
        raise SystemExit(f"No CSV files found under {args.dataset_root}")
    args.output_dir.mkdir(parents=True, exist_ok=True)
    rows, failures = [], []
    for path in csv_files:
        try:
            rows.append(summarize(path, args.dataset_kind))
        except (OSError, ValueError, KeyError, pd.errors.ParserError) as error:
            failures.append({"file": str(path), "error": str(error)})
    audit = pd.DataFrame(rows)
    audit.to_csv(args.output_dir / "recordings.csv", index=False)
    annotations = read_annotations(args.label_root) if args.label_root else pd.DataFrame()
    if not annotations.empty:
        annotations.to_csv(args.output_dir / "annotations.csv", index=False)
    summary = {
        "dataset_root": str(args.dataset_root),
        "expected_rate_hz": SAMPLE_RATE_HZ,
        "csv_files_found": len(csv_files),
        "recordings_indexed": len(rows),
        "files_failed": len(failures),
        "labels": audit["label"].value_counts().to_dict() if not audit.empty else {},
        "subjects": int(audit["subject"].nunique()) if not audit.empty else 0,
        "total_samples": int(audit["samples"].sum()) if not audit.empty else 0,
        "total_duration_h": float(audit["duration_s"].sum() / 3600) if not audit.empty else 0.0,
        "median_recording_rate_hz": float(audit["median_rate_hz"].median()) if not audit.empty else None,
        "dataset_kind": args.dataset_kind,
        "acceleration_values_used_as": "g",
        "gyro_values_used_as": "deg/s",
        "annotation_rows": int(len(annotations)),
        "failures": failures,
        "note": "Six-axis audit only; Euler angles and existing InflateBody models are not modified.",
    }
    (args.output_dir / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    if args.plot_member:
        member = args.plot_member if args.plot_member.is_absolute() else args.dataset_root / args.plot_member
        plot_recording(member, args.output_dir / "recording.png", annotations, args.dataset_kind)
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
