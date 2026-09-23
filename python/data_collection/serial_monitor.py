"""Print 9-axis IMU readings sent by an ESP-WROOM-32 at 115200 baud.

Expected serial line:
    ax,ay,az,gx,gy,gz,mx,my,mz
"""

import argparse
import math
import time

import serial
from serial.tools import list_ports


BAUD_RATE = 115200


def find_esp32_port():
    """Return a likely ESP32 USB-to-UART port, if it is connected."""
    keywords = ("esp32", "cp210", "silicon labs", "ch340", "wch", "usbserial")
    for port in list_ports.comports():
        details = f"{port.device} {port.description} {port.manufacturer or ''}".lower()
        if any(keyword in details for keyword in keywords):
            return port.device
    return None


def parse_sample(line):
    values = [float(value.strip()) for value in line.split(",")]
    if len(values) != 9 or not all(math.isfinite(value) for value in values):
        raise ValueError("expected nine finite comma-separated values")
    return values


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", help="ESP32 serial port; detected automatically by default")
    parser.add_argument("--baud", type=int, default=BAUD_RATE)
    args = parser.parse_args()

    port = args.port or find_esp32_port()
    if not port:
        raise SystemExit("ESP32 not found. Connect it with a USB data cable and try again.")

    print(f"Connected to {port} at {args.baud} baud. Press Control+C to stop.")
    print("ax,ay,az,gx,gy,gz,mx,my,mz")
    try:
        with serial.Serial(port, args.baud, timeout=1) as device:
            time.sleep(2)
            while True:
                line = device.readline().decode("utf-8", errors="replace").strip()
                if not line:
                    continue
                try:
                    values = parse_sample(line)
                except ValueError:
                    print(f"Skipped invalid line: {line}")
                    continue
                print(",".join(f"{value:.6g}" for value in values))
    except KeyboardInterrupt:
        print("\nStopped.")


if __name__ == "__main__":
    main()
