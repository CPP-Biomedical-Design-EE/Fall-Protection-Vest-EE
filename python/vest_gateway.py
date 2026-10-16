"""Record ESP32 samples and expose experimental status to the Flutter app.

The ESP32 remains the 100 Hz acquisition owner. This process is the only USB
serial reader, writes every accepted sample to CSV, runs the experimental
Python threshold candidate detector, and serves the latest snapshot over HTTP.
No message from this gateway controls a servo or inflation mechanism.
"""

import argparse
import csv
import json
import math
import threading
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import numpy as np
import serial

from collect_data import CSV_FIELDS, DEFAULT_DATA_DIR, FIELD_NAMES, activity_label, find_esp32_port
from esp32_serial import open_esp32
from serial_samples import SerialSampleParser
from stream_health import HundredHzGuard, StreamHealth, positive_seconds
from threshold_detection import ThresholdFallDetector, Thresholds


class GatewayState:
    """Thread-safe latest-sample and candidate state served to Flutter."""

    def __init__(self):
        self._lock = threading.Lock()
        self._candidate_acknowledgements = 0
        self._snapshot = {
            "connected": False,
            "fall_candidate": False,
            "battery": None,
            "timestamp": datetime.now(timezone.utc).isoformat(timespec="milliseconds"),
            "sample_rate_hz": None,
            "device_time_us": None,
            "sequence": None,
            "acceleration_g": None,
            "gyroscope_dps": None,
            "tilt_degrees": None,
            "sensor": {name: None for name in FIELD_NAMES},
            "calibrating": True,
            "notice": "Waiting for a timestamped 100 Hz ESP32 stream.",
        }

    def update(self, **values):
        with self._lock:
            self._snapshot.update(values)

    def snapshot(self):
        with self._lock:
            return dict(self._snapshot)

    def acknowledge_candidate(self):
        with self._lock:
            self._snapshot.update(
                fall_candidate=False,
                notice="Candidate acknowledged; experimental monitoring continues.",
            )
            self._candidate_acknowledgements += 1

    def candidate_acknowledgements(self):
        with self._lock:
            return self._candidate_acknowledgements


def create_handler(state):
    class Handler(BaseHTTPRequestHandler):
        def _json_response(self, status, payload):
            body = json.dumps(payload, allow_nan=False).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
            self.send_header("Access-Control-Allow-Headers", "Content-Type")
            self.end_headers()
            self.wfile.write(body)

        def do_OPTIONS(self):
            self._json_response(204, {})

        def do_GET(self):
            if self.path != "/api/status":
                self._json_response(404, {"error": "not found"})
                return
            self._json_response(200, state.snapshot())

        def do_POST(self):
            if self.path != "/api/candidate/ack":
                self._json_response(404, {"error": "not found"})
                return
            state.acknowledge_candidate()
            self._json_response(200, state.snapshot())

        def log_message(self, _format, *_args):
            return

    return Handler


def start_http_server(state, host, port):
    server = ThreadingHTTPServer((host, port), create_handler(state))
    server.daemon_threads = True
    thread = threading.Thread(target=server.serve_forever, name="vest-http-gateway", daemon=True)
    thread.start()
    return server


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", help="ESP32 serial port; auto-detected if omitted")
    parser.add_argument("--api-host", default="0.0.0.0", help="HTTP bind address (default: all local interfaces)")
    parser.add_argument("--api-port", type=int, default=8765, help="HTTP port for Flutter (default: 8765)")
    parser.add_argument("--subject-id", type=activity_label, default="unknown")
    parser.add_argument("--label", type=activity_label, default="unlabeled")
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_DATA_DIR)
    parser.add_argument("--duration", type=positive_seconds, help="Stop after this many seconds from the first sample")
    parser.add_argument("--no-data-timeout", type=positive_seconds, default=10.0)
    return parser.parse_args()


