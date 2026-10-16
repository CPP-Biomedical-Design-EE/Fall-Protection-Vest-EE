"""Train an exploratory SVM from the local labeled lower-back recordings."""
import json
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

from extract_recording_features import summarize, validate_feature_columns

WINDOW_SIZE = 40
WINDOW_STEP = 20
MAX_WINDOWS_PER_RECORDING = 3
MINIMUM_SAMPLES = 20
RANDOM_STATE = 42
BASE_DIR = Path(__file__).resolve().parent
DEFAULT_ROOT = BASE_DIR / "Data" / "recordings" / "P01"
MODEL_DIR = BASE_DIR / "Models"
GRAPH_DIR = BASE_DIR / "Graphs"
META = ["recording", "label", "is_fall", "window_number", "window_start", "window_end"]


def windows(sample_count):
    if sample_count < MINIMUM_SAMPLES:
        return []
    if sample_count <= WINDOW_SIZE:
        return [(0, sample_count)]
    starts = list(range(0, sample_count - WINDOW_SIZE + 1, WINDOW_STEP))
    final = sample_count - WINDOW_SIZE
    if starts[-1] != final:
        starts.append(final)
    return [(start, start + WINDOW_SIZE) for start in starts]


def choose_windows(items, acceleration, is_fall):
    if len(items) <= MAX_WINDOWS_PER_RECORDING:
        return items
    if is_fall:
        scored = [(np.linalg.norm(acceleration[start:end], axis=1).max(), start, end)
                  for start, end in items]
        return sorted((start, end) for _, start, end in sorted(scored, reverse=True)[:MAX_WINDOWS_PER_RECORDING])
    positions = np.linspace(0, len(items) - 1, MAX_WINDOWS_PER_RECORDING, dtype=int)
    return [items[index] for index in sorted(set(positions))]


def load_features(root):
    rows = []
    for path in sorted(root.rglob("*.csv")):
        label = path.parent.name
        if label.startswith("cal_") or not label.startswith(("adl_", "fall_")):
            continue
        frame = pd.read_csv(path)
        required = ["ax", "ay", "az", "gx", "gy", "gz"]
        if any(column not in frame.columns for column in required):
            continue
        acceleration = frame[["ax", "ay", "az"]].to_numpy(float)
        gyro = frame[["gx", "gy", "gz"]].to_numpy(float)
        count = min(len(acceleration), len(gyro))
        is_fall = label.startswith("fall_")
        for number, (start, end) in enumerate(
                choose_windows(windows(count), acceleration, is_fall), start=1):
            row = {
                "recording": str(path), "label": label, "is_fall": int(is_fall),
                "window_number": number, "window_start": start, "window_end": end,
            }
            row.update(summarize(acceleration[start:end], "acc"))
            row.update(summarize(gyro[start:end], "gyro"))
            rows.append(row)
    frame = pd.DataFrame(rows)
    if frame.empty:
        raise ValueError(f"No labeled activity/fall CSV files found under {root}")
    feature_columns = [column for column in frame.columns if column not in META]
    validate_feature_columns(feature_columns)
    return frame, feature_columns


def metrics(y_true, prediction):
    matrix = confusion_matrix(y_true, prediction, labels=[0, 1])
    tn, fp, fn, tp = matrix.ravel()
    return {
        "accuracy": float((tn + tp) / matrix.sum()),
        "precision": float(tp / (tp + fp)) if tp + fp else 0.0,
        "fall_recall": float(tp / (tp + fn)) if tp + fn else 0.0,
        "specificity": float(tn / (tn + fp)) if tn + fp else 0.0,
        "f1": float(2 * tp / (2 * tp + fp + fn)) if 2 * tp + fp + fn else 0.0,
        "true_negative": int(tn), "false_positive": int(fp),
        "false_negative": int(fn), "true_positive": int(tp),
    }


def main():
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--recordings-root", type=Path, default=DEFAULT_ROOT)
    args = parser.parse_args()
    frame, feature_columns = load_features(args.recordings_root)
    x, y, groups = frame[feature_columns], frame["is_fall"], frame["recording"]
    split = None
    for seed in range(RANDOM_STATE, RANDOM_STATE + 50):
        candidate = GroupShuffleSplit(n_splits=1, test_size=.25, random_state=seed)
        train, test = next(candidate.split(x, y, groups))
        if y.iloc[train].nunique() == 2 and y.iloc[test].nunique() == 2:
            split = train, test
            break
    if split is None:
        raise ValueError("Could not create a grouped train/test split containing both classes")
    train, test = split
    model = Pipeline([("scale", StandardScaler()),
                      ("svm", SVC(kernel="rbf", C=2.0, gamma="scale",
                                  class_weight="balanced", probability=True,
                                  random_state=RANDOM_STATE))])
    model.fit(x.iloc[train], y.iloc[train])
    prediction = model.predict(x.iloc[test])
    probability = model.predict_proba(x.iloc[test])[:, 1]
    result = metrics(y.iloc[test], prediction)
    MODEL_DIR.mkdir(exist_ok=True)
    GRAPH_DIR.mkdir(exist_ok=True)
    model_path = MODEL_DIR / "local_lower_back_fall_detector.joblib"
    metrics_path = MODEL_DIR / "local_lower_back_fall_detector_metrics.json"
    prediction_path = MODEL_DIR / "local_lower_back_fall_detector_test_predictions.csv"
    graph_path = GRAPH_DIR / "local_lower_back_fall_detector_confusion_matrix.png"
    joblib.dump({"pipeline": model, "feature_columns": feature_columns,
                 "window_samples": WINDOW_SIZE, "step_samples": WINDOW_STEP,
                 "source": "P01 local lower-back recordings", "validated_for_hardware": False}, model_path)
    output = frame.iloc[test][META].copy()
    output["predicted_is_fall"] = prediction
    output["fall_probability"] = probability
    output.to_csv(prediction_path, index=False)
    matrix = confusion_matrix(y.iloc[test], prediction, labels=[0, 1])
    display = ConfusionMatrixDisplay(matrix, display_labels=["ADL", "Fall"])
    display.plot(cmap="Blues", colorbar=False)
    display.ax_.set_title("Local P01 Lower-Back Model — Recording Holdout")
    display.figure_.tight_layout()
    display.figure_.savefig(graph_path, dpi=170)
    plt.close(display.figure_)
    report = {
        "model_type": "SVM with RBF kernel",
        "source": "P01 local lower-back recordings",
        "recordings": int(frame["recording"].nunique()),
        "windows": int(len(frame)),
        "train_recordings": int(frame.iloc[train]["recording"].nunique()),
        "test_recordings": int(frame.iloc[test]["recording"].nunique()),
        "train_windows": int(len(train)), "test_windows": int(len(test)),
        "metrics": result,
        "limitations": [
            "Train/test groups are recordings from one participant (P01), not unseen participants.",
            "This is an exploratory baseline, not validated fall accuracy or safety performance.",
            "The model must be retrained after more labeled subjects and activities are collected.",
        ],
    }
    metrics_path.write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(f"Recordings: {report['recordings']} | windows: {report['windows']}")
    print(f"Holdout accuracy: {result['accuracy']:.3f} | fall recall: {result['fall_recall']:.3f} | specificity: {result['specificity']:.3f}")
    print(f"Model: {model_path}")
    print(f"Metrics: {metrics_path}")
    print(f"Graph: {graph_path}")


if __name__ == "__main__":
    main()
