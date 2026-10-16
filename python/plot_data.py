"""Create six-axis public-data ADL-versus-fall sensor trend graphs."""

from pathlib import Path

import matplotlib

matplotlib.use("Agg")

import matplotlib.pyplot as plt
import numpy as np

from six_axis_data import DEFAULT_DATASET_DIR, iter_recordings, read_sensor_vectors, recording_metadata


BASE_DIR = Path(__file__).resolve().parent
GRAPH_DIR = BASE_DIR / "Graphs"


def main() -> None:
    recordings = list(iter_recordings(DEFAULT_DATASET_DIR))
    if not recordings:
        raise SystemExit(f"No recordings found in {DEFAULT_DATASET_DIR}")

    fall_candidates = []
    for path in recordings:
        metadata = recording_metadata(path, DEFAULT_DATASET_DIR)
        if not metadata["is_fall"]:
            continue
        vectors, _ = read_sensor_vectors(path)
        if len(vectors["acg"]):
            fall_candidates.append((float(np.linalg.norm(vectors["acg"], axis=1).max()), path))
    fall_candidates.sort(key=lambda item: item[0])
    fall_path = fall_candidates[len(fall_candidates) // 2][1]
    fall_meta = recording_metadata(fall_path, DEFAULT_DATASET_DIR)
    same_user_adl = [
        path for path in recordings
        if recording_metadata(path, DEFAULT_DATASET_DIR)["user"] == fall_meta["user"]
        and not recording_metadata(path, DEFAULT_DATASET_DIR)["is_fall"]
    ]
    adl_path = same_user_adl[len(same_user_adl) // 2]
    examples = [("Normal activity (ADL)", adl_path), ("Fall", fall_path)]

    GRAPH_DIR.mkdir(parents=True, exist_ok=True)
    figure, axes = plt.subplots(2, 2, figsize=(14, 7), sharex="col")
    sensor_rows = [
        ("acg", "Acceleration including gravity (m/s²)", ("Ax", "Ay", "Az")),
        ("gyro", "Gyroscope (rad/s)", ("Gx", "Gy", "Gz")),
    ]
    colors = ("#4C78A8", "#E45756", "#54A24B")
    selected_names = []
    for column, (activity, path) in enumerate(examples):
        vectors, _ = read_sensor_vectors(path)
        count = min(len(vectors["acg"]), len(vectors["gyro"]))
        impact_sample = int(np.linalg.norm(vectors["acg"][:count], axis=1).argmax())
        selected_names.append(path.relative_to(DEFAULT_DATASET_DIR).as_posix())
        for row, (sensor, ylabel, labels) in enumerate(sensor_rows):
            axis = axes[row, column]
            values = vectors[sensor][:count]
            for component, label, color in zip(range(3), labels, colors):
                axis.plot(values[:, component], label=label, color=color, linewidth=1.0, alpha=0.9)
            if column == 1:
                axis.axvline(impact_sample, color="black", linestyle="--", linewidth=1.2, label="Peak impact" if row == 0 else None)
            axis.set_ylabel(ylabel)
            axis.grid(alpha=0.2)
            if row == 0:
                axis.set_title(activity)
            if row == 1:
                axis.set_xlabel("Paired sample number")
            axis.legend(loc="upper right", ncol=2, fontsize=8)

    figure.suptitle("6-Axis Public-Data Trends: Normal Activity vs Fall", fontsize=15)
    figure.text(0.5, 0.015, f"Examples: {selected_names[0]}  |  {selected_names[1]}", ha="center", fontsize=8)
    figure.tight_layout(rect=(0, 0.035, 1, 0.96))
    trend_path = GRAPH_DIR / "six_axis_fall_vs_adl_trends.png"
    figure.savefig(trend_path, dpi=180)
    plt.close(figure)

    print(f"Created: {trend_path}")
    print(f"ADL example: {selected_names[0]}")
    print(f"Fall example: {selected_names[1]}")


if __name__ == "__main__":
    main()
