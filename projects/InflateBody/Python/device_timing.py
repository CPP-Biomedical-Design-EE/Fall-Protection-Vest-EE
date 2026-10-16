"""Validate the 100 Hz firmware's uint32 read timestamps and packet sequence."""
from collections import deque


class DeviceTiming:
    def __init__(self):
        self.timestamp_us = None
        self.sequence = None
        self.elapsed_s = 0.0
        self.interval_s = None
        self.intervals = deque(maxlen=500)
        self.discontinuity = False
        self.missing_packets = 0
        self.reset_count = 0
        self._pending_reset = False

    def restart(self):
        if self.timestamp_us is not None:
            self.reset_count += 1
            self._pending_reset = True
        self.timestamp_us = self.sequence = None
        self.elapsed_s = 0.0
        self.interval_s = None
        self.intervals.clear()

    @property
    def received_rate_hz(self):
        return len(self.intervals) / sum(self.intervals) if self.intervals else None

    def observe(self, timestamp_us, sequence):
        for value in (timestamp_us, sequence):
            if not isinstance(value, int) or not 0 <= value < 2**32:
                raise ValueError("Timestamp and sequence must be unsigned 32-bit integers")
        self.discontinuity = self._pending_reset
        self._pending_reset = False
        self.interval_s = None
        if self.timestamp_us is not None:
            delta = (timestamp_us - self.timestamp_us) % 2**32
            advance = (sequence - self.sequence) % 2**32
            if advance == 0 or delta == 0:
                raise ValueError("Duplicate timestamp or sequence; packet ignored")
            if delta >= 2**31 or advance >= 2**31:
                self.restart()
                self._pending_reset = False
                self.discontinuity = True
            else:
                self.interval_s = delta / 1_000_000.0
                self.elapsed_s += self.interval_s
                self.intervals.append(self.interval_s)
                self.missing_packets += advance - 1
                self.discontinuity = advance != 1 or not 0.005 <= self.interval_s <= 0.015
        self.timestamp_us, self.sequence = timestamp_us, sequence
