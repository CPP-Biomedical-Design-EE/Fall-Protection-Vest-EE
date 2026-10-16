"""Live six-axis sensor monitor. No fall classification or actuator control."""
from collections import deque
from zoneinfo import ZoneInfo
import math
import time

GRAVITY = 9.80665


def accelerometer_tilt(values):
    """Sensor-frame roll/pitch in degrees; quasi-static estimate, not fused attitude.

    Near-1-g magnitude is necessary but does not guarantee absence of motion.
    No yaw or fall-decision angle is inferred here.
    """
    ax, ay, az = values[:3]
    magnitude = math.sqrt(ax * ax + ay * ay + az * az) / GRAVITY
    if not math.isfinite(magnitude) or not 0.8 <= magnitude <= 1.2:
        return float("nan"), float("nan")
    roll = math.degrees(math.atan2(ay, az))
    pitch = math.degrees(math.atan2(-ax, math.hypot(ay, az)))
    # Roll is undefined when gravity is aligned with the sensor X axis.
    if math.hypot(ay, az) < 1e-6:
        roll = float("nan")
    return roll, pitch


def euler_angles(values, previous_yaw_deg=0.0, dt_s=0.0):
    """Return Euler X/Y/Z in degrees for display and recorded context.

    X is accelerometer roll and Y is accelerometer pitch. Z is a relative
    gyro-Z integration from the start of the recording; it has no absolute
    heading and can drift, especially with residual gyro bias.
    """
    roll, pitch = accelerometer_tilt(values)
    yaw = previous_yaw_deg
    if math.isfinite(dt_s) and dt_s > 0 and math.isfinite(values[5]):
        yaw += math.degrees(values[5] * dt_s)
    return roll, pitch, yaw


class BufferedSerialLines:
    """Read complete lines without blocking the GUI or discarding fragments.

    Use with a serial port opened with timeout=0. Bound memory even when the
    device sends corrupt text without newlines.
    """
    def __init__(self, device):
        self.device = device
        self.buffer = bytearray()

    def readline(self):
        if b"\n" not in self.buffer:
            waiting = self.device.in_waiting
            # Some USB drivers report zero until an actual read starts receiving.
            # timeout=0 makes this one-byte probe nonblocking even when idle.
            self.buffer.extend(self.device.read(min(waiting, 8192) if waiting else 1))
        if len(self.buffer) > 65536:
            raise RuntimeError("Serial text has no usable line endings. Check firmware and baud rate.")
        end = self.buffer.find(b"\n")
        if end < 0:
            return b""
        line = bytes(self.buffer[:end + 1])
        del self.buffer[:end + 1]
        return line


