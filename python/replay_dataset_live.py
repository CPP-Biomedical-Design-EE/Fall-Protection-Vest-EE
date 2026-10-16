"""Play a saved KFall or UNIVRFall recording as a live-style graph."""
import argparse
import math
import re
import sys
import time
from pathlib import Path

import numpy as np

from analyze_kfall import read_sensor_csv
from live_sensor_graph import LiveSensorGraph, GRAVITY


SAMPLE_RATE_HZ = 100.0
RECORDING_RE = re.compile(r"S\d+T(?P<task>\d+)R\d+\.csv", re.IGNORECASE)


def default_dataset_root(dataset):
    collection = Path(__file__).resolve().parents[2] / "Data Collection"
    return collection / {"kfall": "sensor_data_new_2", "univrfall": "UniVrFall_Dataset"}[dataset]


def available_recordings(dataset, root):
    """Index only sensor recordings; never pick a label or generated CSV."""
    root = Path(root).expanduser()
    if not root.is_dir():
        raise ValueError(f"Dataset folder not found: {root}. Set --dataset-root to its location.")
    sensor_root = root if dataset == "kfall" else root / "laboratory" / "sensors_data"
    recordings = {}
    for path in sorted(sensor_root.glob("SA*/S*T*R*.csv")):
        match = RECORDING_RE.fullmatch(path.name)
        if match and path.is_file():
            recordings.setdefault(int(match.group("task")), []).append(path)
    if dataset == "univrfall":
        field = sorted(path for path in (root / "OnField").glob("*/*.csv") if path.is_file())
        if field:
            recordings[88] = field
    return recordings


def resolve_recording(dataset, root, task=None, member=None):
    root = Path(root).expanduser()
    if member is not None:
        path = root / member
        if not path.is_file():
            raise ValueError(f"Recording not found: {path}. Use --task 20 to select an existing recording automatically.")
        return path
    maximum = 36 if dataset == "kfall" else 44
    if task is None or not (1 <= task <= maximum or (dataset == "univrfall" and task == 88)):
        extra = " or 88 (on-field)" if dataset == "univrfall" else ""
        raise ValueError(f"For {dataset}, --task must be 1–{maximum}{extra}.")
    candidates = available_recordings(dataset, root).get(task, [])
    if not candidates:
        raise ValueError(f"No recording for task {task} in {root}. Use --list-tasks to see available tasks.")
    # Choose an actual file, including when the first available trial is not R01.
    return candidates[0]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset", choices=("kfall", "univrfall"), required=True)
    parser.add_argument("--dataset-root", type=Path, help="Defaults to the project's adjacent Data Collection folder")
    selection = parser.add_mutually_exclusive_group(required=True)
    selection.add_argument("--member", help="Exact CSV path relative to --dataset-root")
    selection.add_argument("--task", type=int, help="Activity number; selects the first available participant/trial")
    selection.add_argument("--list-tasks", action="store_true", help="List available task numbers and example recordings")
    parser.add_argument("--check-only", action="store_true", help="Verify the selected file without opening a graph")
    parser.add_argument("--speed", type=float, default=1.0, help="Playback multiplier; 1 uses nominal 100 Hz timing")
    parser.add_argument("--print-every", type=int, default=10, help="Print every Nth sample")
    args = parser.parse_args(argv)
    if not math.isfinite(args.speed) or args.speed <= 0 or args.print_every <= 0:
        parser.error("--speed must be finite and positive; --print-every must be positive")

    root = (args.dataset_root or default_dataset_root(args.dataset)).expanduser()
    try:
        if args.list_tasks:
            recordings = available_recordings(args.dataset, root)
            if not recordings:
                raise ValueError(f"No sensor recordings found in {root}.")
            print("task,recordings,example_file")
            for task, paths in sorted(recordings.items()):
                print(f"{task},{len(paths)},{paths[0].relative_to(root)}")
            return
        path = resolve_recording(args.dataset, root, args.task, args.member)
        values = read_sensor_csv(path, args.dataset)
        raw = values[["ax", "ay", "az", "gx", "gy", "gz"]].to_numpy(float)
        if not len(raw) or not np.isfinite(raw).all():
            raise ValueError(f"No usable finite six-axis recording in {path}.")
    except (OSError, ValueError, KeyError) as error:
        parser.error(str(error))
    if "timestamp_s" in values.columns:
        source_time = values["timestamp_s"].to_numpy(float)
        source_elapsed = source_time - source_time[0]
        time_description = "source timestamps"
    else:
        source_elapsed = np.arange(len(raw), dtype=float) / SAMPLE_RATE_HZ
        time_description = "nominal 100 Hz spacing; source timestamps unavailable"
    print(f"Recording: {path}\nSamples: {len(raw)} | source duration: {source_elapsed[-1]:.3f} s | {time_description}",
          file=sys.stderr, flush=True)
    if args.check_only:
        return
    # The shared graph expects SI units, while both analyzed datasets are
    # represented here as g and deg/s after their dataset-specific scaling.
    si_values = raw.copy()
    si_values[:, :3] *= GRAVITY
    si_values[:, 3:] = np.deg2rad(si_values[:, 3:])
    sample_rate = SAMPLE_RATE_HZ
    try:
        graph = LiveSensorGraph("lower_back", f"{args.dataset} replay · {path.name}", True)
    except RuntimeError as error:
        parser.error(str(error))
    graph.figure.canvas.manager.set_window_title(f"InflateBody | {args.dataset.upper()} dataset replay")
    graph.figure.suptitle(f"{args.dataset.upper()} · LIVE-STYLE REPLAY (not ESP32)", fontsize=15, fontweight="bold", y=.97)
    graph.axes[-1].set_xlabel("Source elapsed time (seconds from recording start)")
    graph.time_label.set_text(
        f"Source time: {source_elapsed[0]:.3f}–{source_elapsed[-1]:.3f} s"
        f"  |  Playback: nominal {SAMPLE_RATE_HZ:g} Hz"
    )
    started = time.monotonic()
    cursor = 0
    print("sample,source_time_s,ax_g,ay_g,az_g,gx_dps,gy_dps,gz_dps", flush=True)
    try:
        while cursor < len(si_values) and graph.poll():
            end = min(len(si_values), int((time.monotonic() - started) * args.speed * sample_rate) + 1)
            while cursor < end:
                graph.add_sample(float(source_elapsed[cursor]), si_values[cursor])
                if cursor % args.print_every == 0:
                    row = raw[cursor]
                    print(f"{cursor},{source_elapsed[cursor]:.2f}," + ",".join(f"{x:.5f}" for x in row), flush=True)
                cursor += 1
            time.sleep(.01)
        if not graph.closed:
            graph.redraw()
            graph.status.set_text("REPLAY COMPLETE · close this window to finish")
            graph.figure.canvas.draw_idle()
            graph.plt.show(block=True)
    except KeyboardInterrupt:
        print("Replay stopped.")
    finally:
        graph.finish()


if __name__ == "__main__":
    main()
