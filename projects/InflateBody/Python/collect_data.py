import argparse
import csv
import math
import re
import time
from datetime import datetime, timezone
from pathlib import Path

import serial
from serial.tools import list_ports
from serial_samples import SerialSampleParser, parse_csv_values
from esp32_serial import open_esp32
from stream_health import HundredHzGuard, StreamHealth, positive_seconds
from live_sensor_graph import euler_angles


BAUD_RATE = 115200
FIELD_NAMES = ("ax", "ay", "az", "gx", "gy", "gz")
DEFAULT_DATA_DIR = Path(__file__).resolve().parent / "Data" / "recordings"
CSV_FIELDS = ("timestamp_utc", "elapsed_s", "label", "placement", "subject_id", *FIELD_NAMES,
              "acceleration_unit", "gyroscope_unit", "input_format", "device_time_us",
              "sequence", "device_elapsed_s", "sample_interval_s", "stream_discontinuity",
              "euler_x_deg", "euler_y_deg", "euler_z_deg")


def activity_label(value):
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,63}", value):
        raise argparse.ArgumentTypeError("Use 1-64 letters, numbers, underscores or hyphens for the label.")
    return value


def parse_six_axis_line(line):
    return parse_csv_values(line)


def find_esp32_port():
    """Return the most likely ESP32 USB-to-UART port, if connected."""
    ports = list(list_ports.comports())
    keywords = (
        "esp32",
        "cp210",
        "silicon labs",
        "ch340",
        "wch",
        "usbserial",
        "usbmodem",
    )

    for port in ports:
        details = f"{port.device} {port.description} {port.manufacturer or ''}".lower()
        if any(keyword in details for keyword in keywords):
            return port.device

    return None