def main():
    args = parse_args()
    if not 1 <= args.api_port <= 65535:
        raise SystemExit("--api-port must be between 1 and 65535")
    port = args.port or find_esp32_port()
    if port is None:
        raise SystemExit("ESP32 not found. Connect the ESP-WROOM-32 and try again.")

    state = GatewayState()
    try:
        server = start_http_server(state, args.api_host, args.api_port)
    except OSError as error:
        raise SystemExit(f"Could not start Flutter HTTP gateway: {error}") from error

    output_file = None
    output_path = None
    writer = None
    sample_count = 0
    started = None
    candidate_latched = False
    seen_acknowledgements = state.candidate_acknowledgements()
    detector = ThresholdFallDetector(
        sample_rate_hz=100.0,
        calibration_samples=100,
        evidence_seconds=1.0,
        cooldown_seconds=2.0,
        thresholds=Thresholds(),
    )
    parser = SerialSampleParser("timestamped")
    rate_guard = HundredHzGuard()
    health = StreamHealth(args.no_data_timeout)
    print(f"Flutter status API listening on http://{args.api_host}:{args.api_port}/api/status")
    print("Use the computer's LAN IP in Flutter; keep the phone and computer on the same trusted Wi-Fi.")
    print("Experimental fall candidates only; no servo or inflation output is connected.")
    print(f"Connecting to ESP32 serial port {port} at 115200 baud...")

    try:
        with open_esp32(port, 115200, timeout=1) as device:
            time.sleep(2)
            syncing = False
            if hasattr(device, "reset_input_buffer"):
                device.reset_input_buffer()
                syncing = True
            print("Connected. Leave the sensor still during the one-second detector calibration.")

            while True:
                raw_line = device.readline()
                line = raw_line.decode("utf-8", errors="replace").strip()
                health.check(line)
                if syncing:
                    if raw_line.endswith(b"\n"):
                        syncing = False
                    continue
                if not line:
                    continue

                try:
                    values = parser.feed(line)
                except ValueError as error:
                    raise RuntimeError(f"Invalid timestamped ESP32 input: {error}") from error
                if values is None:
                    continue

                timing = parser.timing
                rate_guard.check(parser.last_format, timing)
                if health.accept():
                    raise RuntimeError("Serial stream paused for more than two seconds; recording stopped.")
                if started is None:
                    started = time.monotonic()
                elapsed = time.monotonic() - started
                if args.duration is not None and elapsed >= args.duration:
                    break

                if writer is None:
                    recording_dir = args.output_dir / args.subject_id / args.label
                    recording_dir.mkdir(parents=True, exist_ok=True)
                    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S_%fZ")
                    output_path = (recording_dir / f"{args.label}_lower_back_center_waist_{stamp}.csv").resolve()
                    output_file = output_path.open("x", newline="", encoding="utf-8")
                    writer = csv.writer(output_file)
                    writer.writerow(CSV_FIELDS)
                    print(f"Saving raw data to: {output_path}")

                result = detector.update(np.asarray(values[:3]), np.asarray(values[3:]))
                acknowledgements = state.candidate_acknowledgements()
                if acknowledgements != seen_acknowledgements:
                    candidate_latched = False
                    seen_acknowledgements = acknowledgements
                if result["fall_detected"]:
                    candidate_latched = True
                    print("EXPERIMENTAL FALL CANDIDATE — review the recording; no hardware action taken.")

                writer.writerow([
                    datetime.now(timezone.utc).isoformat(timespec="milliseconds"),
                    f"{elapsed:.6f}", args.label, "lower_back_center_waist", args.subject_id, *values,
                    "m/s^2", "rad/s", parser.last_format,
                    timing.timestamp_us, timing.sequence,
                    f"{timing.elapsed_s:.6f}",
                    f"{timing.interval_s:.6f}" if timing.interval_s is not None else "",
                    int(timing.discontinuity),
                ])
                output_file.flush()
                sample_count += 1

                acceleration_magnitude = float(np.linalg.norm(values[:3]))
                gyroscope_magnitude = float(np.linalg.norm(values[3:]))
                snapshot = {
                    "connected": True,
                    "fall_candidate": candidate_latched,
                    "battery": None,
                    "timestamp": datetime.now(timezone.utc).isoformat(timespec="milliseconds"),
                    "sample_rate_hz": timing.received_rate_hz if rate_guard.verified else None,
                    "device_time_us": timing.timestamp_us,
                    "sequence": timing.sequence,
                    "acceleration_g": acceleration_magnitude / 9.80665,
                    "gyroscope_dps": math.degrees(gyroscope_magnitude),
                    "tilt_degrees": result.get("tilt_degrees"),
                    "sensor": dict(zip(FIELD_NAMES, values)),
                    "calibrating": not detector.calibrated,
                    "notice": (
                        "EXPERIMENTAL FALL CANDIDATE — not a validated alert."
                        if candidate_latched else
                        "Thresholds are experimental; this is not a safety detector."
                    ),
                }
                if snapshot["tilt_degrees"] is not None and not math.isfinite(snapshot["tilt_degrees"]):
                    snapshot["tilt_degrees"] = None
                state.update(**snapshot)

    except KeyboardInterrupt:
        print("\nStopping gateway.")
    except (RuntimeError, serial.SerialException, OSError) as error:
        print(f"Gateway stopped: {error}")
        state.update(connected=False, notice=str(error))
        return 1
    finally:
        state.update(connected=False)
        if output_file is not None:
            output_file.close()
            print(f"Saved {sample_count} samples to: {output_path}")
        server.shutdown()
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())