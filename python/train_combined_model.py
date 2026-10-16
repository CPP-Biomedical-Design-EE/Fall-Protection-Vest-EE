"""Train an exploratory combined KFall + local lower-back SVM."""
import json
import re
from pathlib import Path

import joblib
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd
from sklearn.metrics import ConfusionMatrixDisplay, confusion_matrix
from sklearn.model_selection import GroupShuffleSplit
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import StandardScaler
from sklearn.svm import SVC

from analyze_kfall import read_sensor_csv, classify_task
from extract_recording_features import summarize, validate_feature_columns
from train_local_model import choose_windows, windows

BASE_DIR = Path(__file__).resolve().parent
LOCAL_ROOT = BASE_DIR / "Data" / "recordings" / "P01"
KFALL_ROOT = BASE_DIR.parent.parent / "Data Collection" / "sensor_data_new_2"
MODEL_DIR = BASE_DIR / "Models"
GRAPH_DIR = BASE_DIR / "Graphs"
META = ["recording", "source", "action_label", "label", "is_fall", "window_number", "window_start", "window_end"]


def add_windows(rows, recording, source, action_label, label, acceleration, gyro):
    count = min(len(acceleration), len(gyro))
    is_fall = label == "fall"
    selected = choose_windows(windows(count), acceleration, is_fall)
    if source == "kfall" and selected:
        selected = [selected[len(selected) // 2]]
    for number, (start, end) in enumerate(selected, start=1):
        row = {"recording": recording, "source": source, "action_label": action_label, "label": label,
               "is_fall": int(is_fall), "window_number": number,
               "window_start": start, "window_end": end}
        row.update(summarize(acceleration[start:end], "acc"))
        row.update(summarize(gyro[start:end], "gyro"))
        rows.append(row)


def load_combined(local_root, kfall_root):
    rows = []
    for path in sorted(local_root.rglob("*.csv")):
        label = path.parent.name
        if label.startswith("cal_") or not label.startswith(("adl_", "fall_")):
            continue
        frame = pd.read_csv(path)
        columns = ["ax", "ay", "az", "gx", "gy", "gz"]
        if any(column not in frame.columns for column in columns):
            continue
        add_windows(rows, str(path), "local", label, "fall" if label.startswith("fall_") else "adl",
                    frame[["ax", "ay", "az"]].to_numpy(float),
                    frame[["gx", "gy", "gz"]].to_numpy(float))

    for path in sorted(kfall_root.glob("SA*/S*T*R*.csv")):
        match = re.search(r"T(\d+)", path.stem, re.IGNORECASE)
        if not match:
            continue
        frame = read_sensor_csv(path, "kfall")
        acceleration = frame[["ax", "ay", "az"]].to_numpy(float) * 9.80665
        gyro = np.deg2rad(frame[["gx", "gy", "gz"]].to_numpy(float))
        task = int(match.group(1))
        add_windows(rows, str(path), "kfall", f"KFall T{task:02d}", classify_task(task), acceleration, gyro)
    result = pd.DataFrame(rows)
    if result.empty:
        raise ValueError("No local or KFall windows were found")
    feature_columns = [column for column in result.columns if column not in META]
    validate_feature_columns(feature_columns)
    return result, feature_columns


def main():
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--local-root", type=Path, default=LOCAL_ROOT)
    parser.add_argument("--kfall-root", type=Path, default=KFALL_ROOT)
    args = parser.parse_args()
    frame, feature_columns = load_combined(args.local_root, args.kfall_root)
    x, y, groups = frame[feature_columns], frame["is_fall"], frame["recording"]
    split = None
    for seed in range(42, 92):
        train, test = next(GroupShuffleSplit(n_splits=1, test_size=.25, random_state=seed).split(x, y, groups))
        if y.iloc[train].nunique() == 2 and y.iloc[test].nunique() == 2:
            split = train, test
            break
    if split is None:
        raise ValueError("Could not create a grouped split containing both classes")
    train, test = split
    model = Pipeline([("scale", StandardScaler()),
                      ("svm", SVC(kernel="rbf", C=2.0, gamma="scale", class_weight="balanced",
                                  probability=True, random_state=42))])
    model.fit(x.iloc[train], y.iloc[train])
    prediction = model.predict(x.iloc[test])
    probability = model.predict_proba(x.iloc[test])[:, 1]
    matrix = confusion_matrix(y.iloc[test], prediction, labels=[0, 1])
    tn, fp, fn, tp = matrix.ravel()
    result = {"accuracy": float((tn + tp) / matrix.sum()),
              "fall_recall": float(tp / (tp + fn)) if tp + fn else 0.0,
              "specificity": float(tn / (tn + fp)) if tn + fp else 0.0,
              "false_positive": int(fp), "false_negative": int(fn)}
    MODEL_DIR.mkdir(exist_ok=True)
    GRAPH_DIR.mkdir(exist_ok=True)
    model_path = MODEL_DIR / "combined_kfall_local_fall_detector.joblib"
    metrics_path = MODEL_DIR / "combined_kfall_local_fall_detector_metrics.json"
    predictions_path = MODEL_DIR / "combined_kfall_local_fall_detector_test_predictions.csv"
    graph_path = GRAPH_DIR / "combined_kfall_local_fall_detector_confusion_matrix.png"
    joblib.dump({"pipeline": model, "feature_columns": feature_columns,
                 "window_samples": 40, "step_samples": 20,
                 "sources": ["KFall", "P01 local lower-back"],
                 "validated_for_hardware": False}, model_path)
    output = frame.iloc[test][META].copy()
    output["predicted_is_fall"] = prediction
    output["fall_probability"] = probability
    output.to_csv(predictions_path, index=False)
    display = ConfusionMatrixDisplay(matrix, display_labels=["ADL", "Fall"])
    display.plot(cmap="Blues", colorbar=False)
    display.ax_.set_title("Combined KFall + Local Model — Grouped Holdout")
    display.figure_.tight_layout()
    display.figure_.savefig(graph_path, dpi=170)
    plt.close(display.figure_)
    report = {"model_type": "SVM with RBF kernel",
              "sources": {source: int((frame.source == source).sum()) for source in sorted(frame.source.unique())},
              "recordings": {source: int(frame[frame.source == source].recording.nunique()) for source in sorted(frame.source.unique())},
              "windows": int(len(frame)), "train_windows": int(len(train)), "test_windows": int(len(test)),
              "metrics": result,
              "limitations": ["KFall and local hardware/placement are different domains.",
                              "The local data is from P01 only, so this does not test unseen vest users.",
                              "This is exploratory and not a safety or deployment result."]}
    metrics_path.write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(f"Sources: {report['sources']}")
    print(f"Recordings: {report['recordings']} | windows: {report['windows']}")
    print(f"Holdout accuracy: {result['accuracy']:.3f} | fall recall: {result['fall_recall']:.3f} | specificity: {result['specificity']:.3f}")
    print(f"Model: {model_path}\nMetrics: {metrics_path}\nGraph: {graph_path}")


if __name__ == "__main__":
    main()