def main():
    parser = argparse.ArgumentParser(description="Record six-axis ESP32 data in m/s^2 and rad/s to CSV.")
    parser.add_argument("--label", type=activity_label, default="unlabeled",
                        help="Activity for this entire recording, e.g. standing or walking.")
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_DATA_DIR)
    parser.add_argument("--preview", action="store_true", help="Display readings without saving a file.")
    parser.add_argument("--graph", action="store_true", help="Show a live graph; combine with --preview to avoid saving.")
    parser.add_argument("--graph-seconds", type=positive_seconds, default=20.0,
                        help="Seconds visible in the rolling live graph (default: 20).")
    parser.add_argument("--placement", choices=("lower_back_center_waist", "wrist", "bench", "unknown"),
                        default="lower_back_center_waist", help="Actual physical sensor location; does not transform data.")
    parser.add_argument("--subject-id", type=activity_label, default="unknown",
                        help="Anonymous participant ID; keep the same ID across that person's sessions.")
    parser.add_argument("--duration", type=positive_seconds, help="Stop this many seconds after the first complete sample.")
    parser.add_argument("--no-data-timeout", type=positive_seconds, default=10.0)
    parser.add_argument("--show-raw", action="store_true", help="Show received text for troubleshooting.")
    parser.add_argument("--port")
    parser.add_argument("--input-format", choices=("auto", "andy", "csv", "timestamped"), default="auto")
    parser.add_argument("--require-100hz", action="store_true",
                        help="Reject untimed input, gaps/resets, and rates outside 95–105 Hz after 101 samples.")
    parser.add_argument("--acceleration-unit", choices=("mps2", "g"), default="mps2")
    parser.add_argument("--gyroscope-unit", choices=("rads", "dps"), default="rads")
    args = parser.parse_args()
    if args.require_100hz and args.input_format in ("andy", "csv"):
        parser.error("--require-100hz needs --input-format auto or timestamped")
    samples = SerialSampleParser(args.input_format, args.acceleration_unit, args.gyroscope_unit)
    port = args.port or find_esp32_port()
    if port is None:
        print("ESP32 not found.")
        print("Connect the ESP-WROOM-32 with a USB data cable, then run this again.")
        return 1

    print(f"Connecting to {port} at {BAUD_RATE} baud...")

    output_file = None
    output_path = None
    count = 0
    received_count = 0
    host_rate = None
    announced_format = None
    exit_code = 0
    euler_yaw_deg = 0.0
    previous_euler_elapsed = None
    rate_guard = HundredHzGuard() if args.require_100hz else None
    graph = None
    try:
        if args.graph:
            from live_sensor_graph import LiveSensorGraph, BufferedSerialLines
            graph = LiveSensorGraph(args.placement, args.label, args.preview, args.graph_seconds)
        with open_esp32(port, BAUD_RATE, timeout=0 if args.graph else 1) as esp32:
            time.sleep(2)
            syncing = False
            if hasattr(esp32, "reset_input_buffer"):
                esp32.reset_input_buffer()  # Discard readings queued during connection settling.
                # A USB packet may still contain the tail of a row after a flush.
                # Discard through the first newline, even if that tail looks like
                # valid numbers (e.g. a timestamp with missing leading digits).
                syncing = True
            print("Connected to ESP32! Press Control+C to stop.\n")
            if not args.graph:
                print(",".join(FIELD_NAMES))
            reader = BufferedSerialLines(esp32) if args.graph else esp32
            writer = None
            started = None
            last_timing_report = 0.0
            health = StreamHealth(args.no_data_timeout)
            print(f"Actual sensor placement must be: {args.placement}; subject: {args.subject_id}")
            if not args.preview:
                print(f"Recording label: {args.label}. A CSV will be created when the first complete sample arrives.")

            while True:
                if graph is not None and not graph.poll():
                    print("Graph window closed. Collection stopped.")
                    break
                raw_line = reader.readline()
                line = raw_line.decode("utf-8", errors="replace").strip()
                if started is not None and args.duration is not None and time.monotonic() - started >= args.duration:
                    print("Requested recording duration reached.")
                    break
                health.check(line)
                if syncing:
                    if raw_line.endswith(b"\n"):
                        syncing = False
                    elif graph is not None and not raw_line:
                        time.sleep(.005)
                    continue
                if args.show_raw and line:
                    print(f"RAW: {line}")
                if line:
                    try:
                        values = samples.feed(line)
                    except ValueError as error:
                        print(f"Skipped input: {error}")
                        continue
                    if values is None:
                        continue
                    gap = health.accept()
                    timed = samples.last_format == "timestamped"
                    timing = samples.timing
                    if rate_guard is not None:
                        rate_guard.check(samples.last_format, timing)
                        if gap:
                            raise RuntimeError("100 Hz check failed: host received no valid sample for over two seconds.")
                    if samples.last_format != announced_format:
                        announced_format = samples.last_format
                        print(f"Input detected: {announced_format}.")
                        if not timed:
                            print("WARNING: no device timing; this is NOT a verified 100 Hz stream. "
                                  "Upload Arduino/MPU6050_100Hz/MPU6050_100Hz.ino for 100 Hz collection.")
                    gap = gap or (timed and timing.discontinuity)
                    if gap:
                        print("Warning: stream discontinuity; check device timestamps/sequence before using this recording.")
                    if started is None:
                        started = time.monotonic()
                    elapsed = time.monotonic() - started
                    euler_dt = timing.interval_s if timed else (
                        elapsed - previous_euler_elapsed if previous_euler_elapsed is not None else 0.0
                    )
                    if (gap or euler_dt is None or not math.isfinite(euler_dt)
                            or euler_dt <= 0 or euler_dt > 1):
                        euler_dt = 0.0
                    euler_x_deg, euler_y_deg, euler_yaw_deg = euler_angles(
                        values, euler_yaw_deg, euler_dt
                    )
                    previous_euler_elapsed = elapsed
                    received_count += 1
                    received_at = datetime.now(timezone.utc)
                    host_rate = (received_count - 1) / elapsed if received_count > 1 and elapsed > 0 else None
                    if timed and timing.received_rate_hz is not None and elapsed - last_timing_report >= 5:
                        print(f"Device-timestamp received rate: {timing.received_rate_hz:.1f} Hz; "
                              f"missing packets: {timing.missing_packets}; resets: {timing.reset_count}")
                        last_timing_report = elapsed
                    if not args.preview:
                        if writer is None:
                            recording_dir = args.output_dir / args.subject_id / args.label
                            recording_dir.mkdir(parents=True, exist_ok=True)
                            stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S_%fZ")
                            output_path = (recording_dir / f"{args.label}_{args.placement}_{stamp}.csv").resolve()
                            output_file = output_path.open("x", newline="", encoding="utf-8")
                            writer = csv.writer(output_file)
                            writer.writerow(CSV_FIELDS)
                            print(f"Saving to: {output_path}")
                        writer.writerow([
                            received_at.isoformat(timespec="milliseconds"),
                            f"{elapsed:.6f}", args.label, args.placement, args.subject_id, *values,
                            "m/s^2", "rad/s", samples.last_format,
                            timing.timestamp_us if timed else "", timing.sequence if timed else "",
                            f"{timing.elapsed_s:.6f}" if timed else "",
                            f"{timing.interval_s:.6f}" if timed and timing.interval_s is not None else "",
                            int(gap),
                            f"{euler_x_deg:.6f}" if math.isfinite(euler_x_deg) else "",
                            f"{euler_y_deg:.6f}" if math.isfinite(euler_y_deg) else "",
                            f"{euler_yaw_deg:.6f}" if math.isfinite(euler_yaw_deg) else "",
                        ])
                        output_file.flush()
                        count += 1
                    if graph is not None:
                        graph.set_recording_time(received_at)
                        graph.source_format = samples.last_format
                        graph.host_rate_hz = host_rate
                        graph.device_rate_hz = timing.received_rate_hz if timed else None
                        graph.add_sample(elapsed, values, gap=gap)
                    else:
                        print(",".join(f"{value:.6g}" for value in values))
                elif graph is not None:
                    time.sleep(.005)
    except KeyboardInterrupt:
        print("\nProgram stopped.")
    except RuntimeError as error:
        exit_code = 1
        print(error)
    except serial.SerialException as error:
        exit_code = 1
        print(f"Serial connection error: {error}")
    except OSError as error:
        exit_code = 1
        print(f"CSV file error: {error}")
    finally:
        if output_file is not None:
            output_file.close()
            print(f"Saved {count} samples to: {output_path}")
        elif not args.preview:
            print("No CSV saved: no complete sample was recorded.")
        if graph is not None:
            try:
                graph.finish(output_path.with_suffix(".png") if output_path else None)
            except OSError as error:
                exit_code = 1
                print(f"Could not save graph snapshot (CSV is unchanged): {error}")
        if host_rate is not None:
            print(f"Final host-received rate: {host_rate:.2f} Hz ({received_count} samples); "
                  f"input format: {samples.last_format}. Host receipt timing is not device timing.")
        if samples.last_format == "timestamped" and samples.timing.received_rate_hz is not None:
            print(f"Final device-timestamp received rate: {samples.timing.received_rate_hz:.1f} Hz "
                  f"(up to last 500 intervals); packet gaps: {samples.timing.missing_packets}; "
                  f"resets: {samples.timing.reset_count}")
        if rate_guard is not None:
            if exit_code or not rate_guard.verified:
                exit_code = 1
                print("100 Hz verification NOT completed successfully. Any saved CSV is partial/unverified; "
                      "at least 101 continuous timestamped samples are required.")
            else:
                print("100 Hz timing check passed: 95–105 Hz, no observed timing/sequence gaps or resets. "
                      "This does not validate sensor accuracy or fall detection.")
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