class LiveSensorGraph:
    def __init__(self, placement, label, preview, window_seconds=20.0, show=True):
        import matplotlib
        import matplotlib.pyplot as plt

        if show and str(matplotlib.get_backend()).lower() in {"agg", "pdf", "svg", "ps", "pgf", "cairo", "template"}:
            raise RuntimeError("No desktop graph backend is active. Run from the Mac terminal without MPLBACKEND=Agg.")
        self.plt = plt
        self.window_seconds = window_seconds
        self.history = deque(maxlen=20000)
        self.total_samples = 0
        self.preview = preview
        self.device_rate_hz = None
        self.host_rate_hz = None
        self.source_format = None
        self.show = show
        self.last_draw = -float("inf")
        self.closed = False
        self.recording_start = None
        self.figure, self.axes = plt.subplots(4, 1, figsize=(11, 10), sharex=True)
        self.figure.canvas.manager.set_window_title("InflateBody | Live MPU6050")
        self.figure.patch.set_facecolor("#f5f7fa")
        self.figure.suptitle("Live MPU6050 · Six-axis sensor monitor", fontsize=16, fontweight="bold", y=.97)
        self.figure.text(.5, .93, f"{placement.replace('_', ' ')}  |  {label.replace('_', ' ')}",
                         ha="center", fontsize=11)
        self.status = self.figure.text(.08, .06, "Waiting for the first complete sensor sample…", fontsize=10)
        self.time_label = self.figure.text(.5, .905, "", ha="center", fontsize=9, color="#526171")
        self.figure.text(.08, .025, "Sensor readings only — not a fall alarm or an accuracy test. Close this window to stop.",
                         fontsize=9, color="#526171")
        # Leave space for the two-line acquisition/rate status below the x label.
        self.figure.subplots_adjust(top=.87, bottom=.18, left=.10, right=.96, hspace=.26)
        colors = ("#2674b8", "#d85944", "#22865e")
        self.acc_lines = [self.axes[0].plot([], [], color=c, label=f"A{a}", lw=1.5)[0]
                          for a, c in zip("xyz", colors)]
        self.gyro_lines = [self.axes[1].plot([], [], color=c, label=f"G{a}", lw=1.5)[0]
                           for a, c in zip("xyz", colors)]
        self.norm_line = self.axes[2].plot([], [], color="#7451ac", label="Total acceleration", lw=1.7)[0]
        self.axes[2].axhline(1, color="#7b8794", linestyle="--", label="1 g reference (not a fall threshold)")
        self.angle_lines = [self.axes[3].plot([], [], color=c, label=name, lw=1.5)[0]
                            for name, c in zip(("Euler X / Roll", "Euler Y / Pitch", "Euler Z / Relative yaw"), colors)]
        self.axes[3].set_title("Euler angle display · X/Y accelerometer tilt; Z relative gyro-integrated yaw", fontsize=9)
        for axis, ylabel in zip(self.axes, ("Acceleration (m/s²)", "Rotation (°/s)", "Acceleration (g)", "Tilt (°)")):
            axis.set_ylabel(ylabel)
            axis.grid(alpha=.2)
            axis.legend(loc="upper left", ncol=3, fontsize=9)
        self.axes[0].set_ylim(-12, 12)
        self.axes[1].set_ylim(-10, 10)
        self.axes[2].set_ylim(0, 2)
        self.axes[3].set_ylim(-180, 180)
        self.axes[3].set_yticks([-180, -90, 0, 90, 180])
        self.axes[3].set_xlabel("Elapsed time (seconds; computer receipt time)")
        self.axes[2].set_xlim(0, window_seconds)
        self.figure.canvas.mpl_connect("close_event", self._on_close)
        self.figure.canvas.mpl_connect("motion_notify_event", self._on_hover)
        self.hover_lines = [axis.axvline(0, color="#526171", linestyle=":", alpha=.65, visible=False)
                            for axis in self.axes]
        self.hover_annotation = self.axes[0].annotate(
            "", xy=(0, 0), xytext=(12, 12), textcoords="offset points",
            bbox={"boxstyle": "round", "facecolor": "white", "edgecolor": "#526171", "alpha": .92},
            fontsize=8, visible=False,
        )
        if show:
            plt.show(block=False)

    def _on_close(self, event):
        self.closed = True

    def _angle_history(self):
        angles = []
        previous_time = None
        yaw = 0.0
        for timestamp, values in self.history:
            if not all(math.isfinite(value) for value in values):
                angles.append((float("nan"), float("nan"), float("nan")))
                previous_time = None
                continue
            dt = timestamp - previous_time if previous_time is not None else 0.0
            angle = euler_angles(values, yaw, dt)
            angles.append(angle)
            yaw = angle[2]
            previous_time = timestamp
        return angles

    def _on_hover(self, event):
        if event.inaxes not in self.axes or not self.history or event.xdata is None:
            for line in self.hover_lines:
                line.set_visible(False)
            self.hover_annotation.set_visible(False)
            return
        samples = list(self.history)
        index = min(range(len(samples)), key=lambda i: abs(samples[i][0] - event.xdata))
        timestamp, values = samples[index]
        if not all(math.isfinite(value) for value in values):
            self.hover_annotation.set_visible(False)
            return
        angles = self._angle_history()[index]
        for line in self.hover_lines:
            line.set_xdata([timestamp, timestamp])
            line.set_visible(True)
        self.hover_annotation.xy = (timestamp, values[0])
        self.hover_annotation.set_text(
            f"t = {timestamp:.3f} s\n"
            f"A: {values[0]:.3f}, {values[1]:.3f}, {values[2]:.3f} m/s²\n"
            f"Total acceleration: {math.sqrt(sum(value * value for value in values[:3])) / GRAVITY:.3f} g\n"
            f"G: {math.degrees(values[3]):.2f}, {math.degrees(values[4]):.2f}, {math.degrees(values[5]):.2f} °/s\n"
            f"Euler: {angles[0]:.2f}, {angles[1]:.2f}, {angles[2]:.2f}°"
        )
        self.hover_annotation.set_visible(True)
        self.figure.canvas.draw_idle()

    def set_recording_time(self, timestamp):
        """Show actual host receipt timestamps, shared with the CSV; live only."""
        local = timestamp.astimezone(ZoneInfo("America/Los_Angeles"))
        if self.recording_start is None:
            self.recording_start = local
        self.time_label.set_text(
            f"Started: {self.recording_start:%Y-%m-%d %H:%M:%S %Z}"
            f"  |  Latest sample: {local:%H:%M:%S %Z}"
        )

    def add_sample(self, elapsed, values, gap=False):
        if len(values) != 6 or not all(math.isfinite(v) for v in values) or not math.isfinite(elapsed):
            raise ValueError("Graph needs six finite sensor values and a finite timestamp.")
        if self.history and elapsed < self.history[-1][0]:
            raise ValueError("Graph timestamps must be ordered.")
        if gap and self.history:
            self.history.append((elapsed, [float("nan")] * 6))
        self.history.append((elapsed, list(values)))
        self.total_samples += 1
        while self.history and self.history[0][0] < elapsed - self.window_seconds:
            self.history.popleft()

    def redraw(self):
        if not self.history:
            return
        times = [sample[0] for sample in self.history]
        for index, line in enumerate(self.acc_lines):
            line.set_data(times, [sample[1][index] for sample in self.history])
        for index, line in enumerate(self.gyro_lines):
            line.set_data(times, [math.degrees(sample[1][index + 3]) for sample in self.history])
        magnitudes = [math.sqrt(sum(v * v for v in sample[1][:3])) / GRAVITY for sample in self.history]
        self.norm_line.set_data(times, magnitudes)
        angles = self._angle_history()
        for index, line in enumerate(self.angle_lines):
            angle_times, angle_values = [], []
            previous = float("nan")
            for timestamp, pair in zip(times, angles):
                value = pair[index]
                # Break the line at the +/-180 degree boundary instead of
                # drawing a false sweep through zero.
                if math.isfinite(previous) and math.isfinite(value) and abs(value - previous) > 180:
                    angle_times.append(timestamp)
                    angle_values.append(float("nan"))
                angle_times.append(timestamp)
                angle_values.append(value)
                previous = value
            line.set_data(angle_times, angle_values)
        right = max(self.window_seconds, times[-1])
        self.axes[2].set_xlim(right - self.window_seconds, right)
        for axis in self.axes[:3]:
            axis.relim()
            axis.set_autoscaley_on(True)
            axis.autoscale_view(scalex=False, scaley=True)
            axis.margins(y=.2)
        latest = self.history[-1][1]
        rotation = math.degrees(math.sqrt(sum(v * v for v in latest[3:])))
        mode = "PREVIEW · not saved" if self.preview else "RECORDING · saving CSV"
        self.status.set_text(f"{mode}  |  {self.total_samples} samples  |  {times[-1]:.1f} s  |  "
                             f"Total: {magnitudes[-1]:.2f} g  |  Rotation: {rotation:.1f} °/s")
        rates = []
        if self.source_format is not None:
            rates.append(f"Input: {self.source_format.upper()}")
        if self.device_rate_hz is not None:
            rates.append(f"{self.device_rate_hz:.1f} Hz (device)")
        if self.host_rate_hz is not None:
            rates.append(f"{self.host_rate_hz:.1f} Hz (host received)")
        if self.source_format in ("andy", "csv"):
            rates.append("100 Hz NOT verified")
        if rates:
            self.status.set_text(self.status.get_text() + "\n" + "  |  ".join(rates))
        self.figure.canvas.draw_idle()

    def poll(self):
        if self.closed or not self.plt.fignum_exists(self.figure.number):
            return False
        now = time.monotonic()
        if now - self.last_draw >= .1:
            self.redraw()
            if self.show:
                self.figure.canvas.flush_events()
            self.last_draw = now
        return not self.closed

    def finish(self, snapshot_path=None):
        try:
            if snapshot_path is not None and self.total_samples:
                self.redraw()
                self.status.set_text(self.status.get_text().replace("RECORDING · saving CSV", "SAVED · final visible window"))
                # Match the collector's no-overwrite policy.
                with snapshot_path.open("xb") as target:
                    self.figure.savefig(target, format="png", dpi=140)
                print(f"Graph snapshot saved to: {snapshot_path}")
        finally:
            self.plt.close(self.figure)
