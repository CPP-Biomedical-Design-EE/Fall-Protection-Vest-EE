"""Evaluate literature and public-dataset-tuned threshold profiles by user."""

import json
from pathlib import Path
from typing import Dict, List, Set, Tuple

from six_axis_data import DEFAULT_DATASET_DIR, iter_recordings, read_sensor_vectors, recording_metadata
from threshold_detection import ThresholdFallDetector, Thresholds


OUTPUT = Path(__file__).resolve().parent / "Models" / "threshold_detector_metrics.json"
TEST_USERS: Set[str] = {
    "user8",
    "user9",
    "user13",
    "user15",
    "user17",
    "user21",
    "user27",
    "user31",
    "user32",
    "user36",
}

PROFILES = {
    "literature_starting_values": {
        "thresholds": Thresholds(0.9, 47.3, 24.7),
        "evidence_seconds": 1.0,
        "selection": "Values listed in the supplied project brief",
    },
    "public_dataset_tuned": {
        "thresholds": Thresholds(0.9, 250.0, 90.0),
        "evidence_seconds": 0.6,
        "selection": "Best balanced accuracy in a small grid search using training users only",
    },
}


def load_records(source: Path) -> Tuple[List[Tuple], int]:
    records = []
    skipped = 0
    for path in iter_recordings(source):
        metadata = recording_metadata(path, source)
        vectors, _ = read_sensor_vectors(path)
        count = min(len(vectors["acg"]), len(vectors["gyro"]))
        if count <= 50:
            skipped += 1
            continue
        records.append(
            (
                metadata["user"],
                bool(metadata["is_fall"]),
                vectors["acg"][:count],
                vectors["gyro"][:count],
            )
        )
    return records, skipped


def evaluate(records: List[Tuple], thresholds: Thresholds, evidence_seconds: float) -> Dict:
    true_negative = false_positive = false_negative = true_positive = 0
    for _, true_fall, acceleration, gyroscope in records:
        detector = ThresholdFallDetector(
            sample_rate_hz=50,
            calibration_samples=50,
            evidence_seconds=evidence_seconds,
            cooldown_seconds=2,
            thresholds=thresholds,
        )
        predicted_fall = False
        for index in range(len(acceleration)):
            if detector.update(acceleration[index], gyroscope[index])["fall_detected"]:
                predicted_fall = True
                break

        if true_fall and predicted_fall:
            true_positive += 1
        elif true_fall:
            false_negative += 1
        elif predicted_fall:
            false_positive += 1
        else:
            true_negative += 1

    recall = true_positive / (true_positive + false_negative)
    specificity = true_negative / (true_negative + false_positive)
    precision = true_positive / (true_positive + false_positive)
    return {
        "recordings": len(records),
        "true_negative": true_negative,
        "false_positive": false_positive,
        "false_negative": false_negative,
        "true_positive": true_positive,
        "accuracy": (true_positive + true_negative) / len(records),
        "precision": precision,
        "recall_sensitivity": recall,
        "specificity": specificity,
        "balanced_accuracy": (recall + specificity) / 2,
        "f1": 2 * precision * recall / (precision + recall),
    }


def main() -> None:
    records, skipped = load_records(DEFAULT_DATASET_DIR)
    training_records = [record for record in records if record[0] not in TEST_USERS]
    test_records = [record for record in records if record[0] in TEST_USERS]

    report = {
        "source": str(DEFAULT_DATASET_DIR),
        "evaluation": "recording level with 10 held-out users",
        "test_users": sorted(TEST_USERS),
        "usable_recordings": len(records),
        "skipped_recordings_with_50_or_fewer_paired_samples": skipped,
        "profiles": {},
        "boundary": (
            "These results use public data with different hardware and placement. "
            "They do not validate thresholds for the physical vest."
        ),
    }

    for name, profile in PROFILES.items():
        thresholds = profile["thresholds"]
        report["profiles"][name] = {
            "parameters": {
                "low_acceleration_g": thresholds.low_acceleration_g,
                "high_rotation_dps": thresholds.high_rotation_dps,
                "tilt_degrees": thresholds.tilt_degrees,
                "evidence_seconds": profile["evidence_seconds"],
            },
            "selection": profile["selection"],
            "training_users_result": evaluate(
                training_records, thresholds, profile["evidence_seconds"]
            ),
            "held_out_users_result": evaluate(
                test_records, thresholds, profile["evidence_seconds"]
            ),
        }

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(json.dumps(report, indent=2), encoding="utf-8")

    for name, profile in report["profiles"].items():
        result = profile["held_out_users_result"]
        print(name)
        print(f"  recall: {result['recall_sensitivity']:.3f}")
        print(f"  specificity: {result['specificity']:.3f}")
        print(f"  balanced accuracy: {result['balanced_accuracy']:.3f}")
    print(f"Report: {OUTPUT}")


if __name__ == "__main__":
    main()
