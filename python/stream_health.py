"""Host-side serial diagnostics; not proof of sensor accuracy."""
import argparse
import math
import time


def positive_seconds(value):
    number = float(value)
    if not math.isfinite(number) or number <= 0:
        raise argparse.ArgumentTypeError("Use a finite number greater than zero")
    return number


class HundredHzGuard:
    """Optional timing gate, not a sensor-accuracy or protective-system check."""
    def __init__(self):
        self.verified = False

    def check(self, input_format, timing):
        if input_format != "timestamped":
            raise RuntimeError(
                f"100 Hz check failed: received {input_format} data without device timestamps. "
                "Upload Arduino/MPU6050_100Hz/MPU6050_100Hz.ino to the ESP32 first. "
                "Python cannot turn the legacy stream into 100 Hz measurements."
            )
        if timing.discontinuity or timing.missing_packets or timing.reset_count:
            raise RuntimeError("100 Hz check failed: a timing/sequence gap or device reset was detected.")
        # 100 intervals need 101 samples. Continue checking the rolling window
        # after warm-up, so a later slowdown cannot silently pass.
        if len(timing.intervals) >= 100:
            rate = timing.received_rate_hz
            if rate is None or not math.isfinite(rate) or not 95.0 <= rate <= 105.0:
                raise RuntimeError(f"100 Hz check failed: device-timestamp rate is {rate} Hz; expected 95–105 Hz.")
            self.verified = True


class StreamHealth:
    def __init__(self, timeout=10.0, clock=None):
        self.clock = clock or time.monotonic
        self.timeout = positive_seconds(timeout)
        self.last_valid = self.clock()
        self.has_sample = False
        self.lines = 0

    def check(self, line):
        self.lines += bool(line)
        if self.clock() - self.last_valid >= self.timeout:
            detail = "received text but no complete six-axis samples" if self.lines else "received no serial text"
            raise RuntimeError(
                f"Stopped: {detail} for {self.timeout:g} seconds. "
                "Close Arduino Serial Monitor/Plotter, verify 115200 baud and the port, "
                "then try --show-raw to inspect the actual messages. No valid data means no detection."
            )

    def accept(self):
        now = self.clock()
        gap = self.has_sample and now - self.last_valid > 2.0
        self.last_valid = now
        self.has_sample = True
        self.lines = 0
        return gap
