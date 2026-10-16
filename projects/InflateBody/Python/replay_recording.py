"""Open an existing InflateBody CSV with the interactive sensor graph."""
import argparse
import csv
from pathlib import Path
import re

from live_sensor_graph import LiveSensorGraph


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    selection = parser.add_mutually_exclusive_group(required=True)
    selection.add_argument("--input", type=Path)
    selection.add_argument("--latest", action="store_true", help="Open the newest recording CSV")
    selection.add_argument("--choose", action="store_true", help="Choose a recording from a numbered list")
    parser.add_argument("--recordings-root", type=Path,
                        default=Path("Python/Data/recordings"))
    args = parser.parse_args()

    input_path = args.input
    if args.latest or args.choose:
        candidates = sorted(args.recordings_root.rglob("*.csv"), key=lambda path: path.stat().st_mtime)
        if not candidates:
            parser.error(f"No CSV recordings found under {args.recordings_root}")
        if args.latest:
            input_path = candidates[-1]
        else:
            grouped = {}
            for path in candidates:
                match = re.search(r"(?:^|_)T(\d+)(?:_|$)", path.name, re.IGNORECASE)
                if match:
                    grouped.setdefault(int(match.group(1)), []).append(path)
            choices = {}
            print("Available recordings (type: T01 1):")
            for task in sorted(grouped):
                for trial, path in enumerate(sorted(grouped[task]), 1):
                    key = f"T{task:02d} {trial}"
                    choices[key] = path
                    print(f"{key}: {path.relative_to(args.recordings_root)}")
            try:
                choice = input("Enter activity and try: ").strip().upper()
                normalized = re.fullmatch(r"T?(\d+)\s*[-_ ]\s*(\d+)", choice)
                if not normalized:
                    raise KeyError(choice)
                key = f"T{int(normalized.group(1)):02d} {int(normalized.group(2))}"
                input_path = choices[key]
            except (KeyError, ValueError, EOFError, IndexError):
                parser.error("Use a valid choice such as: T01 1")

    with input_path.open(newline="", encoding="utf-8") as source:
        rows = list(csv.DictReader(source))
    if not rows:
        parser.error("CSV contains no samples")

    def number(row, name):
        return float(row[name])

    times = [number(row, "elapsed_s") for row in rows]
    values = [[number(row, name) for name in ("ax", "ay", "az", "gx", "gy", "gz")]
              for row in rows]
    duration = max(times[-1], 1.0)
    first_timestamp = rows[0].get("timestamp_utc", "")
    label = rows[0].get("label", input_path.stem)
    placement = rows[0].get("placement", "unknown")
    graph = LiveSensorGraph(placement, label, True, window_seconds=duration + 1)
    graph.figure.canvas.manager.set_window_title("InflateBody | Saved recording replay")
    graph.figure.suptitle("SAVED RECORDING", fontsize=15, fontweight="bold", y=.97)
    graph.axes[-1].set_xlabel("Elapsed time (seconds from recording start)")
    graph.time_label.set_text(f"Source start: {first_timestamp}  |  Duration: {duration:.3f} s")
    for elapsed, sample in zip(times, values):
        graph.add_sample(elapsed, sample)
    graph.redraw()
    graph.status.set_text(f"SAVED RECORDING · {len(values)} samples · {duration:.3f} s")
    graph.figure.canvas.draw_idle()
    print(f"Opened: {input_path}")
    print("Move the mouse over a line to see sample details. Close the graph to finish.")
    graph.plt.show(block=True)
    graph.finish()


if __name__ == "__main__":
    main()
