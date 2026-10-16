"""Decode six-axis CSV or Andy's MPU6050 text blocks into SI-unit samples."""

import math
import re
import time
from device_timing import DeviceTiming

GRAVITY = 9.80665
NUMBER = r"[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?"
AXIS = re.compile(
    rf"([XYZ])\s*=\s*({NUMBER})\s+(m/s\^2|rad/s)\s+({NUMBER})\s+(g|deg/s)"
)


def parse_csv_values(line, acceleration_unit="mps2", gyroscope_unit="rads"):
    fields = line.split(",")
    if len(fields) != 6:
        raise ValueError("expected exactly six comma-separated sensor values")
    values = [float(field.strip()) for field in fields]
    if acceleration_unit not in ("mps2", "g") or gyroscope_unit not in ("rads", "dps"):
        raise ValueError("unsupported sensor units")
    if acceleration_unit == "g":
        values[:3] = [value * GRAVITY for value in values[:3]]
    if gyroscope_unit == "dps":
        values[3:] = [math.radians(value) for value in values[3:]]
    if not all(math.isfinite(value) for value in values):
        raise ValueError("all six sensor values must be finite")
    return values


class SerialSampleParser:
    """Emit one complete sample, or None while waiting/ignoring status text.

    Andy's repeated X/Y/Z labels are disambiguated by section and order.
    A damaged or stale block is discarded; readings from separate blocks are
    never joined. CSV unit options do not affect explicitly labeled SI values.
    """

    def __init__(self, input_format="auto", acceleration_unit="mps2",
                 gyroscope_unit="rads", clock=time.monotonic):
        if input_format not in ("auto", "csv", "andy", "timestamped"):
            raise ValueError("unknown serial input format")
        self.input_format = input_format
        self.acceleration_unit = acceleration_unit
        self.gyroscope_unit = gyroscope_unit
        self.clock = clock
        self.last_format = None
        self.timing = DeviceTiming()
        self.reset()

    def reset(self):
        self.values = []
        self.stage = None
        self.last_line_at = None

    def feed(self, line):
        now = self.clock()
        if self.last_line_at is not None and now - self.last_line_at > 1.0:
            self.reset()
        line = line.strip()
        if not line:
            return None
        if line.startswith(("# inflatebody_mpu6050_v2", "rst:", "ets ")):
            self.reset()
            self.timing.restart()
            return None
        if line.startswith("ERROR:"):
            self.reset()
            raise ValueError(line)
        if "," in line and self.input_format != "andy":
            self.reset()
            if line.lower().replace(" ", "") == "ax,ay,az,gx,gy,gz":
                return None
            if line.lower().replace(" ", "") == "device_time_us,sequence,ax,ay,az,gx,gy,gz":
                self.timing.restart()
                return None
            fields = [field.strip() for field in line.split(",")]
            if len(fields) == 8:
                if not all(field.isascii() and field.isdigit() for field in fields[:2]):
                    raise ValueError("Invalid timestamp/sequence fields")
                # Versioned timestamped firmware always sends SI units. CSV
                # override flags apply only to the old six-value format.
                values = parse_csv_values(",".join(fields[2:]), "mps2", "rads")
                self.timing.observe(int(fields[0]), int(fields[1]))
                self.last_format = "timestamped"
                return values
            if self.input_format == "timestamped":
                raise ValueError("Expected device_time_us,sequence and six sensor values")
            values = parse_csv_values(line, self.acceleration_unit, self.gyroscope_unit)
            self.last_format = "csv"
            return values
        if self.input_format in ("csv", "timestamped"):
            return None
        if line == "--- ACCELEROMETER ---":
            self.reset()
            self.stage = "acc"
            self.last_line_at = now
            return None
        if self.stage is None:
            return None
        self.last_line_at = now
        if self.stage == "gyro_header":
            if line == "--- GYROSCOPE ---":
                self.stage = "gyro"
                return None
        else:
            match = AXIS.fullmatch(line)
            units = ("m/s^2", "g") if self.stage == "acc" else ("rad/s", "deg/s")
            if (match and match[1] == "XYZ"[len(self.values) % 3]
                    and (match[3], match[5]) == units
                    and math.isfinite(float(match[2]))
                    and math.isfinite(float(match[4]))):
                self.values.append(float(match[2]))
                if len(self.values) == 3:
                    self.stage = "gyro_header"
                elif len(self.values) == 6:
                    values = self.values
                    self.reset()
                    self.last_format = "andy"
                    return values
                return None
        self.reset()
        raise ValueError("incomplete or malformed MPU6050 block; waiting for next accelerometer header")
