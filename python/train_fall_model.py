"""Train and evaluate the first recording-level fall-detection SVM."""

import json
from pathlib import Path

import joblib
import matplotlib

matplotlib.use("Agg")

import matplotlib.pyplot as plt
import pandas as pd
from sklearn.metrics import (
    ConfusionMatrixDisplay,
    accuracy_score,
    confusion_matrix,
    f1_score,
    precision_score,
    recall_score,
)
from sklearn.model_selection import GroupShuffleSplit, StratifiedGroupKFold, cross_validate
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import StandardScaler
from sklearn.svm import SVC
from extract_recording_features import validate_feature_columns


BASE_DIR = Path(__file__).resolve().parent
FEATURE_FILE = BASE_DIR / "Data" / "processed" / "recording_features.csv"
MODEL_DIR = BASE_DIR / "Models"
GRAPH_DIR = BASE_DIR / "Graphs"
RANDOM_STATE = 42


def make_model() -> Pipeline:
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


def main() -> None:
    if not FEATURE_FILE.exists():
        raise SystemExit(
            "Feature table not found. Run: python Python/extract_recording_features.py"
        )

    frame = pd.read_csv(FEATURE_FILE)
    metadata_columns = ["recording", "user", "label", "is_fall"]
    feature_columns = [column for column in frame.columns if column not in metadata_columns]
    validate_feature_columns(feature_columns)
    x = frame[feature_columns]
    y = frame["is_fall"]
    groups = frame["user"]

    splitter = GroupShuffleSplit(n_splits=1, test_size=0.22, random_state=RANDOM_STATE)
    train_indices, test_indices = next(splitter.split(x, y, groups))
    x_train, x_test = x.iloc[train_indices], x.iloc[test_indices]
    y_train, y_test = y.iloc[train_indices], y.iloc[test_indices]
    train_users = sorted(groups.iloc[train_indices].unique())
    test_users = sorted(groups.iloc[test_indices].unique())

    model = make_model()
    model.fit(x_train, y_train)
    predictions = model.predict(x_test)
    probabilities = model.predict_proba(x_test)[:, 1]

    matrix = confusion_matrix(y_test, predictions, labels=[0, 1])
    true_negative, false_positive, false_negative, true_positive = matrix.ravel()
    specificity = true_negative / (true_negative + false_positive)

    cross_validation = StratifiedGroupKFold(
        n_splits=5, shuffle=True, random_state=RANDOM_STATE
    )
    cv_results = cross_validate(
        make_model(),
        x,
        y,
        groups=groups,
        cv=cross_validation,
        scoring={
            "accuracy": "accuracy",
            "precision": "precision",
            "recall": "recall",
            "f1": "f1",
        },
        n_jobs=-1,
    )

    metrics = {
        "model_type": "SVM with RBF kernel",
        "source_sensors": "6-axis MPU6050 acceleration and gyroscope",
        "evaluation_unit": "one complete recording",
        "split_method": "grouped by user; test users are absent from training",
        "recordings": int(len(frame)),
        "features": int(len(feature_columns)),
        "training_recordings": int(len(train_indices)),
        "test_recordings": int(len(test_indices)),
        "training_users": train_users,
        "test_users": test_users,
        "test_class_counts": {
            "adl": int((y_test == 0).sum()),
            "fall": int((y_test == 1).sum()),
        },
        "holdout_metrics": {
            "accuracy": float(accuracy_score(y_test, predictions)),
            "precision": float(precision_score(y_test, predictions, zero_division=0)),
            "recall_sensitivity": float(recall_score(y_test, predictions, zero_division=0)),
            "specificity": float(specificity),
            "f1": float(f1_score(y_test, predictions, zero_division=0)),
            "true_negative": int(true_negative),
            "false_positive": int(false_positive),
            "false_negative": int(false_negative),
            "true_positive": int(true_positive),
        },
        "five_fold_grouped_cv": {
            metric: {
                "mean": float(cv_results[f"test_{metric}"].mean()),
                "std": float(cv_results[f"test_{metric}"].std()),
            }
            for metric in ("accuracy", "precision", "recall", "f1")
        },
        "limitations": [
            "This baseline classifies a complete recording, not a live rolling window.",
            "The source sensor placement and hardware differ from the vest prototype.",
            "Public simulated falls do not replace physical testing with vest-mounted data.",
        ],
    }

    MODEL_DIR.mkdir(parents=True, exist_ok=True)
    GRAPH_DIR.mkdir(parents=True, exist_ok=True)
    model_path = MODEL_DIR / "fall_detector_svm_recording.joblib"
    metrics_path = MODEL_DIR / "fall_detector_svm_metrics.json"
    predictions_path = MODEL_DIR / "fall_detector_svm_test_predictions.csv"
    graph_path = GRAPH_DIR / "fall_detector_svm_confusion_matrix.png"

    joblib.dump(
        {
            "pipeline": model,
            "feature_columns": feature_columns,
            "positive_label": "fall",
            "evaluation_unit": "complete recording",
        },
        model_path,
    )
    metrics_path.write_text(json.dumps(metrics, indent=2), encoding="utf-8")

    test_output = frame.iloc[test_indices][metadata_columns].copy()
    test_output["predicted_is_fall"] = predictions
    test_output["fall_probability"] = probabilities
    test_output.to_csv(predictions_path, index=False)

    display = ConfusionMatrixDisplay(
        confusion_matrix=matrix, display_labels=["ADL", "Fall"]
    )
    display.plot(cmap="Blues", colorbar=False)
    display.ax_.set_title("SVM Test Results — Unseen Users")
    display.figure_.tight_layout()
    display.figure_.savefig(graph_path, dpi=170)
    plt.close(display.figure_)

    holdout = metrics["holdout_metrics"]
    cv = metrics["five_fold_grouped_cv"]
    print(f"Test users: {', '.join(test_users)}")
    print(f"Holdout accuracy: {holdout['accuracy']:.3f}")
    print(f"Holdout fall recall: {holdout['recall_sensitivity']:.3f}")
    print(f"Holdout specificity: {holdout['specificity']:.3f}")
    print(f"Holdout F1: {holdout['f1']:.3f}")
    print(f"Grouped 5-fold F1: {cv['f1']['mean']:.3f} +/- {cv['f1']['std']:.3f}")
    print(f"Model: {model_path}")
    print(f"Metrics: {metrics_path}")


if __name__ == "__main__":
    main()
