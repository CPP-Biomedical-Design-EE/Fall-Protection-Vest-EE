"""Train the SVM used by the live rolling-window detector."""

import json
from pathlib import Path

import joblib
import matplotlib

matplotlib.use("Agg")

import matplotlib.pyplot as plt
import pandas as pd
from sklearn.metrics import ConfusionMatrixDisplay, confusion_matrix
from sklearn.model_selection import GroupShuffleSplit, StratifiedGroupKFold, cross_validate
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import StandardScaler
from sklearn.svm import SVC
from extract_recording_features import validate_feature_columns


BASE_DIR = Path(__file__).resolve().parent
FEATURE_FILE = BASE_DIR / "Data" / "processed" / "window_features.csv"
MODEL_DIR = BASE_DIR / "Models"
GRAPH_DIR = BASE_DIR / "Graphs"
RANDOM_STATE = 42
METADATA_COLUMNS = [
    "recording",
    "user",
    "label",
    "is_fall",
    "window_number",
    "window_start",
    "window_end",
    "window_samples",
]


def create_model() -> Pipeline:
    return Pipeline(
        [
            ("scale", StandardScaler()),
            (
                "svm",
                SVC(
                    kernel="rbf",
                    C=2.0,
                    gamma="scale",
                    class_weight="balanced",
                    probability=True,
                    random_state=RANDOM_STATE,
                ),
            ),
        ]
    )


def score_values(y_true: pd.Series, y_pred: pd.Series) -> dict:
    matrix = confusion_matrix(y_true, y_pred, labels=[0, 1])
    tn, fp, fn, tp = matrix.ravel()
    return {
        "accuracy": float((tp + tn) / matrix.sum()),
        "precision": float(tp / (tp + fp)) if tp + fp else 0.0,
        "recall_sensitivity": float(tp / (tp + fn)) if tp + fn else 0.0,
        "specificity": float(tn / (tn + fp)) if tn + fp else 0.0,
        "f1": float(2 * tp / (2 * tp + fp + fn)) if 2 * tp + fp + fn else 0.0,
        "true_negative": int(tn),
        "false_positive": int(fp),
        "false_negative": int(fn),
        "true_positive": int(tp),
    }


def main() -> None:
    if not FEATURE_FILE.exists():
        raise SystemExit("Run: python Python/extract_window_features.py")

    frame = pd.read_csv(FEATURE_FILE)
    feature_columns = [column for column in frame.columns if column not in METADATA_COLUMNS]
    validate_feature_columns(feature_columns)
    x = frame[feature_columns]
    y = frame["is_fall"]
    groups = frame["user"]

    split = GroupShuffleSplit(n_splits=1, test_size=0.22, random_state=RANDOM_STATE)
    train_indices, test_indices = next(split.split(x, y, groups))
    model = create_model()
    model.fit(x.iloc[train_indices], y.iloc[train_indices])
    predictions = model.predict(x.iloc[test_indices])
    probabilities = model.predict_proba(x.iloc[test_indices])[:, 1]
    holdout_metrics = score_values(y.iloc[test_indices], predictions)

    grouped_cv = StratifiedGroupKFold(n_splits=5, shuffle=True, random_state=RANDOM_STATE)
    cv = cross_validate(
        create_model(),
        x,
        y,
        groups=groups,
        cv=grouped_cv,
        scoring={"accuracy": "accuracy", "precision": "precision", "recall": "recall", "f1": "f1"},
        n_jobs=-1,
    )

    test_users = sorted(groups.iloc[test_indices].unique())
    metrics = {
        "model_type": "SVM with RBF kernel",
        "evaluation_unit": "40-sample rolling window; short recordings use 20-39 samples",
        "source_sensors": (
            "Public-data acceleration including gravity (m/s^2) and gyroscope (rad/s); not live MPU6050 validation"
        ),
        "split_method": "grouped by user",
        "windows": int(len(frame)),
        "recordings": int(frame["recording"].nunique()),
        "features": int(len(feature_columns)),
        "test_users": test_users,
        "training_windows": int(len(train_indices)),
        "test_windows": int(len(test_indices)),
        "holdout_metrics": holdout_metrics,
        "five_fold_grouped_cv": {
            metric: {
                "mean": float(cv[f"test_{metric}"].mean()),
                "std": float(cv[f"test_{metric}"].std()),
            }
            for metric in ("accuracy", "precision", "recall", "f1")
        },
        "live_defaults": {
            "window_samples": 40,
            "step_samples": 20,
            "fall_probability_threshold": 0.70,
            "consecutive_fall_windows": 2,
        },
        "limitations": [
            "Every selected window inherits its recording label, so boundary windows may be noisy.",
            "Fall windows are selected around the strongest acceleration, which can make this public-data estimate optimistic.",
            "The public dataset hardware and placement differ from the vest prototype.",
            "Live detection requires calibration and physical vest testing before safety use.",
        ],
    }

    MODEL_DIR.mkdir(parents=True, exist_ok=True)
    GRAPH_DIR.mkdir(parents=True, exist_ok=True)
    model_path = MODEL_DIR / "fall_detector_svm_window.joblib"
    metrics_path = MODEL_DIR / "fall_detector_svm_window_metrics.json"
    predictions_path = MODEL_DIR / "fall_detector_svm_window_test_predictions.csv"
    graph_path = GRAPH_DIR / "fall_detector_svm_window_confusion_matrix.png"

    joblib.dump(
        {
            "pipeline": model,
            "feature_columns": feature_columns,
            "positive_label": "fall",
            "window_samples": 40,
            "step_samples": 20,
            "training_acceleration_unit": "m/s^2",
            "training_gyroscope_unit": "rad/s",
            "source_placement": "unverified_public_source",
            "waist_validated": False,
        },
        model_path,
    )
    metrics_path.write_text(json.dumps(metrics, indent=2), encoding="utf-8")

    output = frame.iloc[test_indices][METADATA_COLUMNS].copy()
    output["predicted_is_fall"] = predictions
    output["fall_probability"] = probabilities
    output.to_csv(predictions_path, index=False)

    matrix = confusion_matrix(y.iloc[test_indices], predictions, labels=[0, 1])
    display = ConfusionMatrixDisplay(matrix, display_labels=["ADL", "Fall"])
    display.plot(cmap="Blues", colorbar=False)
    display.ax_.set_title("Rolling-Window SVM — Unseen Users")
    display.figure_.tight_layout()
    display.figure_.savefig(graph_path, dpi=170)
    plt.close(display.figure_)

    performance_path = GRAPH_DIR / "fall_model_performance.png"
    metric_names = ["Accuracy", "Fall recall", "Specificity", "Precision", "F1"]
    metric_values = [
        holdout_metrics["accuracy"],
        holdout_metrics["recall_sensitivity"],
        holdout_metrics["specificity"],
        holdout_metrics["precision"],
        holdout_metrics["f1"],
    ]
    figure, axes = plt.subplots(1, 2, figsize=(12, 4.8))
    bars = axes[0].bar(metric_names, metric_values, color=["#4C78A8", "#E45756", "#72B7B2", "#F2CF5B", "#B279A2"])
    axes[0].set_ylim(0, 1.05)
    axes[0].set_ylabel("Score")
    axes[0].set_title("6-Axis Public-Data Model — Unseen Users")
    axes[0].tick_params(axis="x", rotation=25)
    for bar, value in zip(bars, metric_values):
        axes[0].text(bar.get_x() + bar.get_width() / 2, value + 0.02, f"{value:.1%}", ha="center")

    matrix_image = axes[1].imshow(matrix, cmap="Blues")
    axes[1].set_xticks([0, 1], labels=["ADL", "Fall"])
    axes[1].set_yticks([0, 1], labels=["ADL", "Fall"])
    axes[1].set_xlabel("Predicted")
    axes[1].set_ylabel("Actual")
    axes[1].set_title("Confusion Matrix (Windows)")
    for row in range(2):
        for column in range(2):
            text_color = "white" if matrix[row, column] > matrix.max() / 2 else "black"
            axes[1].text(column, row, str(matrix[row, column]), ha="center", va="center", color=text_color)
    figure.colorbar(matrix_image, ax=axes[1], fraction=0.046, pad=0.04)
    figure.tight_layout()
    figure.savefig(performance_path, dpi=180)
    plt.close(figure)

    cv_f1 = metrics["five_fold_grouped_cv"]["f1"]
    print(f"Test users: {', '.join(test_users)}")
    print(f"Holdout accuracy: {holdout_metrics['accuracy']:.3f}")
    print(f"Holdout fall recall: {holdout_metrics['recall_sensitivity']:.3f}")
    print(f"Holdout specificity: {holdout_metrics['specificity']:.3f}")
    print(f"Holdout F1: {holdout_metrics['f1']:.3f}")
    print(f"Grouped 5-fold F1: {cv_f1['mean']:.3f} +/- {cv_f1['std']:.3f}")
    print(f"Model: {model_path}")
    print(f"Performance graph: {performance_path}")


if __name__ == "__main__":
    main()
